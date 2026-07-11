# fish-term

HarmonyOS terminal emulator built on Ghostty's VT library.

## Quick Start

### Prerequisites

- DevEco Studio 5.0+
- Node.js 16+
- ohpm (HarmonyOS package manager)

### Build

```sh
# Install dependencies
ohpm install

# Build the project (via DevEco Studio or CLI)
# Use --mode release for app-store upload; debug mode injects "debug": true
# into the packaged module.json and will be rejected by the store.
/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/bin/hvigor.js assembleApp -m project --mode release --no-daemon
```

### Rebuild Native Library

If you need to rebuild the bundled `libghostty_vt.a`:

```sh
./tools/build-ghostty-vt-docker.sh
```

## Project Structure

```
fish-term/
├── libghostty_ohos/      # Reusable HAR library
│   ├── src/main/ets/     # ArkTS surface & controller
│   ├── src/main/cpp/     # Native terminal & renderer
│   └── prebuilt/         # Prebuilt native libraries
├── entry/                # Fish-term app
│   ├── src/main/ets/     # Pages, sessions, transport
│   └── src/main/cpp/     # PTY, SSH drivers
├── tools/                # Build scripts
└── docs/                 # Documentation
```

## Key Components

### Library (`libghostty_ohos`)

- `TerminalSurface.ets` - ArkTS rendering surface
- `TerminalController.ets` - Terminal state management
- `napi_init.cpp` - N-API bindings
- `native_drawing_renderer.cpp` - Hardware-accelerated renderer

### App (`entry`)

- `Index.ets` - Main UI
- `TerminalSession.ets` - Session lifecycle
- `FishWebSocketDriver.ets` - WebSocket transport
- `pty_handler.cpp` - PTY management

## Configuration

### OpenCode Config

The project includes `opencode.jsonc` for AI coding optimization:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "watcher": {
    "ignore": ["build/**", ".cxx/**", ".hvigor/**", "prebuilt/**"]
  }
}
```

## Development

### Adding Features

1. Reusable terminal logic → `libghostty_ohos/`
2. App-specific features → `entry/`
3. Keep library public API minimal

### Testing

- Verify controller lifecycle (attach/detach)
- Test input listener wiring
- Check config propagation

## Documentation

- [BUILD.md](BUILD.md) - Build instructions
- [USAGE.md](docs/USAGE.md) - Integration guide
- [AGENTS.md](AGENTS.md) - AI agent instructions

## License

MIT License
