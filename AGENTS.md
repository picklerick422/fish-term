# AGENTS.md

## Project

fish-term — HarmonyOS terminal app on Ghostty's VT library.

- `libghostty_ohos/` — Reusable HAR: terminal rendering, controller, native bindings, themes
- `entry/` — App: shell/PTY/WebSocket transport, UI

**Boundary**: Reusable logic → libghostty_ohos. App logic → entry.

## Key Files

### Library (`libghostty_ohos/src/main/`)
- `ets/TerminalSurface.ets`, `TerminalController.ets` — ArkTS surface & state
- `cpp/napi_init.cpp` — N-API bindings
- `cpp/terminal/terminal.cpp` — Core terminal logic
- `cpp/renderer/native_drawing_renderer.cpp` — Hardware renderer
- `cpp/CMakeLists.txt` — Native build config

### App (`entry/src/main/`)
- `ets/pages/Index.ets` — Main UI
- `ets/transport/FishWebSocketDriver.ets` — WebSocket transport
- `ets/session/TerminalSession.ets` — Session lifecycle
- `cpp/pty/pty_handler.cpp` — PTY management

## Rules

1. Preserve library/entry split
2. Keep public API minimal; sync ArkTS ↔ C++ when changing exports
3. Never hand-edit `prebuilt/*/libghostty_vt.a` — rebuild with script
4. No per-frame/per-cell logs in render paths
5. Keep changes scoped; renderer/state paths are perf-sensitive

## Build

```sh
ohpm install                              # Dependencies
./tools/build-ghostty-vt-docker.sh       # Rebuild native lib
hvigor.js assembleApp -m project --mode release   # Full build for release/store upload (needs signing config)
```

## Change Rules

- **ArkTS**: Verify lifecycle (attach/detach), input wiring, config propagation
- **C++**: Match CMakeLists.txt, preserve OH_NativeWindow/N-API error handling
- **App**: Keep minimal; don't leak app assumptions into HAR API

## Docs

Update on material changes: README.md (API), BUILD.md (toolchain), THIRD_PARTY_NOTICES.md (deps)
