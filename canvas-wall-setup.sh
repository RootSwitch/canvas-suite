#!/usr/bin/env bash
# canvas-wall-setup.sh
# https://github.com/RootSwitch/canvas-suite
#
# One-shot deploy of the LIGHTWEIGHT PAIR: PingCanvas + AlertCanvas - a ping
# wall that pages you. No SNMP, no syslog, no portal; the only interconnect
# is the poller's status file. Light enough for a Pi. For the whole suite,
# use canvas-suite-setup.sh instead.
#
#   CrossCanvas  - the editor (served BY PingCanvas's web container; cloned as a build input)
#   PingCanvas   - reachability kiosk + poller   8080/tcp http, 8443/tcp https
#   AlertCanvas  - ping alerting (email/ntfy/syslog)   9162/tcp
#
# AlertCanvas runs in ping-only mode (STATUS_FILE=off): it reads the poller's
# combined status-all.json and alarms on the devices you opt in on its
# Watching page - nothing else, no SNMP-feed watchdog.
#
# SAFE TO RE-RUN. Never regenerates ALERTCANVAS_SECRET, never touches existing
# history or certs; re-running reconciles the box to this layout.
#
# Usage:
#   sudo-capable user runs:  ./canvas-wall-setup.sh [options]
#
#   --ip ADDR         address the box is reached at   (default: auto-detected)
#   --board FILE      seed this .xcanvas as the kiosk board (default: none; upload later)
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
APP_UID=1000                       # the uid AlertCanvas runs as inside the container
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
        -h|--help)  sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

# ----- helpers --------------------------------------------------------------
if [ -t 1 ]; then B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); N=$(printf '\033[0m'); else B=; G=; Y=; R=; N=; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Read a value back out of an override file on a re-run. This script writes
# `- KEY=value`, but a hand-edited file may quote the value or use the YAML
# mapping form, and a commented-out old line must never win - the previous
# pattern mis-read all three, and a mis-read secret is silently replaced by a
# fresh one that can no longer decrypt what the old one wrote.
read_secret() {
    local key="$1" file="$2" line=""
    [ -f "$file" ] || return 0
    line="$(grep -E "^[[:space:]]*-?[[:space:]]*[\"']?${key}[=:]" "$file" | head -1 || true)"
    [ -n "$line" ] || return 0
    line="${line#*[=:]}"                        # drop everything up to the separator
    line="${line#"${line%%[![:space:]]*}"}"     # ltrim
    line="${line%"${line##*[![:space:]]}"}"     # rtrim
    line="${line%\"}"; line="${line#\"}"        # unwrap "..."
    line="${line%\'}"; line="${line#\'}"        # unwrap '...'
    printf '%s' "$line"
}

# Refuse to point the installer at a directory that is not ours. Both roots get
# `sudo chown -R`, so a one-token typo (--data /srv instead of /srv/noc-data)
# would silently re-own every other service's data on the box, as root.
assert_safe_target() {
    local path="$1" label="$2"; shift 2
    case "$path" in
        /*) : ;;
        *)  die "$label must be an absolute path (got '$path')." ;;
    esac
    local resolved="${path%/}"
    [ -d "$path" ] && resolved="$(cd "$path" && pwd -P)"
    local sys
    for sys in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var; do
        [ "$resolved" = "$sys" ] && die "refusing to use $resolved as the $label: it is a system directory and this script chowns its target recursively. Use a dedicated path such as /srv/noc-data."
    done
    # sudo -n so this can never sit at a password prompt; a directory we cannot
    # list reads as empty and falls through, as it did before this guard.
    if [ -d "$resolved" ] && [ -n "$(sudo -n ls -A "$resolved" 2>/dev/null || ls -A "$resolved" 2>/dev/null)" ]; then
        local marker found=0
        for marker in "$@"; do
            [ -e "$resolved/$marker" ] && { found=1; break; }
        done
        [ "$found" = 1 ] || die "$resolved already holds content that does not look like a Canvas suite $label, and this script would chown it recursively. Point it at a new or existing suite directory instead."
    fi
}

# Stop rather than mint a replacement when a key is present but unreadable.
assert_readable() {
    local key="$1" file="$2" val="$3"
    if [ -z "$val" ] && [ -f "$file" ] && grep -q "$key" "$file"; then
        die "$file mentions $key but no value could be read from it. Refusing to mint a replacement - anything encrypted under the old secret would become unreadable. Fix that line (or move the file aside) and re-run."
    fi
}

[ "$(uname -s)" = "Linux" ] || die "this script targets Linux."
command -v sudo >/dev/null 2>&1 || die "sudo not found - run as a user with sudo."
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
# cert SANs, and the verify curls - quietly.
BOX_IP="$(printf '%s' "$BOX_IP" | tr -d ' ,\t\r\n')"
case "$BOX_IP" in
    *[!0-9.]*)
        printf '%s' "$BOX_IP" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
            || die "'$BOX_IP' is not a valid IP address or hostname." ;;
    *)
        printf '%s' "$BOX_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
            || die "'$BOX_IP' is not a valid IPv4 address (check --ip for typos)." ;;
esac
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"

# ----- 3. directories --------------------------------------------------------
assert_safe_target "$DATA_ROOT" "data root" \
    certs board.xcanvas alertcanvas status.json status-all.json
assert_safe_target "$PROJ_ROOT" "projects root" crosscanvas pingcanvas alertcanvas

say "Creating shared data root at $DATA_ROOT (owned by container uid $APP_UID)"
sudo mkdir -p "$DATA_ROOT/certs" "$DATA_ROOT/alertcanvas/certs"
sudo chown -R "$APP_UID:$APP_UID" "$DATA_ROOT"
# The shared root stays world-readable - the kiosk's nginx runs as another uid
# and serves boards out of it. AlertCanvas's subdir holds only its database.
[ -d "$DATA_ROOT/alertcanvas" ] && sudo chmod 750 "$DATA_ROOT/alertcanvas"

say "Creating repo root at $PROJ_ROOT (owned by you, so clones need no sudo)"
sudo mkdir -p "$PROJ_ROOT"
sudo chown "$USER:$USER" "$PROJ_ROOT"

# ----- 4. clone the three repos (crosscanvas is the editor build input) ------
clone_one() {
    name="$1"; url="$2"; dir="$PROJ_ROOT/$name"
    if [ -d "$dir/.git" ]; then
        if [ "$DO_UPDATE" = 1 ]; then say "Updating $name"; git -C "$dir" pull --ff-only || warn "$name: pull skipped (local changes?)"
        else ok "$name already cloned (use --update to pull)"; fi
    else
        say "Cloning $name"; GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$url" "$dir"
    fi
}
clone_one crosscanvas "$ORG/CrossCanvas.git"
clone_one pingcanvas  "$ORG/PingCanvas.git"
clone_one alertcanvas "$ORG/AlertCanvas.git"

# ----- 5. optional board seed ------------------------------------------------
if [ -n "$BOARD" ]; then
    [ -f "$BOARD" ] || die "board file not found: $BOARD"
    # Never clobber a live board on a re-run - it may have been refined since
    # install. Delete it to replace.
    if [ -f "$DATA_ROOT/board.xcanvas" ]; then
        warn "board.xcanvas already exists - keeping it (delete it first to replace)"
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
    # `|| true`: grep exits 1 when a scan found nothing, and under pipefail +
    # errexit that killed the whole run right here - silently, with the friendly
    # "scan produced no usable board" branch below left unreachable.
    COUNT="$(grep -o '"IP-Address"' "$TMP/board.xcanvas" 2>/dev/null | wc -l | tr -d ' ' || true)"
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

# ----- 6. override files (untracked; survive every git pull) -----------------
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

# AlertCanvas in PING-ONLY mode: STATUS_FILE=off disables the SNMP feed and
# its watchdog (seeded on first boot); the ping feed default is already
# /status/status-all.json, which the poller writes (COMBINED=1 is its docker
# default). Same idempotent secret rule as the full suite: reuse, never
# regenerate.
AC_OVR="$PROJ_ROOT/alertcanvas/docker-compose.override.yml"
AC_SECRET="$(read_secret ALERTCANVAS_SECRET "$AC_OVR")"
assert_readable ALERTCANVAS_SECRET "$AC_OVR" "$AC_SECRET"
[ -n "$AC_SECRET" ] || AC_SECRET="$(openssl rand -base64 32)"
cat > "$AC_OVR" <<YAML
services:
  alertcanvas:
    volumes:
      - $DATA_ROOT/alertcanvas:/data:z
      - $DATA_ROOT:/status:ro,z
    environment:
      - TZ=$TZ
      - STATUS_FILE=off
      - ALERTCANVAS_SECRET=$AC_SECRET
YAML

# ALERTCANVAS_SECRET decrypts the stored SMTP password and ntfy token, and the
# default umask would leave this file world-readable inside a 0755 /projects.
for f in "$PROJ_ROOT"/*/docker-compose.override.yml; do
    [ -f "$f" ] && chmod 600 "$f"
done
ok "Overrides written (chmod 600 - they hold your secrets)"

# ----- 7. TLS certs (before first 'up', so HTTPS is on from boot) ------------
if [ "$GEN_TLS" = 1 ]; then
    if [ ! -f "$DATA_ROOT/certs/fullchain.pem" ]; then
        say "Generating PingCanvas cert (SAN: $BOX_IP)"
        ( cd "$PROJ_ROOT/pingcanvas" && CERT_DIR="$DATA_ROOT/certs" bash docker/gen-selfsigned-cert.sh "$BOX_IP" >/dev/null )
    else ok "PingCanvas cert exists - kept"; fi

    if [ ! -f "$DATA_ROOT/alertcanvas/certs/server.crt" ]; then
        say "Generating AlertCanvas cert"
        ( cd "$PROJ_ROOT/alertcanvas" && CERT_DIR="$DATA_ROOT/alertcanvas/certs" sh tools/gen-cert.sh "$BOX_IP" "$HOST_FQDN" >/dev/null )
    else ok "AlertCanvas cert exists - kept"; fi

    sudo chown -R "$APP_UID:$APP_UID" "$DATA_ROOT/certs" "$DATA_ROOT/alertcanvas/certs"
else
    warn "Skipping TLS (--no-tls). The pair serves HTTP only."
fi

# ----- 8. bring the stack up -------------------------------------------------
say "Building + starting PingCanvas (this also bakes in the CrossCanvas editor)"
( cd "$PROJ_ROOT/pingcanvas" && bash docker/build-web.sh && $DC compose up -d --build )

say "Starting AlertCanvas"
( cd "$PROJ_ROOT/alertcanvas" && $DC compose up -d --build )

# ----- 9. verify -------------------------------------------------------------
say "Verifying"
sleep 2
# The editor check gates the sensitive-file probe: a down web tier would make
# a failed key probe read as "safe". With --no-tls there is no server.key, so
# a 404 would prove nothing and the probe is skipped.
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
S="http"; [ "$GEN_TLS" = 1 ] && S="https"
# shellcheck disable=SC2015  # same deliberate idiom
curl -skf "$S://$BOX_IP:9162/api/health" >/dev/null 2>&1 && ok "AlertCanvas is serving" || warn "AlertCanvas not reachable yet (may still be warming up)"

# ----- 10. summary -----------------------------------------------------------
# The editor and the kiosk are two pages on ONE web server; with TLS on, lead
# with the HTTPS form of both so nobody has to infer it from a footnote.
WEBPORT="8080"; [ "$GEN_TLS" = 1 ] && WEBPORT="8443"
echo
printf '%s============ PingCanvas + AlertCanvas pair is up ============%s\n' "$B" "$N"
echo "  CrossCanvas editor   $S://$BOX_IP:$WEBPORT/index.html"
echo "  PingCanvas kiosk     $S://$BOX_IP:$WEBPORT/kiosk.html?board=data/board.xcanvas&status=data/status.json"
echo "  AlertCanvas          $S://$BOX_IP:9162  - set the admin password promptly"
if [ "$GEN_TLS" = 1 ]; then
    echo "  (The editor and kiosk share one web server: HTTPS on 8443, plain HTTP"
    echo "  still on 8080 - same pages either way. Self-signed cert, so your"
    echo "  browser warns once per host.)"
fi
echo
echo "  First visit: draw a board in the editor - or skip the drawing entirely:"
echo "  run a ping scan (nmap -sn <your-subnet>), paste the output into the"
echo "  editor's File -> Import Inventory paste box, and the subnet lands as"
echo "  devices with IP-Addresses already set. Save the board as"
echo "  $DATA_ROOT/board.xcanvas and the kiosk comes alive. Then open"
echo "  AlertCanvas -> Watching, check the devices that should page you (your"
echo "  ISPs, an internet canary), give them notification labels, and add an"
echo "  email/ntfy/syslog channel in Settings."
echo
if [ "$DC" = "sudo docker" ]; then
    printf '  %sNOTE:%s plain "docker" commands will say "permission denied" until you log\n' "$Y" "$N"
    echo "  out and back in once (docker group membership activates on next login;"
    echo "  'newgrp docker' works too). Until then, prefix with sudo. Nothing at"
    echo "  $PROJ_ROOT needs different permissions - it is the Docker socket, not the files."
    echo
fi
echo "  Your ALERTCANVAS_SECRET lives in the docker-compose.override.yml under"
echo "  $PROJ_ROOT - back it up alongside $DATA_ROOT. A database restored onto a"
echo "  redeploy only decrypts with the same secret it was written under."
echo
echo "  Want SNMP graphs, syslog history, or the suite portal later? The full"
echo "  suite installs over this layout: run canvas-suite-setup.sh (from the same"
echo "  repo: https://github.com/RootSwitch/canvas-suite) on this box and flip"
echo "  AlertCanvas's status file path from 'off' to the SNMP feed."
echo "  Firewall: this box now listens on 8080/8443/9162 tcp."
