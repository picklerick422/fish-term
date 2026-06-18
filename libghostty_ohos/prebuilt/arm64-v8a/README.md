# prebuilt/arm64-v8a

Drop `libghostty_vt.a` here. The native build (`libghostty_ohos/src/main/cpp/CMakeLists.txt`)
hard-requires it and aborts with a FATAL_ERROR if missing.

## How to produce it

Option A — repo helper (Docker + network):

```bash
./tools/build-ghostty-vt-docker.sh
# copies the result to libghostty_ohos/prebuilt/arm64-v8a/libghostty_vt.a
```

Option B — manual:

```bash
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build -Dtarget=aarch64-freestanding -Doptimize=ReleaseFast
cp zig-out/lib/libghostty_vt.a \
   ../libghostty_ohos/prebuilt/arm64-v8a/libghostty_vt.a
```

This `.a` is treated as a generated build input and is not produced in this
environment (no Docker/network). It must be supplied before the first DevEco build.
