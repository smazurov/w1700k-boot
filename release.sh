#!/bin/bash
# Publishes the last build as a GitHub release, with gh:
#   ./release.sh                 check the build, then create the release
#   ./release.sh --dry-run       check the build and print the tag and notes
#   ./release.sh --update-notes  rewrite the notes of the release of the last build (assets untouched)
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
MODE=create
case "${1:-}" in
  "") ;;
  --dry-run) MODE=dry ;;
  --update-notes) MODE=notes ;;
  *) echo "usage: $0 [--dry-run | --update-notes]" >&2; exit 2 ;;
esac

die() { echo "release.sh: $*" >&2; exit 1; }
digest() {  # GitHub's digest of a release asset
  gh api "repos/$REPO/releases/tags/$1" --jq ".assets[] | select(.name == \"$(basename "$2")\") | .digest"
}

[ ! -d .build.lock ] || die "a build is running (.build.lock)"
[ "$(sed -n 's/^exit=//p' build.log 2>/dev/null | tail -1)" = 0 ] || die "the last build did not succeed (build.log)"
[ -f "$INFO" ] && [ -f "$CHAIN" ] && [ -f "$REC" ] || die "no build artifacts with $INFO; run ./build.sh"
info() { sed -n "s/^$1=//p" "$INFO"; }
[ "$(info dirty)" = no ] || die "the build was of a tree with uncommitted changes; commit and rebuild"
built=$(info commit)
tag="$(info built | cut -c1-10 | tr - .)-${built:0:7}"

if [ "$MODE" = notes ]; then
  gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 || die "release $tag does not exist"
  for f in "$CHAIN" "$REC"; do  # the notes describe the files the release serves
    [ "$(digest "$tag" "$f")" = "sha256:$(sha256sum "$f" | cut -d' ' -f1)" ] ||
      die "$(basename "$f") of $tag is not the last build's"
  done
else
  head=$(git rev-parse HEAD)
  [ "$built" = "$head" ] || die "the build is of ${built:0:7}, HEAD is ${head:0:7}; rebuild"
  [ -z "$(git status --porcelain)" ] || die "the tree has uncommitted changes"
  git fetch -q origin
  git merge-base --is-ancestor "$head" origin/main || die "HEAD ${head:0:7} is not on origin/main; push it first"
  ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 || die "release $tag exists"
fi

# GitHub renders a release body's newlines as line breaks: one line per paragraph and bullet.
row() {  # a table row: name and size of an artifact (GitHub shows each asset's sha256 itself)
  printf '| `%s` | %s |' "$(basename "$1")" "$(stat -c %s "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')"
}
patches=$(git ls-tree --name-only "$built" patches/ | while read -r p; do  # as built, not as HEAD has them
  git show "$built:$p" | awk '/^Subject: /{s=$0; while ((getline l) > 0 && l ~ /^ /) s = s l; sub(/^Subject: \[PATCH[^]]*\] /, "", s); print "  - " s; exit}'
done)
base=$(info base)
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<NOTES
Gemtek W1700K chainloader and recovery image for the UBI layout OpenWrt 26.12 is expected to ship, built from [${built:0:7}](https://github.com/$REPO/tree/$built). Not an official OpenWrt build.

| File | Bytes |
|---|--:|
$(row "$CHAIN")
$(row "$REC")

- U-Boot \`$(info uboot | sed 's/^U-Boot //')\`; recovery image OpenWrt \`$(info revision)\`, $(info kernel | sed 's/^linux-/Linux /'), with LuCI.
- Base: [openwrt/openwrt#26296](https://github.com/openwrt/openwrt/pull/26296) at \`${base:0:7}\`, plus:
$patches
- NAND: W25N04KV only. W25N04LV has no mainline driver yet (openwrt/openwrt#25532).
- Recovery: hold reset from the red status LED until it turns blue; the recovery system boots from the \`recovery\` volume (or TFTP from 192.168.1.254 if that fails), with LuCI at 192.168.1.1 and a slowly blinking blue LED.
NOTES

echo "tag: $tag"
cat "$notes"
case "$MODE" in
  dry) exit 0 ;;
  notes) gh release edit "$tag" --repo "$REPO" --notes-file "$notes" >/dev/null
         echo "release.sh: notes of $tag updated"; exit 0 ;;
esac

gh release create "$tag" "$CHAIN" "$REC" --repo "$REPO" --target "$built" --title "$tag" --notes-file "$notes"

# GitHub's digests of what it now serves must be the local files'.
for f in "$CHAIN" "$REC"; do
  want="sha256:$(sha256sum "$f" | cut -d' ' -f1)"
  got=$(digest "$tag" "$f")
  [ "$got" = "$want" ] || die "$(basename "$f"): GitHub has $got, local $want"
done
echo "release.sh: published $tag, digests match"
