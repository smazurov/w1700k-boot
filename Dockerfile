# OpenWrt build environment for the Gemtek W1700K.
#
# Run it with --init. Without an init process PID 1 is `sleep infinity`, which never
# reaps children; orphaned build processes pile up as zombies until the build deadlocks.
# build.sh enforces this.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential clang flex bison g++ gawk \
      gcc-multilib g++-multilib gettext git \
      libncurses-dev libssl-dev python3-setuptools python3-dev \
      rsync unzip zlib1g-dev file wget swig time ccache \
      ca-certificates curl xxd zstd squashfs-tools \
      libelf-dev quilt patch \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 already ships uid/gid 1000 as `ubuntu`. Building as non-root is what
# OpenWrt expects and keeps artifacts owned by the host user across the bind mount.
USER ubuntu
WORKDIR /bld

CMD ["sleep", "infinity"]
