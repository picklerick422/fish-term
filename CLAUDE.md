# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```sh
ohpm install                              # Install dependencies
./tools/build-ghostty-vt-docker.sh       # Rebuild native lib (rarely needed)
```

Primary build is via DevEco Studio or the hvigor CLI. The collaboration environment can only produce source — compilation happens inside DevEco Studio on a host with the HarmonyOS SDK.

## Architecture

### Two-module structure

```
libghostty_ohos/   ← reusable HAR: terminal rendering, controller, native bindings, themes
entry/             ← app: pages, sessions, transport drivers, connection persistence
```

**Boundary rule**: reusable terminal logic → `libghostty_ohos`; app-specific (WebSocket/PTY/SSH, UI pages, settings) → `entry`. Never leak app assumptions into the HAR's public API.

### Data flow (spec §3.3)

```
Terminal input → driver.write(data) → network
Network output → driver.onOutputBytes(ArrayBuffer) → controller.feedBytes(ArrayBuffer) → renderer
```

Binary output is batched in the driver (flush at 256 KB or next tick) and fed as raw bytes — no UTF-16 string round-trip on the UI thread. This is what makes server ring-buffer replay fast (measured: ~14.6k tiny WS frames per 2.2 MB snapshot). String-based `controller.feed(data)` remains for local/PTY-style drivers.

The TerminalController is persistent (one per tab, never unmounted). The driver (WebSocket/PTY/SSH) connects and disconnects independently — the surface stays alive. This avoids the crash that occurred when disconnect destroyed the rendering surface.

### Focus model (IME)

Two independent channels must both move to the active tab:
1. **ArkUI `focusControl.requestFocus(surfaceId)`** — routes hardware keyboard to the XComponent
2. **Native IME via `controller.focusTerminal()`** — routes soft-keyboard / CJK input process-wide

`focusControl` alone does not route IME. Both must be called on tab switch and return-from-background.

### Transport abstraction

`TerminalDriver` interface in `entry/src/main/ets/transport/TerminalDriver.ets` defines `start/write/resize/stop/onOutputBytes/onStatus`. The only active implementation is `FishWebSocketDriver` (connect to a fish-agent backend via WebSocket). SSH driver stubs exist but are `OFF` by default.

`FishWebSocketDriver` also tracks **replay state**: a connection opened with a known `session_id` attaches to a live server session, which replays its cached output (there is no "replay done" protocol frame — completion is detected by a 500 ms output-quiet window with a 15 s guard). `onReplayState` drives the full-screen `LoadingScreen` overlay in `Index.ets` and mutes task-pattern detection during replay.

### Color system

`entry/src/main/ets/theme/UiTheme.ets` — single source of truth for all UI chrome colors. Two switchable schemes: `refined` (default dark, cyan accent) and `futuristic` (violet/cyan gradient, restrained glow). Components read tokens via `@StorageLink('uiTheme')`; never scatter hex values elsewhere (pure-black overlay masks excepted). Scheme selection persists via `ConnectionStore.loadUiScheme/saveUiScheme`. Library overlays take an optional `surfaceTheme` prop (`libghostty_ohos/.../SurfaceTheme.ets`); entry maps tokens with `toSurfaceTheme()`.

### Tab architecture

- `TabMeta` (reactive, @Observed class) — lightweight metadata driving the tab strip UI. Uses `@State tabs: TabMeta[]` on the page.
- `TerminalRuntime` (non-reactive) — heavy per-tab objects (controller + surface ID + session), stored in a `Map<number, TerminalRuntime>` separate from the reactive array.

### Settings persistence

`ConnectionStore` in `entry/src/main/ets/store/ConnectionStore.ets` uses:
- `@ohos.data.preferences` for plain values (host, port, font size, theme name, etc.)
- Asset Store Kit for encrypted token storage
- All operations degrade gracefully on storage errors

## Conventions

### ArkTS

- `@Builder` methods use `build` prefix: `buildTabStrip()`, `buildSurface(id)`, `buildStatusBanner()`
- `@State` for reactive state, `@Observed class` for nested object tracking in arrays
- `bindSheet()` for settings panel (center sheet, no drag bar)
- Use `bindContextMenu(this.Builder, ResponseType.RightClick)` for context menus
- Animations: `120–150ms, Curve.EaseOut` for hover/button; `180ms, Curve.Friction` for drag
- Focus management: all non-terminal controls are `.focusable(false)` and hand focus back via `focusActiveTerminal()`
- Overlay dialogs (guide, rename) use a full-screen `Stack` with `#CC000000` background, centered card with `constraintSize({ maxWidth })`

### C++

- N-API error handling: check all `napi_*` return values
- Match `CMakeLists.txt` when adding/removing source files
- Preserve `OH_NativeWindow` lifecycle — null-check before use, restore after resize
- No per-frame/per-cell logs in render paths (performance-sensitive)

### Testing

No automated test suite exists. Test by building in DevEco Studio and running on a real arm64 device (x86_64 emulator fails on prebuilt native libs). The `entry/build-profile.json5` pins `abiFilters: ["arm64-v8a"]`.

## Serve agent(fish-agent)

fish-agent在../agent-fish/fish-agent/ ，如需修改服务端内容，可以查看。

## Visual companion (superpowers brainstorming)

The agent runs in a Linux VM; the user's browser is on the host. The host can reach the VM at `172.16.105.2` (eth0) but not the VM's `127.0.0.1`. Always start the visual companion (and any local preview server meant for the user) with:

```sh
scripts/start-server.sh --project-dir /mnt/linux_share/DevEcoStudioProjects/fish-term --host 0.0.0.0 --url-host 172.16.105.2
```

Give the user the full `http://172.16.105.2:<port>/?key=...` URL. `--open` only opens a browser inside the VM.
## Constraints

- Target API: HarmonyOS 6.0.0 (API 20), compatible SDK 6.0.0
- Device: 2in1 (tablet/desktop), arm64-v8a only
- Prebuilt `libghostty_vt.a` is gitignored — obtained via Docker build script or upstream Ghostty zig build
- The FUSE mount at `/mnt/linux_share` doesn't support `chmod` — git operations must happen inside DevEco Studio or via `tools/git-init.sh`
- Strict mode enabled with `caseSensitiveCheck: true`
