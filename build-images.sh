#!/usr/bin/env bash
# build-images.sh - build every suite app for amd64 AND arm64 and save them as
# offline tarballs, one per architecture.
#
#   ./build-images.sh                      # all apps, amd64 + arm64
#   ./build-images.sh 1.2.0                # tag the images with a version too
#   ./build-images.sh "" amd64             # just amd64
#   APPS="snmpcanvas alertcanvas" ./build-images.sh
#
# Why tarballs and not a registry: `docker save`/`load` is single-architecture,
# so a portable offline artifact has to be one file per arch. Nothing here is
# published anywhere - the output is yours to archive or hand over. Publishing
# to a registry makes you a redistributor of the base image and every npm
# dependency baked in, which is a deliberate decision and not this script's to
# make.
#
# Cross-arch builds need QEMU binfmt on the host, once:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# PingCanvas is NOT built here - it has two images, a web asset build step and a
# base image with no arm64 build, all handled by its own docker/publish.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-}"
shift 2>/dev/null || true
if [ "$#" -gt 0 ]; then ARCHES=("$@"); else ARCHES=(amd64 arm64); fi
APPS="${APPS:-snmpcanvas syslogcanvas alertcanvas launchcanvas}"

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "docker buildx required" >&2; exit 1; }

# Repo discovery: each app's checkout is a sibling of this one, but the folder
# names vary (GitHub ZIPs extract as '<name>-main', and two of the repos sit one
# level deeper inside a same-named parent). Search for the Dockerfile rather
# than assuming a layout, and fail loudly naming what was missing.
find_repo() {
    local app="$1" root
    root="$(cd "$SCRIPT_DIR/.." && pwd)"
    for cand in \
        "$root/$app" "$root/$app/$app" \
        "$root/$app/${app^}"* "$root/${app}-main" "$root/$app/${app^^}"*; do
        [ -f "$cand/Dockerfile" ] && { printf '%s' "$cand"; return 0; }
    done
    # last resort: any sibling whose name starts with the app and holds a Dockerfile
    for cand in "$root/$app"*/ "$root/$app"*/*/; do
        [ -f "${cand}Dockerfile" ] && { printf '%s' "${cand%/}"; return 0; }
    done
    return 1
}

BUILDER=canvas-suite-builder
docker buildx inspect "$BUILDER" >/dev/null 2>&1 || docker buildx create --name "$BUILDER" >/dev/null
docker buildx use "$BUILDER"

# Fail BEFORE building anything if an arch is not actually emulatable - an hour
# into a run is a bad time to discover binfmt was never installed.
avail="$(docker buildx inspect "$BUILDER" --bootstrap 2>/dev/null | sed -n 's/^Platforms: *//p')"
for arch in "${ARCHES[@]}"; do
    case "$avail" in *"linux/$arch"*) ;; *)
        echo "builder cannot target linux/$arch (have: $avail)" >&2
        echo "install emulation first:  docker run --privileged --rm tonistiigi/binfmt --install $arch" >&2
        exit 1 ;;
    esac
done

OUT="$SCRIPT_DIR/dist"; mkdir -p "$OUT"
built=()
for app in $APPS; do
    repo="$(find_repo "$app")" || { echo "!! $app: no checkout with a Dockerfile found next to canvas-suite - skipping" >&2; continue; }
    for arch in "${ARCHES[@]}"; do
        tags=(-t "$app:latest")
        save=("$app:latest")
        if [ -n "$VERSION" ]; then tags+=(-t "$app:$VERSION"); save=("$app:$VERSION" "$app:latest"); fi
        echo ">> $app  linux/$arch${VERSION:+  v$VERSION}   ($repo)"
        docker buildx build --platform "linux/$arch" "${tags[@]}" --load "$repo"
        tarball="$OUT/${app}${VERSION:+-$VERSION}-${arch}.tar.gz"
        docker save "${save[@]}" | gzip > "$tarball"
        echo "   wrote $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"
        built+=("$(basename "$tarball")")
    done
done

echo
echo "dist/ now holds ${#built[@]} tarball(s):"
printf '  %s\n' "${built[@]}"
echo
echo "On the target host, load the one matching its architecture:"
echo "  docker load < <app>-<arch>.tar.gz"
echo "then use the app's own docker-compose.yml (its 'image:' name already matches)."
