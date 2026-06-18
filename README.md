# fish-term

**fish-term** is a HarmonyOS terminal app powered by [Ghostty](https://ghostty.org)'s VT terminal core. It ships both a reusable HAR library (`libghostty-ohos`) and a ready-to-run example app that connects to a remote shell over WebSocket, local PTY, or SSH.

<img width="3120" height="2080" alt="fish-term screenshot" src="https://github.com/user-attachments/assets/42905cc8-2233-438d-a6e3-d461f7da06ce" />

## Features

- Full VT terminal rendering backed by `libghostty-vt` (Ghostty's terminal core)
- ArkTS `TerminalSurface` component using HarmonyOS `XComponent` for native GPU rendering
- Hardware keyboard, IME, clipboard, and touch input (tap-to-scroll, long-press selection)
- 50+ bundled terminal color themes (Ghostty format)
- Symbols Nerd Font Mono for glyph/icon fallback
- WebSocket transport to a remote shell backend (`fish-agent`)
- Local PTY shell driver
- SSH transport (opt-in, compile-time flag)
- Adjustable font size with persistent preference storage
- Encrypted token storage via HarmonyOS Asset Store Kit

## Project Layout

```
fish-term/
├── libghostty_ohos/          # Reusable HAR library (published as libghostty-ohos)
│   ├── src/main/ets/         # ArkTS: TerminalSurface, TerminalController, TerminalTypes
│   ├── src/main/cpp/         # Native N-API bridge + renderer + VT terminal wrapper
│   └── src/main/resources/   # 50+ themes, Symbols Nerd Font Mono
├── entry/                    # fish-term app (consumes the HAR)
│   ├── src/main/ets/
│   │   ├── pages/Index.ets              # Main page: connection form + terminal
│   │   ├── transport/
│   │   │   ├── FishWebSocketDriver.ets  # WebSocket transport to fish-agent backend
│   │   │   ├── FishUrl.ets              # WebSocket URL builder
│   │   │   ├── TerminalDriver.ets       # TerminalDriver interface + FishConnectConfig
│   │   │   └── Utf8Framer.ets           # UTF-8 frame decoder for binary WS frames
│   │   ├── session/TerminalSession.ets  # Session lifecycle management
│   │   └── store/ConnectionStore.ets    # Persistent connection profiles + font size
│   └── src/main/cpp/         # Native PTY and SSH drivers
├── tools/
│   ├── build-ghostty-vt-docker.sh  # Rebuilds libghostty_vt.a in Docker
│   └── build-fish-ohos.sh          # Rebuilds bundled fish/starship/fastfetch HNP
├── BUILD.md                  # Build prerequisites and DevEco Studio setup
├── THIRD_PARTY_NOTICES.md    # License attribution
└── LICENSE                   # MIT
```

## The `libghostty-ohos` Library

The HAR library is designed to be embedded in any HarmonyOS app. It provides:

| Export | Description |
|--------|-------------|
| `TerminalSurface` | ArkTS component backed by `XComponent`; owns native bind/unbind lifecycle |
| `TerminalController` | Imperative control: input/output wiring, scroll, selection, theme, config |
| `TerminalConfig` / `TerminalConfigPatch` | Configuration types |
| `CursorPosition` / `CellMetrics` | Query types |
| `DEFAULT_TERMINAL_CONFIG` / `DEFAULT_THEME_NAME` | Defaults |

### Install

```sh
ohpm install libghostty-ohos
```

Or as a `oh-package.json5` dependency:

```json5
{
  "dependencies": {
    "libghostty-ohos": "^0.1.0"
  }
}
```

For local development:

```json5
{
  "dependencies": {
    "libghostty-ohos": "file:../libghostty_ohos"
  }
}
```

### Quick Start

```ts
import { TerminalController, TerminalSurface } from 'libghostty-ohos';

@Entry
@Component
struct TerminalPage {
  private controller: TerminalController = new TerminalController();

  aboutToAppear(): void {
    this.controller.updateConfig({ fontSize: 16, scrollbackLines: 20000 });
    this.controller.setTheme('Aizen_Dark');
    this.controller.setInputListener((data: string) => {
      this.driver.write(data);
    });
  }

  build() {
    Stack() {
      TerminalSurface({
        controller: this.controller,
        surfaceId: 'main-terminal-surface',
        surfaceColor: '#0B0D10'
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0D10')
  }
}
```

### Usage Rules

- One `TerminalController` per terminal instance.
- Never reuse the same `surfaceId` across simultaneously visible surfaces.
- `TerminalSurface` owns the native lifecycle — do not call `bindNative()` / `unbindNative()` from app code.
- Config is cached on the controller and applied when the surface binds.
- `getThemeList()`, `isRendererReady()`, and `getRendererError()` are meaningful only after the surface is attached.

### Multi-Terminal Composition

- **Tabs**: one controller per tab; mount/unmount the active `TerminalSurface`.
- **Splits**: render multiple `TerminalSurface` instances side by side, each with a unique `surfaceId` and its own controller.
- **Custom actions**: use `write()`, `feed()`, `scrollView()`, `clearSelection()`, `setTheme()`, `updateConfig()` directly.

## Transport Drivers

The app separates terminal rendering from I/O transport via the `TerminalDriver` interface:

```ts
interface TerminalDriver {
  start(cols: number, rows: number): void;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  stop(): void;
  onOutput(cb: (data: string) => void): void;
  onStatus(cb: (s: DriverStatus) => void): void;
}
```

| Driver | Status | Description |
|--------|--------|-------------|
| `FishWebSocketDriver` | Enabled | WebSocket to fish-agent backend; auto-reconnect with backoff |
| Local PTY (`ExampleShellDriver`) | Enabled | Direct local shell via PTY |
| SSH | Opt-in | Password-based SSH; enable with `-DFISH_ENABLE_SSH=ON` at build time |

## Runtime Behavior

- Terminal starts when the surface binds.
- User input (hardware keyboard, IME, paste, touch) routes through the controller to your driver.
- Driver output is fed back via `controller.feed()`.
- Touch drag scrolls; long-press enters selection mode.

## Build From Source

See [BUILD.md](BUILD.md) for the full prerequisite setup. Quick summary:

**1. Build the native archive:**

```sh
./tools/build-ghostty-vt-docker.sh
```

This produces `libghostty_ohos/prebuilt/arm64-v8a/libghostty_vt.a`.

**2. Install OHPM dependencies:**

```sh
ohpm install
```

**3. Build the app in DevEco Studio:**

```sh
/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js assembleApp -m project --no-daemon
```

Target: HarmonyOS 6.0.0 / API Level 20 / arm64-v8a.

## Platform & Requirements

| Requirement | Detail |
|-------------|--------|
| Target OS | HarmonyOS 6.0.0 (API Level 20) |
| Architecture | arm64-v8a (real device required) |
| IDE | DevEco Studio |
| Build tools | Hvigor, OHPM, CMake, HarmonyOS NDK |
| Native archive | Zig 0.15.2 + Docker (for Ghostty rebuild) |

## Third-Party Components

| Component | License |
|-----------|---------|
| [Ghostty](https://ghostty.org) (`libghostty_vt.a`) | MIT |
| simdutf | Apache-2.0 OR MIT |
| Google Highway | Apache-2.0 OR BSD-3-Clause |
| Symbols Nerd Font Mono | SIL OFL 1.1 |

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full attribution.

## License

MIT — see [LICENSE](LICENSE).
