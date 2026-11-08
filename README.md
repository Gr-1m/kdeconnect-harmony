# KDE Connect for HarmonyOS

[中文](README.zh-CN.md) | **English**

A HarmonyOS (OpenHarmony API 26) port of [KDE Connect](https://kdeconnect.kde.org/) — the multi-platform tool that lets your devices communicate over the local network.

> **Status**: **0.8.4** — native stack fully migrated to Rust (`ohos-rs` + `rustls`, TLS 1.3/1.2). Core networking (UDP discovery, TCP, TLS, pairing), file sharing with batch progress UI, and the plugin set are functional. Verified on HarmonyOS emulators (foldable/tablet) and real devices (MatePad Mini, Mate 80 Pro) against KDE Desktop.

## Screenshots

<!-- Screenshots will be added here. See screenshots/ directory. -->
<!-- Recommended shots: main screen, pairing dialog, media control, file received, settings -->

## Features

| Feature | Status | Protocol Packet |
|---|---|---|
| Device discovery & pairing | ✅ Working | `kdeconnect.identity`, `kdeconnect.pair` |
| File sharing | ✅ Working (batch UI in 0.8.4) | `kdeconnect.share.request`, `share.request.update` |
| Clipboard sync (bidirectional) | ✅ Working | `kdeconnect.clipboard`, `kdeconnect.clipboard.connect` |
| Find my device (ring) | ✅ Working | `kdeconnect.ping` |
| Battery status (bidirectional) | ✅ Working | `kdeconnect.battery`, `kdeconnect.battery.request` |
| Network connectivity report | ✅ Working | `kdeconnect.connectivity_report` |
| Remote commands | ✅ Working | `kdeconnect.runcommand` |
| Media control (controller) | ✅ Working | `kdeconnect.mpris`, `kdeconnect.mpris.request` |
| Remote input (mousepad) | ✅ Working | `kdeconnect.mousepad.*` |
| Notifications | ✅ Display (reply/action not supported by platform) | `kdeconnect.notification.*` |

## Architecture

```
┌──────────────────────────────────────────────┐
│              ArkTS (UI + Plugins)             │
│  ┌────────────┐ ┌──────────────┐ ┌─────────┐ │
│  │  Plugins   │ │ PacketRouter │ │ UI Layer│ │
│  └─────┬──────┘ └──────┬───────┘ └─────────┘ │
├────────┼───────────────┼─────────────────────┤
│        │      NAPI Bridge (ohos-rs)           │
├────────┼───────────────┼─────────────────────┤
│  ┌─────┴───────────────────────────────────┐  │
│  │ Rust native — entry/src/main/cpp/rust/full/ │
│  │  kdc_native (core) + kdeconnect_napi       │
│  │  discovery · TCP · TLS(rustls) · certs     │
│  │  (rcgen) · packet framing · payload spool  │
│  │  pairing state machine                     │
│  └────────────────────────────────────────────┘
└──────────────────────────────────────────────┘
```

- **Rust native (`ohos-rs` + `rustls`)**: UDP discovery, TCP server/connections, TLS 1.3/TLS 1.2, self-signed certificate generation (rcgen), packet serialization, payload transfer with spool, pairing state machine — all under `entry/src/main/cpp/rust/full/` (`core` + `napi` crates).
- **ArkTS**: plugin framework (registry-driven), UI, business logic; NAPI contract frozen in `entry/src/main/cpp/types/libkdeconnect_napi/Index.d.ts`.
- **C++ baseline**: removed from `main` in 0.8.4 and frozen at branch `backup/main-cpp` (historical reference / rollback only).

## Tech Stack

| Layer | Technology |
|---|---|
| UI / Business | ArkTS (OpenHarmony API 26, Stage model) |
| Native Networking | Rust (ohos-rs, rustls, rcgen, serde, sha2) |
| Build | hvigorw (HarmonyOS), CMake → cargo (native) |
| Protocol | KDE Connect protocol v8 |

## Build

### Prerequisites

- HarmonyOS Command Line Tools (`/opt/command-line-tools`)
- OpenHarmony SDK (`/opt/ohos-sdk`)
- Rust toolchain (the whole native stack is Rust):

  ```bash
  rustup target add aarch64-unknown-linux-ohos x86_64-unknown-linux-ohos
  ```

  CMake only invokes `cargo` to produce `libkdeconnect_napi.so`; architecture, test criteria and
  known risks are in `devdocs/FULL_RUST.md`.
- **Windows cross-build** (DevEco on Win10): 6 user-level environment variables
  (`CC_/AR_*`, `CARGO_TARGET_*_LINKER`) plus `hvigorw --stop-daemon` — see
  `devdocs/CPP_GUIDE.md`, section "Windows 交叉编译前置".
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
entry/src/main/cpp/tests/run.sh
# = cargo test -p kdc_native (19 unit + 1 cross-stack E2E)
#   + cargo check -p kdeconnect_napi (NAPI symbols cannot link on host)
#   + NAPI contract check (Index.d.ts ↔ exported fields)
```

## Project Structure

```
kdeconnect-harmony/
├── entry/src/main/
│   ├── cpp/
│   │   ├── rust/full/        # Rust native workspace
│   │   │   ├── core/         # kdc_native: discovery, tcp, tls, cert, packet, payload, state
│   │   │   └── napi/         # kdeconnect_napi: NAPI exports/events
│   │   └── types/            # Index.d.ts (frozen NAPI contract)
│   ├── ets/
│   │   ├── plugins/          # plugins (registry-driven)
│   │   ├── net/              # PacketRouter
│   │   ├── common/           # PayloadHistory, shared types
│   │   ├── components/       # DevicesTab, SettingsTab, FilesTab, DeviceInfoDialog
│   │   └── pages/            # UI (Index.ets)
│   └── module.json5          # Permissions, abilities
├── tools/                    # sign-debug.sh, check-encoding.py, sync-revision.sh
├── devdocs/                  # Developer guides, runbooks, roadmaps
├── docs/kdeconnect-oh/       # Frozen interface contract & lane playbook (reference)
├── LICENSES/                 # REUSE license texts (GPL-2.0-or-later, CC0-1.0)
├── screenshots/              # App screenshots
├── LICENSE                   # GPL-2.0-or-later
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

## Development Environment

This project is developed across two machines on the same LAN, with file synchronization handled by [Syncthing](https://syncthing.net/):

| Machine | OS | Responsibilities |
|---|---|---|
| **CachyOS** (Linux) | CachyOS (Arch-based) | Rust native development, host-side tests, KDE Connect desktop (for protocol verification), git operations (single writer) |
| **Win10** | Windows 10 LTSC 21H1 | ArkTS development in DevEco Studio, HarmonyOS emulator & real-device debugging (MatePad Mini) |

- Both machines share one working tree via Syncthing — **never edit the same file from both sides simultaneously**
- `.git` exists only on the Linux side; Win10 tracks the corresponding commit via `AgentsConversion/GIT_REVISION.md`
- KDE Connect desktop runs on the CachyOS machine, serving as the protocol counterpart for end-to-end testing

## Development

### Adding a Plugin

1. Create `entry/src/main/ets/plugins/MyPlugin.ets` extending `PluginBase`
2. Declare `supportedPacketTypes` (incoming) and `outgoingPacketTypes` (outgoing)
3. Implement `onPacketReceived()` and optionally `onCreate()`/`onDestroy()`
4. Register in `PluginRegistry` (`Index.ets`)
5. The framework auto-handles capability negotiation and packet routing

### Coding Standards

- Rust: see `devdocs/FULL_RUST.md` (architecture, invariants, tests)
- C++ (historical, frozen at `backup/main-cpp`): see `devdocs/CPP_GUIDE.md`
- ArkTS: see `devdocs/ARKTS_GUIDE.md`
- Workflow: see `devdocs/PROCESS.md`
- All text files must be valid UTF-8 (enforced by `tools/check-encoding.py` pre-commit hook)

## License

GPL-2.0-or-later — compatible with upstream kdeconnect-android (GPL-2.0-only) and
kdeconnect-kde (GPL-2.0-or-later), enabling direct code porting from both. See [LICENSE](LICENSE).

## Agent Division of Labour

Requirements and key decisions come from **security development engineer Gr%1m**; day-to-day implementation, review and verification are split across several AI agents (collaboration rules and pitfalls: `devdocs/PROCESS.md`).

| Role | Scope | Notes |
|---|---|---|
| **omp** (Linux side) | Rust native stack, host tests, real-desktop verification | discovery/TCP/TLS/certs/NAPI bridge/payload; `backup/main-cpp` kept only as historical reference |
| **DevEco Code** (Win10 side) | ArkTS: UI, plugin framework and plugins | Builds in DevEco Studio; verifies on real devices / emulator |
| **CodeArts** | ArkTS/UI owner; code review and adjudication support | Maintains `devdocs/PROCESS.md` and the coordination log `AgentsConversion/` |
| **AtomCode** | Commander: task dispatch, cross-lane coordination, sole commit/push, build & emulator verification | Migration plan, reviews, acceptance criteria |
| **ZCode** | Early C++/native and build bootstrap | Handed over to omp later |

Both sides share one working tree via Syncthing: **never write the same file from both sides**; `.git` exists on the Linux
side only (Win10 tracks "which commit do these files correspond to" through `AgentsConversion/GIT_REVISION.md`, and a
pre-commit encoding guard rejects mojibake).

## Acknowledgments

- [KDE Connect](https://kdeconnect.kde.org/) — the original project by the KDE community
- [kdeconnect-android](https://invent.kde.org/network/kdeconnect-android) — Android reference implementation
- [kdeconnect-kde](https://invent.kde.org/network/kdeconnect-kde) — Desktop reference implementation
- [kdeconnect-meta](https://invent.kde.org/network/kdeconnect-meta) — Protocol schemas
- [Syncthing](https://syncthing.net/) — Decentralized file synchronization powering our dual-machine workflow
