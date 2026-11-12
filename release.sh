#!/bin/bash
# Publishes the last build as a GitHub release, with gh:
#   ./release.sh            check the build, then create the release
#   ./release.sh --dry-run  check the build and print the tag and notes
#
# Only a successful build of a clean tree at HEAD is published, and HEAD has to be on GitHub, so a
# release always names the commit it was built from. The tag is the build date and that commit,
# e.g. 2026.11.12-fc5ed90: the U-Boot banner's hash only follows patches/, not files/ or config.diff.
set -euo pipefail

REPO=smazurov/w1700k-boot
DIR="$(dirname "$(readlink -f "$0")")"
cd "$DIR"
OUT=openwrt/bin/targets/airoha/an7581
CHAIN=$OUT/openwrt-airoha-an7581-gemtek_w1700k-ubi-chainload-uboot.itb
REC=$OUT/openwrt-airoha-an7581-gemtek_w1700k-ubi-initramfs-recovery.itb
INFO=$OUT/w1700k-boot.info
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

die() { echo "release.sh: $*" >&2; exit 1; }

[ ! -d .build.lock ] || die "a build is running (.build.lock)"
[ "$(sed -n 's/^exit=//p' build.log 2>/dev/null | tail -1)" = 0 ] || die "the last build did not succeed (build.log)"
[ -f "$INFO" ] && [ -f "$CHAIN" ] && [ -f "$REC" ] || die "no build artifacts with $INFO; run ./build.sh"
info() { sed -n "s/^$1=//p" "$INFO"; }

head=$(git rev-parse HEAD)
[ "$(info commit)" = "$head" ] || die "the build is of $(info commit | cut -c1-7), HEAD is ${head:0:7}; rebuild"
[ "$(info dirty)" = no ] || die "the build was of a tree with uncommitted changes; commit and rebuild"
[ -z "$(git status --porcelain)" ] || die "the tree has uncommitted changes"
git fetch -q origin
git merge-base --is-ancestor "$head" origin/main || die "HEAD ${head:0:7} is not on origin/main; push it first"

tag="$(info built | cut -c1-10 | tr - .)-${head:0:7}"
! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 || die "release $tag exists"

row() {  # name, sha256, size of an artifact
  printf '`%s` | %s B | `%s`' "$(basename "$1")" "$(stat -c %s "$1")" "$(sha256sum "$1" | cut -d' ' -f1)"
}
patches=$(for p in patches/*.patch; do
  sed -n 's/^Subject: \[PATCH[^]]*\] //p' "$p" | head -1 | sed 's/^/- /'
done)
base=$(info base)
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<NOTES
Gemtek W1700K chainloader and recovery image for the UBI layout OpenWrt 26.12 is expected to
ship, built from [$(git rev-parse --short HEAD)](https://github.com/$REPO/tree/$head). Not an
official OpenWrt build.

| File | Size | sha256 |
|---|---|---|
| $(row "$CHAIN") |
| $(row "$REC") |

- U-Boot \`$(info uboot | sed 's/^U-Boot //')\`; recovery image OpenWrt \`$(info revision)\`, $(info kernel), with LuCI.
- Base: [openwrt/openwrt#26296](https://github.com/openwrt/openwrt/pull/26296) at \`${base:0:7}\`, plus:
$(echo "$patches" | sed 's/^/  /')
- NAND: W25N04KV only. W25N04LV has no mainline driver yet (openwrt/openwrt#25532).
- Recovery: hold reset from the red status LED until it turns blue; the recovery system boots from
  the \`recovery\` volume (or TFTP from 192.168.1.254 if that fails), with LuCI at 192.168.1.1 and
  a slowly blinking blue LED.
NOTES

echo "tag: $tag"
cat "$notes"
[ "$DRY" = 0 ] || exit 0

gh release create "$tag" "$CHAIN" "$REC" --repo "$REPO" --target "$head" --title "$tag" --notes-file "$notes"

# GitHub's digests of what it now serves must be the local files'.
for f in "$CHAIN" "$REC"; do
  want="sha256:$(sha256sum "$f" | cut -d' ' -f1)"
  got=$(gh api "repos/$REPO/releases/tags/$tag" \
    --jq ".assets[] | select(.name == \"$(basename "$f")\") | .digest")
  [ "$got" = "$want" ] || die "$(basename "$f"): GitHub has $got, local $want"
done
echo "release.sh: published $tag, digests match"
