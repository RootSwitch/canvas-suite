#!/usr/bin/env bash
# docker-ready.sh
# https://github.com/RootSwitch/canvas-suite
#
# Prepare a fresh Linux box to run the kind of containers this org ships, and
# nothing more. It installs no application: use it before canvas-suite-setup.sh,
# before dropping in RSConclave, or on its own to answer "is this box ready".
#
# Built for a newly spun-up Ubuntu Server VM; also handles RHEL/Rocky/Fedora.
#
# What our containers assume, and what this therefore checks or fixes:
#   - Docker Engine with compose v2, and a daemon that actually answers
#   - the daemon ENABLED, because the RHEL family does not start it on install
#   - your user in the docker group
#   - bind-mounted host directories owned by uid 1000 (the containers run as a
#     non-root user with that uid; wrong ownership is the usual first-run failure)
#   - SELinux understood rather than fought: our compose files use the ,z mount
#     suffix, so enforcing mode is fine - this reports the state so a MISSING ,z
#     has an obvious explanation
#   - the host firewall, which on Rocky is enabled by default and is why a
#     published port can be unreachable from anywhere but the box itself
#
# SAFE TO RE-RUN, and safe to run first with --check, which changes nothing.
#
# Usage:
#   ./docker-ready.sh [options]
#
#   --check           report only; make no changes, install nothing
#   --ports LIST      open these TCP ports in the host firewall (e.g. 7777,9161)
#   --projects DIR    create a projects root you own      (default: /projects)
#   --data DIR        create a data root owned by uid 1000 (default: none)
#   --no-docker       skip Docker install/verify (checks everything else)
#
# Env vars PROJ_ROOT / DATA_ROOT override the same values.

set -euo pipefail

# ----- config + defaults ----------------------------------------------------
PROJ_ROOT="${PROJ_ROOT:-/projects}"
DATA_ROOT="${DATA_ROOT:-}"
PORTS=""
CHECK_ONLY=0
DO_DOCKER=1
APP_UID=1000                       # the uid our containers run as inside

while [ $# -gt 0 ]; do
    case "$1" in
        --check)      CHECK_ONLY=1; shift ;;
        --ports)      PORTS="$2"; shift 2 ;;
        --projects)   PROJ_ROOT="$2"; shift 2 ;;
        --data)       DATA_ROOT="$2"; shift 2 ;;
        --no-docker)  DO_DOCKER=0; shift ;;
        -h|--help)    sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

# ----- helpers --------------------------------------------------------------
if [ -t 1 ]; then B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); N=$(printf '\033[0m'); else B=; G=; Y=; R=; N=; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
todo() { printf '%s todo%s %s\n' "$Y" "$N" "$*"; }

# In --check mode nothing may change. Route every mutation through this so a
# missed branch is impossible rather than merely unlikely.
run() {
    if [ "$CHECK_ONLY" = 1 ]; then todo "would run: $*"; return 0; fi
    "$@"
}

# Refuse to chown a directory that is not ours to chown. --data gets a
# recursive chown to uid 1000, so a one-token typo (--data /srv) would re-own
# every other service's data on the box, as root, with no way back.
assert_safe_target() {
    local path="$1" label="$2"
    case "$path" in
        /*) : ;;
        *)  die "$label must be an absolute path (got '$path')." ;;
    esac
    local resolved="${path%/}"
    [ -d "$path" ] && resolved="$(cd "$path" && pwd -P)"
    local sys
    for sys in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var; do
        [ "$resolved" = "$sys" ] && die "refusing to use $resolved as the $label: it is a system directory and this script would chown it recursively. Use a dedicated path such as /srv/appdata."
    done
    # Explicit: the loop's last test is false on every safe path, so without
    # this the function returns 1 and set -e kills the script at the call site.
    return 0
}

[ "$(uname -s)" = "Linux" ] || die "this script targets Linux."
command -v sudo >/dev/null 2>&1 || die "sudo not found - run as a user with sudo."
if [ "$CHECK_ONLY" = 0 ]; then
    # Cache the credential up front so the script never stops for a password
    # partway through, where the prompt can hide inside package output.
    sudo -v || die "this script needs sudo access - run as a user with sudo."
fi

# ----- 1. distro ------------------------------------------------------------
PKG=""
if [ -r /etc/os-release ]; then
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" rhel "*|*" fedora "*|*" centos "*) PKG="dnf" ;;
        *) PKG="apt" ;;
    esac
fi
# Unknown distros fall through to apt, which would otherwise die confusingly
# mid-run on openSUSE/Arch/Alpine. Fail loud on families we do not claim.
if [ "$PKG" = "apt" ] && ! command -v apt-get >/dev/null 2>&1; then
    die "unsupported distro: no apt-get or dnf found. This script targets the Debian/Ubuntu and RHEL (Rocky/Alma/Fedora) families."
fi
pkg_install() {
    if [ "$CHECK_ONLY" = 1 ]; then todo "would install: $*"; return 0; fi
    if [ "$PKG" = "dnf" ]; then sudo dnf install -y "$@"
    else sudo apt-get update -qq && sudo apt-get install -y "$@"; fi
}
say "Box: ${PRETTY_NAME:-unknown} (package manager: $PKG)"

# ----- 2. base packages -----------------------------------------------------
# openssl is not optional: every app's tools/gen-cert.sh needs it, and its
# absence surfaces much later as a TLS step that cannot run.
NEED=""
for c in git curl openssl; do command -v "$c" >/dev/null 2>&1 || NEED="$NEED $c"; done
if [ -n "$NEED" ]; then
    say "Installing:$NEED"
    # shellcheck disable=SC2086  # word splitting intended: space-separated list
    pkg_install $NEED
else
    ok "git, curl, openssl present"
fi

# ----- 3. Docker ------------------------------------------------------------
DC=""
if [ "$DO_DOCKER" = 1 ]; then
    if ! command -v docker >/dev/null 2>&1; then
        say "Installing Docker (official convenience script - modern compose v2)"
        if [ "$CHECK_ONLY" = 1 ]; then
            todo "would install Docker via get.docker.com"
        else
            curl -fsSL https://get.docker.com | sudo sh
            sudo usermod -aG docker "$USER" || true
            warn "Added you to the 'docker' group. It takes effect on next login;"
            warn "this run uses 'sudo docker', which needs no re-login."
        fi
    else
        ok "Docker binary present ($(docker --version 2>/dev/null | head -1))"
    fi

    # The RHEL family installs the service without starting or enabling it, so
    # a box that looks fine today comes up dead after a reboot. Fix both.
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-enabled docker >/dev/null 2>&1; then
            say "Enabling the docker service so it survives a reboot"
            run sudo systemctl enable --now docker
        elif ! systemctl is-active docker >/dev/null 2>&1; then
            say "Starting the docker service"
            run sudo systemctl start docker
        else
            ok "docker service enabled and running"
        fi
    fi

    # Prove the DAEMON answers, not just that a CLI exists. 'docker compose
    # version' alone passes with dockerd down, and the failure would otherwise
    # surface as a cryptic socket error inside whatever runs next.
    if [ "$CHECK_ONLY" = 1 ] && ! command -v docker >/dev/null 2>&1; then
        todo "would verify the docker daemon answers"
    elif docker info >/dev/null 2>&1; then
        DC="docker"; ok "Docker daemon answering (as $USER, no sudo needed)"
    elif sudo docker info >/dev/null 2>&1; then
        DC="sudo docker"
        ok "Docker daemon answering (needs sudo until you log out and back in)"
    else
        die "Docker is installed but the daemon is not answering - start it with:  sudo systemctl enable --now docker   then re-run."
    fi
    if [ -n "$DC" ]; then
        $DC compose version >/dev/null 2>&1 \
            || die "docker compose v2 not available (got compose v1?). Reinstall Docker via get.docker.com."
        ok "compose v2 present ($($DC compose version --short 2>/dev/null || echo v2))"
    fi

    # Group membership, handled outside the install branch: Docker may already
    # have been here while this user was never added.
    if getent group docker >/dev/null 2>&1 \
       && ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        say "Adding $USER to the docker group"
        run sudo usermod -aG docker "$USER"
    fi
fi

# Distinguish the two states that both look like "docker says permission
# denied": not in the group at all, versus in it but the shell predates the
# change. Only the second is fixed by logging out, and inferring it from
# "did we need sudo" gets it wrong when sudo failed for another reason.
#   id -nG "$USER"  asks the account database (updated by usermod immediately)
#   id -nG          asks THIS process (unchanged until a new login)
GROUP_PENDING=0
if [ "$CHECK_ONLY" = 0 ] && getent group docker >/dev/null 2>&1; then
    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker \
       && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        GROUP_PENDING=1
    fi
fi

# ----- 4. directories -------------------------------------------------------
# Two different ownership rules, and mixing them up is the usual first-run
# failure. A projects root holds git checkouts and belongs to YOU. A data root
# is bind-mounted into containers that run as uid 1000 and must belong to THAT.
if [ -n "$PROJ_ROOT" ]; then
    assert_safe_target "$PROJ_ROOT" "projects root"
    if [ -d "$PROJ_ROOT" ]; then
        ok "projects root exists: $PROJ_ROOT"
    else
        say "Creating projects root $PROJ_ROOT (owned by $USER)"
        run sudo mkdir -p "$PROJ_ROOT"
        run sudo chown "$USER:$USER" "$PROJ_ROOT"
    fi
fi
if [ -n "$DATA_ROOT" ]; then
    assert_safe_target "$DATA_ROOT" "data root"
    say "Creating data root $DATA_ROOT (owned by container uid $APP_UID)"
    run sudo mkdir -p "$DATA_ROOT"
    run sudo chown -R "$APP_UID:$APP_UID" "$DATA_ROOT"
    # Only claim it when it is true: in --check nothing ran, and an "ok" line
    # asserting state that was never changed is exactly the kind of report that
    # gets believed later.
    [ "$CHECK_ONLY" = 0 ] && ok "data root owned by uid $APP_UID - containers can write to it"
fi

# ----- 5. firewall ----------------------------------------------------------
# On Rocky, firewalld is enabled by default, so a published port is reachable
# from the box and nowhere else. On Ubuntu, ufw usually exists but is inactive,
# in which case opening a port is a no-op worth saying out loud.
FW="none"
command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1 && FW="firewalld"
[ "$FW" = "none" ] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active' && FW="ufw"

if [ -n "$PORTS" ]; then
    if [ "$FW" = "none" ]; then
        warn "no active host firewall found - ports $PORTS need no rule here."
        warn "If something upstream filters this box, open them there instead."
    else
        say "Opening $PORTS/tcp in $FW"
        OLD_IFS="$IFS"; IFS=','
        for p in $PORTS; do
            IFS="$OLD_IFS"
            case "$p" in
                ''|*[!0-9]*) die "'$p' is not a port number (--ports takes a comma-separated list, e.g. 7777,9161)." ;;
            esac
            if [ "$FW" = "firewalld" ]; then
                run sudo firewall-cmd --permanent --add-port="$p/tcp"
            else
                run sudo ufw allow "$p/tcp"
            fi
            IFS=','
        done
        IFS="$OLD_IFS"
        [ "$FW" = "firewalld" ] && run sudo firewall-cmd --reload
        ok "ports opened in $FW"
    fi
else
    say "Host firewall: $FW  (pass --ports to open any)"
fi

# ----- 6. report ------------------------------------------------------------
# Everything below is observation. It changes nothing and exists so a surprise
# later has an explanation you already read once.
say "Environment report"

if command -v getenforce >/dev/null 2>&1; then
    SE="$(getenforce 2>/dev/null || echo unknown)"
    if [ "$SE" = "Enforcing" ]; then
        ok "SELinux Enforcing - our compose files use the ,z mount suffix, so this is fine."
        warn "A bind mount WITHOUT ,z will read as 'Permission denied' inside the container."
    else
        ok "SELinux $SE"
    fi
else
    ok "SELinux not present"
fi

if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
        ok "clock synchronised ($(timedatectl show -p Timezone --value 2>/dev/null))"
    else
        warn "clock is NOT synchronised. Certificates, retention windows and log"
        warn "correlation all depend on it. Fix with: sudo timedatectl set-ntp true"
    fi
fi

# A port already in use is the collision this org keeps hitting. Name the
# occupant where the RS registry knows it, so "7777 is taken" becomes "7777 is
# taken by the thing you already deployed".
if [ -n "$PORTS" ] && command -v ss >/dev/null 2>&1; then
    OLD_IFS="$IFS"; IFS=','
    for p in $PORTS; do
        IFS="$OLD_IFS"
        if ss -ltn 2>/dev/null | grep -qE "[:.]$p[[:space:]]"; then
            case "$p" in
                7777) who=" (RSConclave, per the RS port registry)" ;;
                8080|8443) who=" (PingCanvas)" ;;
                9160) who=" (LaunchCanvas)" ;;
                9161) who=" (SNMPCanvas)" ;;
                9162) who=" (AlertCanvas)" ;;
                9514) who=" (SyslogCanvas)" ;;
                *) who="" ;;
            esac
            warn "port $p is already listening$who - a second container publishing it will fail to start."
        fi
        IFS=','
    done
    IFS="$OLD_IFS"
fi

DISK="$(df -h --output=avail / 2>/dev/null | tail -1 | tr -d ' ' || echo unknown)"
ok "root filesystem free: $DISK"
if [ -n "$DC" ]; then
    ok "storage driver: $($DC info --format '{{.Driver}}' 2>/dev/null || echo unknown)"
fi

echo
if [ "$CHECK_ONLY" = 1 ]; then
    say "Check only - nothing was changed. Re-run without --check to apply."
else
    say "Box is ready. Next:"
    echo "  - Canvas suite:  ./canvas-suite-setup.sh"
    echo "  - anything else: drop the project in $PROJ_ROOT and 'docker compose up -d'"
fi

# LAST, and loud. This is the one thing a person walks away without doing, and
# it resurfaces minutes later as "permission denied while trying to connect to
# the Docker daemon socket" - which reads like a broken install rather than a
# stale shell. Anything printed after this gets scrolled past.
if [ "$GROUP_PENDING" = 1 ]; then
    echo
    printf '%s============================================================%s\n' "$Y" "$N"
    printf '%s  YOUR SHELL IS STALE - log out and back in before using docker%s\n' "$Y" "$N"
    printf '%s============================================================%s\n' "$Y" "$N"
    echo "  You are in the 'docker' group now, but THIS session started before"
    echo "  that was true, so plain 'docker' commands will say:"
    echo
    echo "      permission denied while trying to connect to the Docker daemon socket"
    echo
    echo "  That is a stale shell, not a broken install. Any one of these fixes it:"
    echo "      log out and back in       (the real fix, and it persists)"
    echo "      newgrp docker             (this shell only, right now)"
    echo "      prefix commands with sudo (works immediately, no re-login)"
    echo
fi

# End on a known-good status. A trailing '&&' chain here returns non-zero when
# its last test is false, which would fail a perfectly healthy run.
exit 0
