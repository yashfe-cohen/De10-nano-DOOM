#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Fetch the Freedoom game data (the free stand-in for DOOM's commercial WADs)
# into data/, which is git-ignored.  Only freedoom1.wad -- the DOOM 1 / Ultimate
# DOOM replacement we target -- is extracted; the release zip is kept so that a
# re-run does not download it again.  Zero WAD bytes ever enter the repository.
#
# Usage: scripts/get_freedoom.sh [--force]
#   --force   extract freedoom1.wad again even if it already exists
#
# Env:
#   FREEDOOM_TAG=v0.13.0   pin a release instead of asking GitHub for "latest"
#   DATA_DIR=/some/path    put the zip and the wad somewhere other than data/

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DATA=${DATA_DIR:-"$ROOT/data"}
REPO=https://github.com/freedoom/freedoom
FORCE=0

die() {
    printf 'get_freedoom: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s [--force]\n' "${0##*/}"
    printf '  --force  extract again even if data/freedoom1.wad already exists\n'
    printf 'env: FREEDOOM_TAG=vX.Y.Z to pin a release, DATA_DIR=/path to relocate\n'
}

while [ $# -gt 0 ]; do
    case $1 in
        -f|--force) FORCE=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument '$1' (try --help)" ;;
    esac
    shift
done

command -v curl >/dev/null 2>&1 || die "curl not found (apt-get install curl)"
command -v python3 >/dev/null 2>&1 || die "python3 not found (see docs/tools.md)"

# Resolve the release tag.  The releases page redirects "latest" to
# .../releases/tag/<tag>, which needs no API quota and no JSON parsing.
tag=${FREEDOOM_TAG:-}
if [ -z "$tag" ]; then
    target=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        --retry 2 "$REPO/releases/latest") ||
        die "cannot reach $REPO/releases/latest -- no network?"
    tag=${target##*/}
    case $tag in
        ''|latest|releases)
            die "could not resolve the latest release tag (got '$target')" ;;
    esac
fi
url="$REPO/releases/download/$tag/freedoom-${tag#v}.zip"

mkdir -p "$DATA"
zip="$DATA/freedoom-${tag#v}.zip"

if [ -s "$zip" ]; then
    printf 'zip:     %s (already downloaded)\n' "${zip#"$ROOT"/}"
else
    printf 'fetching %s\n' "$url"
    curl -fL --retry 2 --proto '=https' -o "$zip.part" "$url" ||
        { rm -f "$zip.part"; die "download failed: $url (see $REPO/releases, or set FREEDOOM_TAG)"; }
    mv "$zip.part" "$zip"
fi

wad="$DATA/freedoom1.wad"
if [ -s "$wad" ] && [ "$FORCE" = 0 ]; then
    printf 'wad:     %s (already extracted, --force to redo)\n' "${wad#"$ROOT"/}"
else
    # python3 reads the zip, so no dependency on the `unzip` tool being present.
    python3 - "$zip" "$wad" <<'PY'
import os, sys, zipfile

zip_path, wad_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as zf:
    names = [n for n in zf.namelist()
             if n == "freedoom1.wad" or n.endswith("/freedoom1.wad")]
    if not names:
        sys.exit("%s: no freedoom1.wad inside (unexpected release layout)" % zip_path)
    payload = zf.read(names[0])

tmp = wad_path + ".part"
with open(tmp, "wb") as fh:
    fh.write(payload)
os.replace(tmp, wad_path)
PY
fi

[ -s "$wad" ] || die "$wad is empty"
size=$(wc -c <"$wad" | tr -d ' ')
[ "$size" -gt 1000000 ] ||
    die "$wad is only $size bytes -- the download is not a real WAD"

sum=$(python3 -c 'import hashlib, sys; \
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$wad")

case $wad in
    "$ROOT"/*)
        if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 &&
            ! git -C "$ROOT" check-ignore -q -- "$wad"; then
            printf 'get_freedoom: warning: %s is not git-ignored, do not commit it\n' \
                "$wad" >&2
        fi ;;
esac

printf '\nrelease: %s\n' "$tag"
printf 'wad:     %s\n' "${wad#"$ROOT"/}"
printf 'size:    %s bytes\n' "$size"
printf 'sha256:  %s\n' "$sum"
