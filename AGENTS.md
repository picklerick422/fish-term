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
- `ets/pages/Index.ets` — Main UI (orchestration only)
- `ets/components/` — TabStrip (exports TabMeta), StatusBanner, ConnectionForm, GuideOverlay (extracted from Index)
- `ets/transport/FishWebSocketDriver.ets` — WebSocket transport
- `ets/session/TerminalSession.ets` — Session lifecycle
- `cpp/pty/pty_handler.cpp` — PTY management
- `ets/theme/UiTheme.ets` — UI 设计令牌 + A/B 双方案 + UiThemeStore(换肤唯一入口)

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

## Environment

Agent runs in a Linux VM; the host shares this repo via `/mnt/linux_share`. VM eth0 IP `172.16.105.2` is reachable from the host; VM `127.0.0.1` is not.

**Visual companion / any preview server for the user**: always start with `--host 0.0.0.0 --url-host 172.16.105.2` and give the user the full `http://172.16.105.2:<port>/?key=...` URL — `--open` only opens a browser inside the VM.

## Change Rules

- **ArkTS**: Verify lifecycle (attach/detach), input wiring, config propagation
- **C++**: Match CMakeLists.txt, preserve OH_NativeWindow/N-API error handling
- **App**: Keep minimal; don't leak app assumptions into HAR API

## Docs

Update on material changes: README.md (API), BUILD.md (toolchain), THIRD_PARTY_NOTICES.md (deps)
