# KDE Connect for HarmonyOS

[中文](README.zh-CN.md) | **English**

A HarmonyOS (OpenHarmony API 26) port of [KDE Connect](https://kdeconnect.kde.org/) — the multi-platform tool that lets your devices communicate over the local network.

> **Status**: Early development. Core networking (UDP discovery, TCP, TLS, pairing) and 10 plugins are functional. Real-device verified on MatePad Mini against KDE Desktop.

## Features

| Feature | Status | Protocol Packet |
|---|---|---|
| Device discovery & pairing | ✅ Working | `kdeconnect.identity`, `kdeconnect.pair` |
| File sharing | ✅ Working | `kdeconnect.share.request` |
| Clipboard sync (bidirectional) | ✅ Working | `kdeconnect.clipboard`, `kdeconnect.clipboard.connect` |
| Find my device (ring) | ✅ Working | `kdeconnect.ping` |
| Battery status (bidirectional) | ✅ Working | `kdeconnect.battery`, `kdeconnect.battery.request` |
| Network connectivity report | ✅ Working | `kdeconnect.connectivity_report` |
| Remote commands | ✅ Working | `kdeconnect.runcommand` |
| Media control (controller) | ✅ Working | `kdeconnect.mpris`, `kdeconnect.mpris.request` |
| Remote input | ⏳ Placeholder | `kdeconnect.mousepad.*` |
| Notifications | ⏳ Placeholder | `kdeconnect.notification.*` |

## Architecture

```
┌─────────────────────────────────────────────┐
│              ArkTS (UI + Plugins)            │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  │
│  │ 10 Plugins│  │PacketRouter│  │  UI Layer │  │
│  └────┬─────┘  └────┬─────┘  └───────────┘  │
│       │              │                        │
├───────┼──────────────┼────────────────────────┤
│       │   NAPI Bridge (napi_exports.cpp)      │
├───────┼──────────────┼────────────────────────┤
│       │              │                        │
│  ┌────┴─────┐  ┌─────┴──────┐  ┌──────────┐  │
│  │ Rust     │  │ C++ Net    │  │ Payload  │  │
│  │ kdc_core │  │ UDP/TCP/   │  │ Transfer │  │
│  │ (packet_ │  │ TLS(BearSSL│  │          │  │
│  │  io,cert)│  │ /cert gen) │  │          │  │
│  └──────────┘  └────────────┘  └──────────┘  │
│              Native C++ Layer                 │
└─────────────────────────────────────────────┘
```

- **Native C++ (NAPI)**: UDP discovery, TCP server/connections, BearSSL 0.6 TLS, self-signed certificate generation, packet serialization, payload transfer
- **Rust staticlib** (`kdc_core`): `packet_io` + `cert_util` — migrated from C++ for memory safety (R1)
- **ArkTS**: Plugin framework (registry-driven), UI, business logic

## Tech Stack

| Layer | Technology |
|---|---|
| UI / Business | ArkTS (OpenHarmony API 26, Stage model) |
| Native Networking | C++20, BearSSL 0.6, cJSON (vendored) |
| Core Utils | Rust (serde, serde_json, sha2, base64) |
| Build | hvigorw (HarmonyOS), CMake (native), cargo (Rust) |
| Protocol | KDE Connect protocol v8 |

## Build

### Prerequisites

- HarmonyOS Command Line Tools (`/opt/command-line-tools`)
- OpenHarmony SDK (`/opt/ohos-sdk`)
- Rust toolchain (for the `kdc_core` staticlib):

  ```bash
  rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos
  ```

  If `cargo` is missing, CMake fails at configure time with the exact install hint; cross-toolchain details are in `entry/src/main/cpp/rust/README.md` §5b.
- Python 3 (for the encoding guard)
- **First build on a fresh clone**: run `ohpm install` (`oh_modules/` is not tracked), then run
  `tools/sync-revision.sh --install` once to install the git hooks (revision marker + encoding guard)

### Build the HAP

```bash
# libxml2 shim (if system libxml2 > 2.12):
mkdir -p ~/.local/share/ohos_libshim
ln -sf /usr/lib/libxml2.so.16 ~/.local/share/ohos_libshim/libxml2.so.2

# Build:
LD_LIBRARY_PATH=$HOME/.local/share/ohos_libshim hvigorw --no-daemon assembleHap
```

### Sign & Install to Device

```bash
# Debug signing (local materials, no Huawei account needed):
tools/sign-debug.sh
```

### Run Tests

```bash
tests/run.sh   # 30 host-side unit/integration tests
```

## Project Structure

```
kdeconnect-harmony/
├── entry/src/main/
│   ├── cpp/              # Native C++ (NAPI)
│   │   ├── net/          # UDP discovery, TCP server, TLS engine, NAPI bridge (napi_exports.cpp)
│   │   ├── payload/      # Payload transfer
│   │   ├── napi_init.cpp # Module registration and NAPI export table
│   │   └── rust/         # Rust staticlib integration (kdc_core: packet_io + cert_util)
│   ├── ets/
│   │   ├── plugins/      # 10 plugins (registry-driven)
│   │   ├── net/          # PacketRouter
│   │   ├── kdeconnect/   # NetworkPacket, protocol types
│   │   └── pages/        # UI (Index.ets)
│   └── module.json5      # Permissions, abilities
├── tools/                # sign-debug.sh, check-encoding.py, sync-revision.sh
├── devdocs/              # Developer guides (CPP_GUIDE, ARKTS_GUIDE, PROCESS)
├── LICENSE               # GPL-3.0
```

## Protocol Compatibility

Implements KDE Connect protocol v8 with strict schema compliance (`kdeconnect-meta/schemas/`). Cross-end constants:

| Constant | Value |
|---|---|
| Protocol version | 8 |
| UDP port | 1716 |
| TCP port range | 1716–1764 |
| Payload port | ≥1739 |
| Max packet size | 32 MiB |
| Identity packet | 8 KiB |
| Pairing timestamp tolerance | ±1800s |

## Development

### Adding a Plugin

1. Create `entry/src/main/ets/plugins/MyPlugin.ets` extending `PluginBase`
2. Declare `supportedPacketTypes` (incoming) and `outgoingPacketTypes` (outgoing)
3. Implement `onPacketReceived()` and optionally `onCreate()`/`onDestroy()`
4. Register in `PluginRegistry` (`Index.ets`)
5. The framework auto-handles capability negotiation and packet routing

### Coding Standards

- C++: See `devdocs/CPP_GUIDE.md`
- ArkTS: See `devdocs/ARKTS_GUIDE.md`
- Workflow: See `devdocs/PROCESS.md`
- All text files must be valid UTF-8 (enforced by `tools/check-encoding.py` pre-commit hook)

## License

GPL-3.0 — same as upstream KDE Connect. See [LICENSE](LICENSE).

## Agent Division of Labour

Requirements and key decisions come from the human author; day-to-day implementation, review and verification are split across several AI agents (collaboration rules and pitfalls: `devdocs/PROCESS.md`).

| Role | Scope | Notes |
|---|---|---|
| **omp** (Linux side) | All C++ native code, the Rust migration, host tests, real-desktop verification, git single writer | UDP/TCP/TLS (BearSSL), certificates, NAPI bridge, payload transfer, `kdc_core` (R1 Rust migration); commits and pushes are made from this side only |
| **DevEco Code** (Win10 side) | ArkTS: UI, plugin framework and the 10 plugins | Builds in DevEco Studio; verifies on real devices / emulator |
| **CodeArts** | Process owner: task dispatch, code review, adjudication and push timing | Maintains `devdocs/PROCESS.md` and the coordination log `AgentsConversion/` |
| **AtomCode** | Independent review (assessment only, no code changes) | Migration plan, full-code reviews, acceptance criteria |
| **ZCode** | Early C++/native and build bootstrap | Handed over to omp later |

Both sides share one working tree via Syncthing: **never write the same file from both sides**; `.git` exists on the Linux
side only (Win10 tracks "which commit do these files correspond to" through `AgentsConversion/GIT_REVISION.md`, and a
pre-commit encoding guard rejects mojibake).

## Acknowledgments

- [KDE Connect](https://kdeconnect.kde.org/) — the original project by the KDE community
- [kdeconnect-android](https://invent.kde.org/network/kdeconnect-android) — Android reference implementation
- [kdeconnect-kde](https://invent.kde.org/network/kdeconnect-kde) — Desktop reference implementation
- [kdeconnect-meta](https://invent.kde.org/network/kdeconnect-meta) — Protocol schemas
