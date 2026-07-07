# Building fish-term in DevEco Studio

This project is built and device-verified in DevEco Studio. The collaboration
environment cannot compile HarmonyOS projects, so it produces source only.

## One-time native prerequisites (gitignored — not in the repo)

1. **libghostty-vt static lib** — required by the `libghostty_ohos` HAR native.
   Place at: `libghostty_ohos/prebuilt/<OHOS_ARCH>/libghostty_vt.a`
   (e.g. `libghostty_ohos/prebuilt/arm64-v8a/libghostty_vt.a`).
   Obtain via `tools/build-ghostty-vt-docker.sh`, or build upstream Ghostty:
   `zig build -Dtarget=aarch64-freestanding -Doptimize=ReleaseFast`, then copy
   `zig-out/lib/libghostty_vt.a` into `prebuilt/arm64-v8a/`.

2. **SSH native deps** — only needed for the SSH transport (P2+), and **off by
   default** so P1 builds without them. The native CMake has a `WAND_ENABLE_SSH`
   option (default `OFF`):
   - `OFF` (default): compiles `ssh/ssh_session_stub.cpp` instead of the real session;
     SSH calls return a "not built" error. No `third_party` needed.
   - `ON` (SSH enabled): place sources at `entry/third_party/mbedtls` and
     `entry/third_party/libssh2`, then enable it by setting in
     `entry/build-profile.json5`:
     `"externalNativeOptions": { "arguments": "-DWAND_ENABLE_SSH=ON", ... }`.

   `example_driver.cpp` is identical in both modes — only the compiled session and
   the link/include of libssh2/mbedtls differ.

## Target ABI

The `libghostty_vt.a` prebuilt is provided for `arm64-v8a` only, so
`entry/build-profile.json5` pins `abiFilters: ["arm64-v8a"]`. Build/run on a real
arm64 device (an x86_64 emulator would fail the prebuilt lookup). To target another
ABI, supply a matching `libghostty_vt.a` under `prebuilt/<arch>/` and add the ABI.

## Git

The shared drive (`/mnt/linux_share`, a FUSE mount) does not permit the `chmod`
operations git needs, so the repo is not initialized there. Initialize and commit
from a native filesystem (or inside DevEco). A ready-to-run script lives at
`tools/git-init.sh`.

## Signing

Root `build-profile.json5` intentionally omits signing config. Add a local signing
profile in DevEco (Project Structure → Signing Configs) before running on a device.

## Run

Open the project root in DevEco Studio → wait for sync → select the `entry` module
→ run on a device/emulator.

- **P0 check:** the original `pages/Index` (local fish shell) is replaced in P1. To
  smoke-test the base before P1, check out the scaffold commit, or temporarily point
  `pages/Index` back at the local PTY example.
- **P1 check:** start your `fish-agent` backend (must include the concurrent-write
  mutex fix), then use the in-app connect form (host / port / token / TLS).
