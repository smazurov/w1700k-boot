#!/bin/bash
# Builds the W1700K chainloader and recovery image. Run from the host:
#   ./build.sh            incremental: reapply patches, rebuild what changed
#   ./build.sh --fresh    also update feeds and download sources
#   ./build.sh --attach   follow the log of the build already running
#
# The container writes its own log and the host only tails it, so losing the
# `docker exec` client costs no output and the build keeps running.
set -euo pipefail

CONTAINER=w1700k-boot
IMAGE=w1700k-boot:latest
DIR="$(dirname "$(readlink -f "$0")")"

if [ ! -f /.dockerenv ]; then
  cd "$DIR"

  if [ "${1:-}" = "--attach" ]; then
    exec tail -f build.log
  fi

  # The container is stopped after every build, so a running one means a build is in progress.
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
    echo "$CONTAINER is already running: a build is in progress. Use ./build.sh --attach." >&2
    echo "If that is wrong:  docker stop $CONTAINER" >&2
    exit 1
  fi

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building $IMAGE from Dockerfile"
    docker build -q -t "$IMAGE" "$DIR" >/dev/null
  fi
  if ! docker start "$CONTAINER" >/dev/null 2>&1; then
    docker run -d --init --name "$CONTAINER" -v "$DIR:/bld" -w /bld "$IMAGE" >/dev/null
    echo "created $CONTAINER"
  fi
  # PID 1 = `sleep` means no zombie reaping, which deadlocks long builds.
  if [ "$(docker exec "$CONTAINER" cat /proc/1/comm 2>/dev/null)" != "docker-init" ]; then
    echo "$CONTAINER has no init (PID 1 = $(docker exec "$CONTAINER" cat /proc/1/comm 2>/dev/null))." >&2
    echo "Recreate it:  docker rm -f $CONTAINER && ./build.sh" >&2
    exit 1
  fi

  # mkdir is atomic: closes the window before `make` exists in which a second build could start.
  if ! mkdir "$DIR/.build.lock" 2>/dev/null; then
    echo "A build is already running (lock: $DIR/.build.lock). Use ./build.sh --attach." >&2
    echo "If no build is running, remove the lock directory." >&2
    exit 1
  fi
  trap 'rmdir "$DIR/.build.lock" 2>/dev/null' EXIT

  ID="$(date +%Y%m%d-%H%M%S)-$$"
  LOG="build-$ID.log"
  : > "$LOG"
  ln -sf "$LOG" build.log

  # Detached: the build survives the client going away.
  docker exec -u 1000:1000 -w /bld -d "$CONTAINER" \
    bash -c "bash /bld/build.sh ${*:-} > /bld/$LOG 2>&1; echo \"exit=\$?\" >> /bld/$LOG"

  echo "building -> $DIR/$LOG (symlinked as build.log)"
  tail -f "$LOG" &
  TAIL=$!
  trap 'kill $TAIL 2>/dev/null; rmdir "$DIR/.build.lock" 2>/dev/null' EXIT
  while ! grep -q '^exit=' "$LOG"; do sleep 5; done
  kill $TAIL 2>/dev/null || true
  RC="$(sed -n 's/^exit=//p' "$LOG" | tail -1)"

  docker stop "$CONTAINER" >/dev/null 2>&1 && echo "stopped $CONTAINER"
  exit "$RC"
fi

# ---- inside the container ------------------------------------------------------------------------
export CCACHE_DIR=/bld/ccache
START=$(mktemp)
FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1

# shellcheck disable=SC1091
. /bld/settings.ini

cd /bld
if [ ! -d openwrt/.git ]; then
  mkdir -p openwrt
  git -C openwrt init -q
  git -C openwrt remote add origin "$REPO_URL"
  FRESH=1
fi
cd /bld/openwrt
git remote set-url origin "$REPO_URL"

# Reset to the pin on every build, then reapply the patches: the patches are the source of truth,
# and a tree left over from an earlier patch revision must not leak into this one. git clean
# without -x keeps the ignored build_dir, staging_dir, dl, feeds and bin, so builds stay incremental.
if ! git cat-file -e "$REPO_COMMIT^{commit}" 2>/dev/null; then
  # Shallow-fetch the exact commit: GitHub serves a full SHA directly.
  git fetch -q --depth 1 origin "$REPO_COMMIT"
  FRESH=1
fi
git checkout -q -f --detach "$REPO_COMMIT"
git clean -fdq

# Fixed committer and dates make the commit ids, and so the "r0-<hash>" in the U-Boot and kernel
# version strings, a function of the patches alone: a new patch revision gets a new banner.
GIT_COMMITTER_NAME=w1700k-boot GIT_COMMITTER_EMAIL=w1700k-boot@localhost \
  git -c core.hooksPath=/dev/null am -q --committer-date-is-author-date /bld/patches/*.patch
echo "build.sh: $(git log --oneline "$REPO_COMMIT"..HEAD | wc -l) patches on $(git rev-parse --short "$REPO_COMMIT"), HEAD $(git rev-parse --short HEAD)"

if [ "$FRESH" = 1 ]; then
  ./scripts/feeds update -a
fi
./scripts/feeds install -a

rm -rf files
mkdir -p files
cp -r /bld/files/. files/ 2>/dev/null || true

# config.diff is the source of truth: reseed every time, or symbols added to it never apply.
cp /bld/config.diff .config
make defconfig

missing=0
while read -r sym; do
  grep -q "^${sym}\$" .config || { echo "build.sh: DROPPED $sym" >&2; missing=$((missing + 1)); }
done < <(grep -E '^CONFIG_[A-Za-z0-9_.+-]+=y$' /bld/config.diff)
[ "$missing" -eq 0 ] || { echo "build.sh: $missing symbol(s) dropped by defconfig" >&2; exit 1; }

[ "$FRESH" = 1 ] && make download -j8
make -j"$(nproc)"

# ---- checks on the artifacts, not the exit code --------------------------------------------------
OUT=bin/targets/airoha/an7581
CHAIN=$OUT/openwrt-airoha-an7581-gemtek_w1700k-ubi-chainload-uboot.itb
REC=$OUT/openwrt-airoha-an7581-gemtek_w1700k-ubi-initramfs-recovery.itb
RECOVERY_VOLUME=$((0x2000000))   # patches/0003: the volume the chainloader reserves
for f in "$CHAIN" "$REC"; do
  [ -f "$f" ] && [ "$f" -nt "$START" ] || { echo "build.sh: $f missing or not rebuilt" >&2; exit 1; }
done
size=$(stat -c %s "$REC")
[ "$size" -le "$RECOVERY_VOLUME" ] || { echo "build.sh: recovery is $size B, volume holds $RECOVERY_VOLUME B" >&2; exit 1; }
# The chainloader was built from the patched environment, not a stale build_dir.
env_file=$(echo build_dir/target-*/u-boot-an7581_gemtek_w1700k/u-boot-*/defenvs/an7581_w1700k_env)
grep -q 'ubi create recovery' "$env_file" ||
  { echo "build.sh: $env_file lacks the patched environment" >&2; exit 1; }
ls -l "$CHAIN" "$REC"
sha256sum "$CHAIN" "$REC"
echo "build.sh: recovery $size of $RECOVERY_VOLUME B ($((size * 100 / RECOVERY_VOLUME))%)"
