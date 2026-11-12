# AGENTS.md: w1700k-boot

Read `README.md` first. Hardware facts and the station's rules live in
`~/dev/w1700k-flasher/AGENTS.md` and `FACTS.md`; nothing here touches a unit.

- **Build only with `./build.sh`.** It re-execs inside the `w1700k-boot` container as UID 1000.
  Never `docker exec` or `make` by hand.
- **One build at a time.** A running container or `.build.lock` means a build is in progress;
  use `--attach`. The container must run with `--init` (zombie reaping); `build.sh` checks.
- **`patches/` is the source of truth.** The tree is reset to the pin and the patches are
  reapplied on every build, so edits made in `openwrt/` are lost. Change the patches on the
  `w1700k-ubi-layout` branch in `~/dev/openwrt-w1700k` and re-export them (README).
- **The patches are a draft upstream PR.** Keep them in OpenWrt style: one change per commit,
  `subsystem: subject`, a message that says why, `Signed-off-by`. Nothing is submitted, pushed or
  posted upstream without the user asking.
- **Verify artifacts, not exit codes.** `build.sh` checks freshness, the recovery size against the
  reserved volume, and the patched U-Boot environment; keep those checks when changing it.
- Commits in this repo: conventional (`type(scope): subject`), no trailers.
- **Releases are public.** Publish with `./release.sh` only when the user asks. Never replace the
  assets of a published release (stations may already have them); publish a new one.
