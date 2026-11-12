# w1700k-boot

Builds the Gemtek W1700K **chainloader** (`-chainload-uboot.itb`) and **recovery image**
(`-initramfs-recovery.itb`) for the layout OpenWrt 26.12 is expected to ship, until 26.12 ships
them itself. The W1700K flasher installs these on stock units.

## What it builds

| Part | Source |
|---|---|
| Base | [openwrt/openwrt#26296](https://github.com/openwrt/openwrt/pull/26296) at `settings.ini`'s pin: XR1710G support, the shared Gemtek DTS, the factory-volume rebuild in `platform.sh`, and the fixed XR1710G chainloader |
| `patches/` | The W1700K follow-up the #26296 reviewers asked for, as `git am` patches. Drafted on branch `w1700k-ubi-layout` in `~/dev/openwrt-w1700k`; this is the upstream PR to be |
| `config.diff` | The W1700K device, its initramfs (the recovery image) and LuCI, as in release builds |
| `files/` | Local only, not for upstream: the recovery system's identity (blue status LED blinking slowly, 1 s on and 1 s off; hostname `w1700k-rescue`), applied only when running from RAM |

The patches:

1. `platform.sh` rebuilds the factory volume (EEPROM, MACs) from the vendor partition on
   sysupgrade for the W1700K too, so no out-of-tree installer is needed.
2. The W1700K chainloader gets #26296's fixes: reset button and LEDs (pin controller), `run` in
   `bootcmd`, fallback production → recovery → TFTP, UBI format and volume creation, environment
   saved on first boot, TFTP server `192.168.1.254`, no installer entries. One difference from the
   XR1710G, which goes straight to TFTP: holding reset boots the recovery volume, then TFTP if
   that fails. Hold it from the red status LED until it turns blue; the recovery system answers
   with LuCI at `192.168.1.1` without needing a TFTP server.
3. The chainloader reserves a 32 MiB `recovery` volume when it creates UBI, before sysupgrade
   gives the rest to `rootfs_data`. The installer's 91-LEB volume could not hold a current
   recovery image (11,658,164 B for a snapshot, more with LuCI).

## The install this targets

1. Stock U-Boot (or stock failsafe) writes the chainloader to `0x600000`, makes `bootcmd` chainload
   it, and erases the stock UBI behind it (`0x700000`, `0x1b700000` bytes).
2. The chainloader creates UBI (`ubootenv`, `ubootenv2`, empty `factory`, empty `recovery`),
   saves its environment, finds nothing to boot and loads the recovery image via TFTP from
   `192.168.1.254`.
3. From the recovery system: write the recovery image into the `recovery` volume
   (`ubiupdatevol`), then `sysupgrade` the firmware; sysupgrade fills `factory`.

## Building

```sh
./build.sh            # reset to the pin, apply patches/, build
./build.sh --fresh    # also update feeds and download sources
./build.sh --attach   # follow a build that is already running
```

Artifacts land in `openwrt/bin/targets/airoha/an7581/`. `build.sh` fails unless both were rebuilt,
the recovery image fits the reserved volume, and the chainloader was built from the patched
environment. The U-Boot banner reads `…-OpenWrt-r0-<hash>`: the hash is the last applied patch,
so a new patch revision gets a new banner.

## Changing the patches

Edit and commit on the branch, then export:

```sh
cd ~/dev/openwrt-w1700k            # branch w1700k-ubi-layout, on top of the pin
git rebase -i <pin>                 # or commit on top
rm ~/dev/w1700k-boot/patches/*.patch
git format-patch <pin>..w1700k-ubi-layout -o ~/dev/w1700k-boot/patches
```

When #26296 is rebased or merged, move the branch onto the new base and bump `settings.ini`.

## Releasing

Builds are published as releases of [smazurov/w1700k-boot](https://github.com/smazurov/w1700k-boot);
the W1700K flasher's release catalog lists them and downloads a release into the station's
`bundles/<tag>/`.

```sh
git push                  # a release names the commit it was built from
./build.sh
./release.sh --dry-run    # the tag and the notes
./release.sh              # gh release create, then GitHub's digests are checked against the files
```

`release.sh` publishes only a successful build of a clean tree at `HEAD`, with `HEAD` on
`origin/main`; `build.sh` records what it built in `w1700k-boot.info` next to the images. A tag is
the build date and commit (`2026.11.12-fc5ed90`), because the banner hash (`r0-<hash>`) changes
only with `patches/`, not with `files/` or `config.diff`.
