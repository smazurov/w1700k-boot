# w1700k-boot

Chainloader and recovery image for the **Gemtek W1700K**, for the UBI layout OpenWrt 26.12 is
expected to ship. Not an official OpenWrt build.

## Why

The W1700K chainloader in OpenWrt main can't recover a unit: it has no pin controller driver,
so it finds neither the reset button nor the status LEDs, and `bootcmd` lacks `run`, so a broken
production volume never falls back to recovery. 25.12 has no W1700K images.

[openwrt/openwrt#26296](https://github.com/openwrt/openwrt/pull/26296) adds the Gemtek XR1710G
with a fixed chainloader derived from the W1700K one; its reviewers asked for the W1700K to follow
in a separate PR. This repo builds that follow-up, #26296 plus three patches drafted for upstream,
until it is merged and released:

1. sysupgrade rebuilds the `factory` volume (EEPROM, MACs) from the vendor partition, so no
   out-of-tree installer is needed.
2. The XR1710G chainloader's fixes, ported to the W1700K: reset button and LEDs, fallback
   production → recovery → TFTP, UBI and environment setup, TFTP server `192.168.1.254`. Unlike
   the XR1710G, holding reset boots the recovery volume first, so no TFTP server is needed.
3. A 32 MiB `recovery` volume, created with UBI before sysupgrade gives the rest to
   `rootfs_data`.

## Releases

| File | |
|---|---|
| `…-chainload-uboot.itb` | U-Boot, chainloaded by the vendor bootloader from `0x600000` |
| `…-initramfs-recovery.itb` | OpenWrt in RAM, with LuCI; booted from the `recovery` volume or by TFTP |

W25N04KV NAND only; W25N04LV has no mainline driver yet
([openwrt/openwrt#25532](https://github.com/openwrt/openwrt/pull/25532)). Installing takes the
serial console; the steps are in patch 0002's message.

**Recovery:** power on, press reset when the status LED turns red and hold it until it turns
blue. The recovery system comes up at `192.168.1.1` (LuCI, `w1700k-rescue`) with the blue LED
blinking slowly; production volumes are left alone.

## Building

```sh
./build.sh             # reset openwrt/ to settings.ini's pin, apply patches/, build (Docker)
./build.sh --fresh     # also update feeds and download sources
./build.sh --attach    # follow a build that is already running
./release.sh           # publish the last build as a GitHub release (gh); --dry-run to preview
```

- `patches/` comes from branch `w1700k-ubi-layout` of an OpenWrt checkout on top of the pin:
  `git format-patch <pin>..w1700k-ubi-layout -o patches/`. Bump `settings.ini` when #26296 moves.
- `config.diff` selects the device, the recovery image and LuCI; `files/` (local, not for
  upstream) gives the recovery system its blinking blue LED and hostname.
- Artifacts land in `openwrt/bin/targets/airoha/an7581/`. `build.sh` checks they were rebuilt, fit
  the recovery volume and carry the patched environment; `release.sh` publishes only a clean,
  pushed `HEAD`, tagged with the build date and commit.
