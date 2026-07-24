#!/usr/bin/env bash
# canvas-suite-setup.sh
# https://github.com/RootSwitch/canvas-suite
#
# One-shot deploy of the Canvas suite onto a fresh Linux box (built for a newly
# spun-up Ubuntu Server VM; also handles RHEL/Rocky/Fedora). Uses the shared-data
# layout: all persistent history lives in one folder outside the git checkouts,
# wired up with untracked docker-compose.override.yml files, so updates and
# rebuilds can never touch your data.
#
# It installs what six containers need and brings the whole wall up:
#   CrossCanvas  - the editor (served BY PingCanvas's web container, no container of its own)
#   LaunchCanvas - the front door: login + launcher + SSO    9160/tcp
#   PingCanvas   - reachability kiosk           8080/tcp http, 8443/tcp https
#   SNMPCanvas   - SNMP polling + history        9161/tcp
#   SyslogCanvas - syslog + trap receiver        9514/tcp, 514/udp, 162/udp
#   AlertCanvas  - threshold alerting on SNMPCanvas's feed   9162/tcp
#
# SAFE TO RE-RUN. It never regenerates the SNMPCanvas/AlertCanvas/suite secrets and
# never overwrites existing history; re-running just reconciles the box to this layout.
#
# Usage:
#   sudo-capable user runs:  ./canvas-suite-setup.sh [options]
#
#   --ip ADDR         address the box is reached at   (default: auto-detected)
#   --board FILE      seed this .xcanvas as the kiosk board (default: none; drop one in later)
#   --scan CIDR[,CIDR...]  ping-scan these subnets (nmap -sn) and seed a board
#                     from the results, so the wall is live immediately
#                     (e.g. --scan 192.168.1.0/24,10.50.1.0/24)
#   --no-tls          skip self-signed cert generation (HTTP only)
#   --data DIR        shared data root                (default: /srv/noc-data)
#   --projects DIR    where the repos are cloned      (default: /projects)
#   --update          git-pull existing clones instead of leaving them as-is
#
# Env vars BOX_IP / DATA_ROOT / PROJ_ROOT / TZ override the same values.

set -euo pipefail

# ----- config + defaults ----------------------------------------------------
DATA_ROOT="${DATA_ROOT:-/srv/noc-data}"
PROJ_ROOT="${PROJ_ROOT:-/projects}"
BOX_IP="${BOX_IP:-}"
BOARD=""
GEN_TLS=1
DO_UPDATE=0
SCAN=""
APP_UID=1000                       # the uid the Node apps run as inside the containers
ORG="https://github.com/RootSwitch"

while [ $# -gt 0 ]; do
    case "$1" in
        --ip)       BOX_IP="$2"; shift 2 ;;
        --board)    BOARD="$2"; shift 2 ;;
        --scan)     SCAN="$2"; shift 2 ;;
        --no-tls)   GEN_TLS=0; shift ;;
        --data)     DATA_ROOT="$2"; shift 2 ;;
        --projects) PROJ_ROOT="$2"; shift 2 ;;
        --update)   DO_UPDATE=1; shift ;;
        -h|--help)  sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

# ----- helpers --------------------------------------------------------------
if [ -t 1 ]; then B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); N=$(printf '\033[0m'); else B=; G=; Y=; R=; N=; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this script targets Linux."
command -v sudo >/dev/null 2>&1 || die "sudo not found - run as a user with sudo."
# Cache the sudo credential once, up front, so the script never stops for a
# password partway through (where the prompt can hide in docker build output).
sudo -v || die "this script needs sudo access - run as a user with sudo."

# distro family, for the package manager only
PKG="apt"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091  # system file, not part of this repo
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" rhel "*|*" fedora "*|*" centos "*) PKG="dnf" ;;
        *) PKG="apt" ;;
    esac
fi


# Fail fast on families we don't claim: unknown distros fall through to apt,
# which would otherwise die confusingly mid-run on openSUSE/Arch/Alpine.
if [ "$PKG" = "apt" ] && ! command -v apt-get >/dev/null 2>&1; then
    die "unsupported distro: no apt-get or dnf found. This script targets the Debian/Ubuntu and RHEL (Rocky/Alma/Fedora) families."
fi

pkg_install() {
    if [ "$PKG" = "dnf" ]; then sudo dnf install -y "$@"
    else sudo apt-get update -qq && sudo apt-get install -y "$@"; fi
}

# timezone: reuse the host's if we can find it
TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Etc/UTC)}"

# ----- 1. prerequisites -----------------------------------------------------
say "Checking prerequisites (pkg manager: $PKG, timezone: $TZ)"
NEED=""
for c in git curl openssl; do command -v "$c" >/dev/null 2>&1 || NEED="$NEED $c"; done
# shellcheck disable=SC2086  # word splitting intended: $NEED is a space-separated package list
[ -n "$NEED" ] && { say "Installing:$NEED"; pkg_install $NEED; }

if ! command -v docker >/dev/null 2>&1; then
    say "Installing Docker (official convenience script - modern compose v2)"
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER" || true
    warn "Added you to the 'docker' group. It takes effect on next login;"
    warn "this run uses 'sudo docker', which needs no re-login."
fi

# pick 'docker' vs 'sudo docker' for THIS run (group may not be active yet).
# Both branches prove the DAEMON answers - 'docker compose version' alone is a
# CLI-plugin check that passes with dockerd down (e.g. a manual dnf install,
# where the RHEL family does not auto-start services), and the failure would
# otherwise surface as a cryptic socket error mid-run.
if docker info >/dev/null 2>&1; then DC="docker"
elif sudo docker info >/dev/null 2>&1; then DC="sudo docker"
else die "Docker is installed but the daemon is not answering - start it with:  sudo systemctl enable --now docker   then re-run."
fi
$DC compose version >/dev/null 2>&1 || die "docker compose v2 not available (got compose v1?). Reinstall Docker via get.docker.com."
ok "Docker ready ($DC)"

# ----- 2. IP -----------------------------------------------------------------
if [ -z "$BOX_IP" ]; then
    BOX_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^172\.1[7-9]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[0-1]\.' | head -1)"
    [ -n "$BOX_IP" ] || die "could not auto-detect an IP - pass --ip ADDR."
    warn "Using auto-detected IP: $BOX_IP  (re-run with --ip if that is the wrong NIC)"
fi
# Sanitize + validate: a stray comma or space in --ip poisons every URL, the
# cert SANs, and the verify curls - quietly. Strip the usual paste debris,
# then insist on a plausible IPv4 or hostname.
BOX_IP="$(printf '%s' "$BOX_IP" | tr -d ' ,\t\r\n')"
case "$BOX_IP" in
    *[!0-9.]*)  # not pure digits-and-dots: allow a hostname, but a sane one
        printf '%s' "$BOX_IP" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
            || die "'$BOX_IP' is not a valid IP address or hostname." ;;
    *)
        printf '%s' "$BOX_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
            || die "'$BOX_IP' is not a valid IPv4 address (check --ip for typos)." ;;
esac
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"

# ----- 3. directories --------------------------------------------------------
say "Creating shared data root at $DATA_ROOT (owned by container uid $APP_UID)"
sudo mkdir -p "$DATA_ROOT/certs" "$DATA_ROOT/syslogcanvas/certs" "$DATA_ROOT/alertcanvas/certs" "$DATA_ROOT/launchcanvas/certs"
sudo chown -R "$APP_UID:$APP_UID" "$DATA_ROOT"

say "Creating repo root at $PROJ_ROOT (owned by you, so clones need no sudo)"
sudo mkdir -p "$PROJ_ROOT"
sudo chown "$USER:$USER" "$PROJ_ROOT"

# ----- 4. clone the six repos (siblings; build-web.sh finds ../crosscanvas) --
clone_one() {
    name="$1"; url="$2"; dir="$PROJ_ROOT/$name"
    if [ -d "$dir/.git" ]; then
        if [ "$DO_UPDATE" = 1 ]; then say "Updating $name"; git -C "$dir" pull --ff-only || warn "$name: pull skipped (local changes?)"
        else ok "$name already cloned (use --update to pull)"; fi
    else
        # GIT_TERMINAL_PROMPT=0: a missing/private repo fails immediately
        # instead of stopping the run at a GitHub credential prompt.
        say "Cloning $name"; GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$url" "$dir"
    fi
}
clone_one crosscanvas  "$ORG/CrossCanvas.git"
clone_one pingcanvas   "$ORG/PingCanvas.git"
clone_one snmpcanvas   "$ORG/SNMPCanvas.git"
clone_one syslogcanvas "$ORG/SyslogCanvas.git"
clone_one alertcanvas  "$ORG/AlertCanvas.git"
clone_one launchcanvas "$ORG/LaunchCanvas.git"

# ----- 5. optional board seed ------------------------------------------------
if [ -n "$BOARD" ]; then
    [ -f "$BOARD" ] || die "board file not found: $BOARD"
    # Never clobber a live board on a re-run - it may have been refined via
    # LaunchCanvas uploads since install. Delete it (or upload) to replace.
    if [ -f "$DATA_ROOT/board.xcanvas" ]; then
        warn "board.xcanvas already exists - keeping it (delete it first, or upload via LaunchCanvas, to replace)"
    else
        say "Seeding board -> $DATA_ROOT/board.xcanvas"
        sudo cp "$BOARD" "$DATA_ROOT/board.xcanvas"
        sudo chown "$APP_UID:$APP_UID" "$DATA_ROOT/board.xcanvas"
    fi
fi

# ----- 5b. optional subnet scan -> auto-seeded board -------------------------
# nmap -sn gives IP + hostname + (on-segment, as root) the NIC's MAC-vendor.
# A tiny board builder runs in node:22-alpine (docker auto-pulls it here; the
# AlertCanvas build below reuses the same cached image, so no new host
# dependency), lays the hosts out in a grid, and guesses a VM stencil from the
# well-known hypervisor OUIs - a hostname lies, a VMware/Hyper-V/KVM prefix does
# not. For the full stencil heuristics, re-import the same scan through the
# editor's File -> Import Inventory later.
if [ -n "$SCAN" ]; then
    command -v nmap >/dev/null 2>&1 || { say "Installing nmap"; pkg_install nmap; }
    say "Ping-scanning $SCAN (nmap -sn)"
    TMP="$(mktemp -d)"
    # -sn = no port scan; sudo so nmap can ARP the segment for MAC vendors.
    # --scan takes one or more targets, comma- or space-separated; each becomes
    # its own nmap target spec (nmap concatenates the host reports).
    read -ra SCAN_TARGETS <<< "${SCAN//,/ }"
    for t in "${SCAN_TARGETS[@]}"; do
        case "$t" in
            */*|*-*|*\**) : ;;  # CIDR or nmap range syntax
            [0-9]*.[0-9]*.[0-9]*.[0-9]*)
                warn "--scan target $t has no /prefix - nmap probes it as ONE host (and a .0 network address answers nothing). Did you mean $t/24?" ;;
            *) : ;;  # bare hostname - a deliberate single-host target
        esac
    done
    # shellcheck disable=SC2024  # user-owned output is intended; sudo is only for nmap's ARP privilege
    sudo nmap -sn "${SCAN_TARGETS[@]}" > "$TMP/scan.txt" 2>/dev/null || warn "nmap reported errors; using whatever it found"
    cat > "$TMP/build.js" <<'BUILDER'
'use strict';
// Minimal nmap -> board.xcanvas builder for the --scan flag. Grid layout, one
// pingable device per host. The VM-OUI set mirrors CrossCanvas app.js's
// guessNmapStencil (immutable OUI data); for the full heuristics, re-import the
// scan through the editor. Reads the nmap text file named in argv[2].
const fs = require('fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
const VM_OUIS = new Set(['000c29','005056','000569','001c14','00155d','080027','525400','00163e','001c42']);
function guess(vendor, mac) {
    const v = String(vendor || '').toLowerCase();
    const oui = String(mac || '').toLowerCase().replace(/[^0-9a-f]/g, '').slice(0, 6);
    if (VM_OUIS.has(oui) || /vmware|virtualbox|parallels|\bxen\b|qemu|\bkvm\b|proxmox/.test(v)) return 'VM';
    if (/axis communication|hikvision|dahua|mobotix|hanwha|hangzhou/.test(v)) return 'Camera';
    if (/\bapc\b|american power|cyberpower|\beaton\b|tripp.?lite|schneider/.test(v)) return 'UPS';
    if (/\bzebra\b/.test(v)) return 'Printer';
    return 'Server';   // generic pingable host
}
const hosts = [];
let cur = null;
const flush = () => { if (cur && /^\d{1,3}(\.\d{1,3}){3}$/.test(cur.ip)) hosts.push(cur); cur = null; };
for (const line of text.split(/\r?\n/)) {
    let m = line.match(/Nmap scan report for (?:(\S+)\s+\((\d{1,3}(?:\.\d{1,3}){3})\)|(\d{1,3}(?:\.\d{1,3}){3}))/i);
    if (m) { flush(); cur = { host: m[1] || '', ip: m[2] || m[3], mac: '', vendor: '' }; continue; }
    m = line.match(/MAC Address:\s+([0-9a-fA-F:]{17})\s*(?:\(([^)]*)\))?/i);
    if (m && cur) { cur.mac = m[1]; cur.vendor = (m[2] || '').trim(); }
}
flush();
const seen = new Set();
const uniq = hosts.filter((h) => !seen.has(h.ip) && seen.add(h.ip));
const AP = (w, h) => [{ rx: w/2, ry: 0 },{ rx: w, ry: 0 },{ rx: w, ry: h/2 },{ rx: w, ry: h },{ rx: w/2, ry: h },{ rx: 0, ry: h },{ rx: 0, ry: h/2 },{ rx: 0, ry: 0 }];
const short = (h) => (h || '').split('.')[0];
const PERROW = 6, DX = 150, DY = 150, X0 = 80, Y0 = 80;
const devices = uniq.map((h, i) => {
    const label = h.host ? short(h.host) : h.ip;
    return {
        id: 'n' + i, templateId: 'n' + i + 't', image: '@' + guess(h.vendor, h.mac),
        originalImage: '@' + guess(h.vendor, h.mac),
        x: X0 + (i % PERROW) * DX, y: Y0 + Math.floor(i / PERROW) * DY, w: 60, h: 60,
        label, labelPosition: 'bottom', fontSize: 14, fontColor: '#333333',
        lineFormats: [{ bold: false, italic: false }],
        spans: [[{ text: label, bold: false, italic: false }]],
        tintColor: null, attachmentPoints: AP(60, 60),
        fields: Object.assign({ 'IP-Address': h.ip },
            h.host ? { Hostname: h.host } : {}, h.mac ? { 'MAC Address': h.mac } : {},
            (h.vendor && !/^unknown$/i.test(h.vendor)) ? { Description: h.vendor } : {})
    };
});
const board = {
    version: 6, appVersion: 'scan', savedAt: new Date().toISOString(),
    diagramTitle: 'scan', diagramVersion: 1, devices,
    connections: [], zones: [], textBoxes: [], images: [], groups: [],
    deviceTemplates: [], imageTable: {}, nextId: 100 + devices.length
};
process.stdout.write(JSON.stringify(board));
BUILDER
    # shellcheck disable=SC2024  # user-owned output is intended; sudo is only for the docker socket
    sudo docker run --rm -v "$TMP":/w:ro,z node:22-alpine node /w/build.js /w/scan.txt > "$TMP/board.xcanvas" 2>/dev/null
    COUNT="$(grep -o '"IP-Address"' "$TMP/board.xcanvas" 2>/dev/null | wc -l | tr -d ' ')"
    if [ -f "$DATA_ROOT/board.xcanvas" ]; then
        warn "board.xcanvas already exists - keeping it; the scan result was not applied (delete the board first to reseed)"
    elif [ -s "$TMP/board.xcanvas" ] && [ "${COUNT:-0}" -gt 0 ]; then
        sudo cp "$TMP/board.xcanvas" "$DATA_ROOT/board.xcanvas"
        sudo chown "$APP_UID:$APP_UID" "$DATA_ROOT/board.xcanvas"
        ok "Seeded board from scan: $COUNT device(s) (VMs auto-iconed; edit in CrossCanvas to arrange)"
    else
        warn "Scan produced no usable board (nothing responded, or nmap needs root on this segment) - draw one in the editor instead."
    fi
    rm -rf "$TMP"
fi

# ----- 6. SNMPCanvas secret (idempotent: reuse existing, never regenerate) ---
SNMP_OVR="$PROJ_ROOT/snmpcanvas/docker-compose.override.yml"
SECRET=""; SECRET_IS_NEW=0
if [ -f "$SNMP_OVR" ]; then
    SECRET="$(sed -n 's/.*SNMPCANVAS_SECRET=\([^ ]*\).*/\1/p' "$SNMP_OVR" | head -1)"
fi
if [ -z "$SECRET" ]; then
    SECRET="$(openssl rand -base64 32)"
    SECRET_IS_NEW=1
fi

# The suite SSO secret (LaunchCanvas single sign-on): one value shared by the
# portal and every Node sibling. Same idempotent rule - reuse, never rotate
# silently (rotating logs everyone out, which is a choice, not a side effect).
LAUNCH_OVR="$PROJ_ROOT/launchcanvas/docker-compose.override.yml"
SUITE_SECRET=""
if [ -f "$LAUNCH_OVR" ]; then
    SUITE_SECRET="$(sed -n 's/.*SUITE_SECRET=\([^ ]*\).*/\1/p' "$LAUNCH_OVR" | head -1)"
fi
[ -n "$SUITE_SECRET" ] || SUITE_SECRET="$(openssl rand -base64 32)"

# The portal's first account. Without this, LaunchCanvas boots UNCLAIMED and the
# first person to reach :9160 becomes suite root - and because SSO carries that
# login into every sibling, "whoever gets there first" decides who owns the whole
# install. Seeding locks the door from the first boot. Idempotent like the
# secrets above, and harmless if it ever changes: it only seeds the account when
# none exists yet.
LAUNCH_PW=""; LAUNCH_PW_IS_NEW=0
if [ -f "$LAUNCH_OVR" ]; then
    LAUNCH_PW="$(sed -n 's/.*ADMIN_PASSWORD=\([^ ]*\).*/\1/p' "$LAUNCH_OVR" | head -1)"
fi
if [ -z "$LAUNCH_PW" ]; then
    LAUNCH_PW="$(openssl rand -hex 16)"
    LAUNCH_PW_IS_NEW=1
fi

# ----- 7. override files (untracked; survive every git pull) -----------------
say "Writing docker-compose.override.yml files"

cat > "$PROJ_ROOT/pingcanvas/docker-compose.override.yml" <<YAML
services:
  web:
    volumes:
      - $DATA_ROOT:/usr/share/nginx/html/data:ro,z
      - $DATA_ROOT/certs:/etc/nginx/certs:ro,z
  poller:
    volumes:
      - $DATA_ROOT:/data:z
YAML

cat > "$SNMP_OVR" <<YAML
services:
  snmpcanvas:
    volumes:
      - $DATA_ROOT:/data:z
    environment:
      - TZ=$TZ
      - SNMPCANVAS_SECRET=$SECRET
      - SUITE_SECRET=$SUITE_SECRET
YAML

cat > "$PROJ_ROOT/syslogcanvas/docker-compose.override.yml" <<YAML
services:
  syslogcanvas:
    volumes:
      - $DATA_ROOT/syslogcanvas:/data:z
    environment:
      - TZ=$TZ
      - SUITE_SECRET=$SUITE_SECRET
YAML

# AlertCanvas: own data dir + a read-only view of the shared root for the
# feed (its default status path is /status/snmp-status.json). Same idempotent
# secret rule as SNMPCanvas: reuse, never regenerate.
AC_OVR="$PROJ_ROOT/alertcanvas/docker-compose.override.yml"
AC_SECRET=""
if [ -f "$AC_OVR" ]; then
    AC_SECRET="$(sed -n 's/.*ALERTCANVAS_SECRET=\([^ ]*\).*/\1/p' "$AC_OVR" | head -1)"
fi
[ -n "$AC_SECRET" ] || AC_SECRET="$(openssl rand -base64 32)"
cat > "$AC_OVR" <<YAML
services:
  alertcanvas:
    volumes:
      - $DATA_ROOT/alertcanvas:/data:z
      - $DATA_ROOT:/status:ro,z
    environment:
      - TZ=$TZ
      - ALERTCANVAS_SECRET=$AC_SECRET
      - SUITE_SECRET=$SUITE_SECRET
YAML

# LaunchCanvas: own data dir, plus the shared root writable at /boards so
# board uploads land exactly where PingCanvas's kiosk reads them.
cat > "$LAUNCH_OVR" <<YAML
services:
  launchcanvas:
    volumes:
      - $DATA_ROOT/launchcanvas:/data:z
      - $DATA_ROOT:/boards:z
    environment:
      - TZ=$TZ
      - SUITE_SECRET=$SUITE_SECRET
      - ADMIN_PASSWORD=$LAUNCH_PW
YAML

# These files hold every secret in the deployment: the SSO key (which mints a
# valid session for ANY username on every sibling), both credential-encryption
# keys, and the portal password. The default umask leaves them world-readable
# inside a 0755 /projects, so any local account could read them and own the
# whole suite without ever touching the network.
for f in "$PROJ_ROOT"/*/docker-compose.override.yml; do
    [ -f "$f" ] && chmod 600 "$f"
done
ok "Overrides written (chmod 600 - they hold your secrets)"

# ----- 8. TLS certs (before first 'up', so HTTPS is on from boot) ------------
if [ "$GEN_TLS" = 1 ]; then
    if [ ! -f "$DATA_ROOT/certs/server.crt" ]; then
        say "Generating SNMPCanvas cert (SAN: $BOX_IP, $HOST_FQDN)"
        ( cd "$PROJ_ROOT/snmpcanvas" && CERT_DIR="$DATA_ROOT/certs" sh tools/gen-cert.sh "$BOX_IP" "$HOST_FQDN" >/dev/null )
    else ok "SNMPCanvas cert exists - kept"; fi

    if [ ! -f "$DATA_ROOT/syslogcanvas/certs/server.crt" ]; then
        say "Generating SyslogCanvas cert"
        ( cd "$PROJ_ROOT/syslogcanvas" && CERT_DIR="$DATA_ROOT/syslogcanvas/certs" sh tools/gen-cert.sh "$BOX_IP" "$HOST_FQDN" >/dev/null )
    else ok "SyslogCanvas cert exists - kept"; fi

    if [ ! -f "$DATA_ROOT/certs/fullchain.pem" ]; then
        say "Generating PingCanvas cert"
        ( cd "$PROJ_ROOT/pingcanvas" && CERT_DIR="$DATA_ROOT/certs" bash docker/gen-selfsigned-cert.sh "$BOX_IP" >/dev/null )
    else ok "PingCanvas cert exists - kept"; fi

    if [ ! -f "$DATA_ROOT/alertcanvas/certs/server.crt" ]; then
        say "Generating AlertCanvas cert"
        ( cd "$PROJ_ROOT/alertcanvas" && CERT_DIR="$DATA_ROOT/alertcanvas/certs" sh tools/gen-cert.sh "$BOX_IP" "$HOST_FQDN" >/dev/null )
    else ok "AlertCanvas cert exists - kept"; fi

    if [ ! -f "$DATA_ROOT/launchcanvas/certs/server.crt" ]; then
        say "Generating LaunchCanvas cert"
        ( cd "$PROJ_ROOT/launchcanvas" && CERT_DIR="$DATA_ROOT/launchcanvas/certs" sh tools/gen-cert.sh "$BOX_IP" "$HOST_FQDN" >/dev/null )
    else ok "LaunchCanvas cert exists - kept"; fi

    # make sure the container uid can read every key we just wrote
    sudo chown -R "$APP_UID:$APP_UID" "$DATA_ROOT/certs" "$DATA_ROOT/syslogcanvas/certs" "$DATA_ROOT/alertcanvas/certs" "$DATA_ROOT/launchcanvas/certs"
else
    warn "Skipping TLS (--no-tls). The suite serves HTTP only."
fi

# ----- 9. bring the stack up -------------------------------------------------
# PingCanvas first: build-web.sh assembles the editor+kiosk web root from ../crosscanvas.
say "Building + starting PingCanvas (this also bakes in the CrossCanvas editor)"
( cd "$PROJ_ROOT/pingcanvas" && bash docker/build-web.sh && $DC compose up -d --build )

say "Starting SNMPCanvas"
( cd "$PROJ_ROOT/snmpcanvas" && $DC compose up -d --build )

say "Starting SyslogCanvas"
( cd "$PROJ_ROOT/syslogcanvas" && $DC compose up -d --build )

say "Starting AlertCanvas"
( cd "$PROJ_ROOT/alertcanvas" && $DC compose up -d --build )

say "Starting LaunchCanvas"
( cd "$PROJ_ROOT/launchcanvas" && $DC compose up -d --build )

# ----- 10. verify ------------------------------------------------------------
say "Verifying"
$DC compose -f "$PROJ_ROOT/pingcanvas/docker-compose.yml" -f "$PROJ_ROOT/pingcanvas/docker-compose.override.yml" ps >/dev/null 2>&1 || true
sleep 2
# the shared folder is served by PingCanvas's web tier; prove the DB/key 404 guard
# is live. Order matters: if the web tier is not answering, a failed key probe
# would read as "safe" - so the editor check gates the guard check, and with
# --no-tls there is no server.key, so a 404 would prove nothing and is skipped.
if curl -sf "http://$BOX_IP:8080/index.html" >/dev/null 2>&1; then
    ok "Editor is serving"
    if [ "$GEN_TLS" = 1 ]; then
        if curl -sf "http://$BOX_IP:8080/data/certs/server.key" >/dev/null 2>&1; then
            warn "SECURITY: server.key is being served - your PingCanvas is older than 2026-07-19. Rebuild it."
        else ok "Sensitive files 404 as expected (co-location is safe)"; fi
    fi
else
    warn "Editor not reachable yet (containers may still be warming up) - could not verify the"
    warn "sensitive-file 404 guard; check later: curl -i http://$BOX_IP:8080/data/certs/server.key"
fi
LC_S="http"; [ "$GEN_TLS" = 1 ] && LC_S="https"
# shellcheck disable=SC2015  # same deliberate idiom
curl -skf "$LC_S://$BOX_IP:9160/api/health" >/dev/null 2>&1 && ok "LaunchCanvas is serving" || warn "LaunchCanvas not reachable yet (may still be warming up)"

# ----- 11. summary -----------------------------------------------------------
S="http"; [ "$GEN_TLS" = 1 ] && S="https"
echo
printf '%s================ Canvas suite is up ================%s\n' "$B" "$N"
echo "  LaunchCanvas (start here)  $S://$BOX_IP:9160  - one login for the suite"
echo "  CrossCanvas editor   http://$BOX_IP:8080/index.html"
echo "  PingCanvas kiosk     http://$BOX_IP:8080/kiosk.html?board=data/board.xcanvas&status=data/status.json&snmp=data/snmp-status.json"
echo "  SNMPCanvas           $S://$BOX_IP:9161"
echo "  SyslogCanvas         $S://$BOX_IP:9514"
echo "  AlertCanvas          $S://$BOX_IP:9162"
[ "$GEN_TLS" = 1 ] && echo "  (PingCanvas HTTPS also on https://$BOX_IP:8443/ ; HTTP stays on 8080. Self-signed - your browser will warn once.)"
echo
echo "  First visit: open LaunchCanvas and log in as  admin  with the password"
echo "  below. With SSO active that one login carries into SNMPCanvas,"
echo "  SyslogCanvas, and AlertCanvas, and the in-app Quickstart walks the rest"
echo "  of the ten minutes. Change the password from Settings once you are in."
echo
if [ "$LAUNCH_PW_IS_NEW" = 1 ]; then
    printf '  %sSAVE THIS - LaunchCanvas admin password (user: admin):%s\n' "$Y" "$N"
    printf '      %s\n' "$LAUNCH_PW"
    echo "  The portal is already claimed, so nobody on the LAN can take it - but"
    echo "  that also makes this the only way in until you change it."
else
    echo "  Reused the existing LaunchCanvas ADMIN_PASSWORD from the override."
fi
echo
if [ -z "$BOARD" ] && [ ! -f "$DATA_ROOT/board.xcanvas" ]; then
    echo "  Next: draw a board in the editor, export it, and upload it from the"
    echo "        LaunchCanvas Launch page (the kiosk shows a getting-started page until then)."
    echo
fi
if [ "$SECRET_IS_NEW" = 1 ]; then
    printf '  %sSAVE THIS - SNMPCanvas credential-encryption secret:%s\n' "$Y" "$N"
    printf '      %s\n' "$SECRET"
    echo "  It is the ONLY thing that decrypts your SNMP credentials. Copy it into a"
    echo "  password manager now. It lives in $SNMP_OVR, but back it up OFF this box -"
    echo "  losing it means re-entering every device's community/keys."
else
    echo "  Reused the existing SNMPCANVAS_SECRET from the override (not regenerated)."
fi
echo
echo "  All your secrets (SNMPCANVAS_SECRET, ALERTCANVAS_SECRET, SUITE_SECRET) live"
echo "  in the docker-compose.override.yml files under $PROJ_ROOT - back those up"
echo "  alongside $DATA_ROOT. A database restored onto a redeploy only decrypts"
echo "  with the same secrets it was written under."
echo
if [ "$DC" = "sudo docker" ]; then
    printf '  %sNOTE:%s plain "docker" commands will say "permission denied" until you log\n' "$Y" "$N"
    echo "  out and back in once (docker group membership activates on next login;"
    echo "  'newgrp docker' works too). Until then, prefix with sudo. Nothing at"
    echo "  $PROJ_ROOT needs different permissions - it is the Docker socket, not the files."
    echo
fi
echo "  Pairs well with Uptime Kuma (service-level checks and status pages -"
echo "  its own compose stack on 3001, no port conflict with anything here)."
PORTS_TCP="8080/8443"; [ "$GEN_TLS" = 1 ] || PORTS_TCP="8080"
echo "  Firewall: this box now listens on $PORTS_TCP/9160/9161/9162/9514 tcp and 514/162 udp."
