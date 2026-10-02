# Project: Daylight Drop

## Architecture Overview
Daylight Drop is a seamless, zero-friction bi-directional sharing and sync system between macOS (via a native Menu Bar tray application with split visual streams and text scratchpad) and the Daylight Computer DC1 (via an Android 13 companion app and foreground service following Sol:OS 8-bit grayscale tokens and Zero-EPD principles).

The system uses a private, zero-cloud peer-to-peer transport engine supporting dual connectivity paths:
1. **Local Wi-Fi Subnet**: Automatic mDNS/Bonjour discovery (`_daylightdrop._tcp.`) and embedded HTTP/WebSocket streaming.
2. **Automatic USB ADB Fallback Tunneling**: Zero-polling ADB daemon tracker (`127.0.0.1:5037` `host:track-devices`) establishing `adb reverse tcp:8765 tcp:8765` (DC1 to Mac) and `adb forward tcp:8766 tcp:8766` (Mac to DC1), achieving 31+ MB/s offline transfers with <1ms ping latency and collision-free port allocation.

```
┌────────────────────────────────────────────────────────────────────────┐
│ macOS ("Daylight Drop" Menu Bar App)                                   │
│  - NSStatusItem + Custom NSPanel (.statusBar level, nonactivating)    │
│  - "From Daylight" Inbound Shelf (QuickLook thumbs, drag-out source)   │
│  - "From Mac" Outbound Shelf (drop zone, staging ~/DaylightDrop)       │
│  - Quick AI Prompt Scratchpad (Cmd + Enter dispatch)                  │
│  - Carbon Global Hotkeys (Cmd+Shift+D toggle, Cmd+Shift+V beam clip)   │
│  - Local HTTP/WS Server (0.0.0.0:8765) & Outbound Client (target :8766)│
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
      ┌────────────────────────────┴─────────────────────────────┐
      │ Dual-Path Peer-to-Peer Transport                         │
      │   Path A: Wi-Fi mDNS (_daylightdrop._tcp.)               │
      │   Path B: USB ADB Tunnel (adb reverse 8765, fwd 8766)    │
      │   Wire Protocol: Chunked HTTP / WS, SHA-256,             │
      │   Loop Suppression (com.daylight.drop.origin)            │
      └────────────────────────────┬─────────────────────────────┘
                                   │
┌──────────────────────────────────┴─────────────────────────────────────┐
│ Daylight Computer DC1 (Android 13 / Sol:OS Companion Service)         │
│  - Sol:OS 8-bit Tokens (--os-0 to --os-1000), Zero-EPD 60-120Hz        │
│  - MediaStore Screenshot Observer (/sdcard/Pictures/Screenshots)       │
│  - Quick Settings Tile (1-tap clipboard via translucent trampoline)    │
│  - Direct Share Sheet Target (ShortcutInfoCompat + Person)             │
│  - Inbound Atomic Storage (/sdcard/Download/DaylightDrop/)             │
│  - Immediate MediaScannerConnection indexing & Heads-Up Notification   │
│  - Local HTTP/WS Server (0.0.0.0:8766) & Outbound Client (target :8765)│
└────────────────────────────────────────────────────────────────────────┘
```

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| F1 | macOS Menu Bar Status Item | Resides in macOS menu bar with custom icon and click handler to toggle tray | M2 | R1.1 |
| F2 | "From Daylight" Inbound Shelf | Horizontal stream displaying received screenshots, notes, PDFs, text cards with QuickLook previews and copy button | M2 | R1.1 |
| F3 | Drag-Out Retention | Prevent premature tray dismissal when dragging items out of "From Daylight" shelf into Finder or external apps | M2 | R1.1 |
| F4 | "From Mac" Outbound Shelf & Drop Zone | Persistent drop zone and history of outbound files beamed to Daylight | M2 | R1.2 |
| F5 | Status Bar Icon Drag-In | Dragging files from Finder directly onto the menu bar icon stages and beams them | M2 | R1.2 |
| F6 | Quick AI Scratchpad | Multi-line text input with `Cmd + Enter` dispatch beaming text to Daylight clipboard | M2 | R1.3 |
| F7 | Carbon Global Hotkeys | `Cmd + Shift + D` (toggle tray) and `Cmd + Shift + V` (beam clipboard) without macOS Accessibility permissions | M2 | R1.4 |
| F8 | macOS Local Staging | Staging under `~/DaylightDrop/incoming` and `~/DaylightDrop/outgoing` with thumbnail generation | M2 | R1.5 |
| F9 | macOS Standalone Utility Packaging | `LSUIElement = true` accessory application behavior without Dock icon | M2 | R1.1 |
| F10 | Sol:OS 8-Bit Grayscale Tokens | Full compliance with `--os-0` (#FFFFFF) to `--os-1000` (#000000) and brand grays, WCAG 2.1 AAA contrast | M3 | R2.1 |
| F11 | Zero-EPD Display Compliance | Native 60Hz/120Hz fluid LivePaper rendering, zero waveform clear flashes, no `ACTION_REFRESH_SCREEN` hooks, 150ms settle | M3 | R2.1 |
| F12 | Direct Share Sheet Target | Android 13 dynamic sharing shortcuts (`ShortcutInfoCompat` + `Person`) ranking Mac at top of Android Share Sheet | M3 | R2.2 |
| F13 | Auto Screenshot Sync | ContentObserver on MediaStore `/sdcard/Pictures/Screenshots` with `IS_PENDING == 0` streaming to Mac in <1500ms | M3 | R2.3 |
| F14 | Quick Settings Tile | Sol:OS pull-down shade tile for 1-tap clipboard beaming using zero-flicker translucent trampoline activity | M3 | R2.4 |
| F15 | Inbound Atomic Storage & Indexing | Atomic writes to `/sdcard/Download/DaylightDrop/` with immediate `MediaScannerConnection.scanFile` indexing | M3 | R2.5 |
| F16 | Sol:OS Heads-Up Notification | Inbound prompt sets system clipboard and posts high-priority Sol:OS heads-up banner | M3 | R2.5 |
| F17 | Wi-Fi mDNS / Bonjour Discovery | Dual advertising/browsing for `_daylightdrop._tcp.` using Network.framework on macOS and NsdManager on Android | M1 | R3.1 |
| F18 | Embedded HTTP / WebSocket Streaming | Chunked HTTP streaming for files (`/api/drop`) and WebSocket (`/api/ws`) for instant prompts/clipboard | M1 | R3.1 |
| F19 | Asymmetric Port Binding & Tunneling | macOS listens on 8765, DC1 listens on 8766; `adb reverse tcp:8765 tcp:8765` and `adb forward tcp:8766 tcp:8766` | M1 | R3.2 |
| F20 | Automatic USB ADB Fallback | Push device tracking via ADB daemon socket (`127.0.0.1:5037` `host:track-devices`), auto-switching to USB offline link | M1 | R3.2 |
| F21 | High-Speed USB Offline Throughput | Delivering 31+ MB/s transfer speed and <1ms latency over USB-C tunnel | M1 | R3.2 |
| F22 | 3-Tier Loop Suppression | Protocol header `X-Daylight-Drop-Origin`, OS clipboard extras (`com.daylight.drop.origin`), and in-memory LRU hash cache | M1 | R3.3 |
| F23 | System End-to-End Integration & Verification | Live verification of all latency budgets, UI gestures, offline failover, and hardware contrast on DC1 (`rooted 3` / `rooted 4`) | M4 | AC |
| F24 | Drag-Hover Spring Open | Hovering over menu bar icon (`draggingEntered:`) automatically springs open floating tray panel | M2 | Addendum |
| F25 | In-Tray Cmd+V Paste | Hitting `Cmd + V` when tray is open pastes clipboard files/images/text to "From Mac" shelf and beams to Daylight | M2 | Addendum |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Transport Engine & Protocol | Shared wire protocol, mDNS discovery, embedded HTTP/WS server/client, ADB tunnel manager, loop suppression | None | DONE |
| M2 | macOS Menu Bar Tray App | Menu bar status item, floating tray NSPanel, drag-out/in handling, Carbon hotkeys, scratchpad, staging | M1 | DONE |
| M3 | Daylight DC1 Companion App | Android 13 service, Sol:OS tokens, screenshot observer, direct share, QS tile, inbound atomic storage & indexing | M1 | DONE |
| M4 | System Integration & Hardware Verification | Deploy to macOS and connected DC1 hardware, pass 100% of E2E tests across Wi-Fi & USB fallback, audit | M1, M2, M3 | DONE |

## Interface Contracts

### 1. Network & Port Allocation
- **macOS HTTP/WS Service**: Listens on `0.0.0.0:8765`.
- **Daylight DC1 HTTP/WS Service**: Listens on `0.0.0.0:8766`.
- **ADB Reverse Tunnel (DC1 -> Mac)**: `adb reverse tcp:8765 tcp:8765` (DC1 connects to `127.0.0.1:8765`).
- **ADB Forward Tunnel (Mac -> DC1)**: `adb forward tcp:8766 tcp:8766` (Mac connects to `127.0.0.1:8766`).
- **Addressing Rule**:
  - Outbound to Daylight DC1 is ALWAYS port `8766` (either `<dc1_ip>:8766` or `127.0.0.1:8766`).
  - Outbound to macOS is ALWAYS port `8765` (either `<mac_ip>:8765` or `127.0.0.1:8765`).

### 2. Wire Protocol REST Endpoints
- `GET /api/health` -> `{"status": "ok", "device_id": string, "device_type": "macos"|"daylight", "version": "1.0"}`
- `POST /api/drop` -> Multipart or chunked stream with headers:
  - `X-Daylight-Drop-Id`: UUID string
  - `X-Daylight-Drop-Type`: `"screenshot"` | `"image"` | `"document"` | `"file"`
  - `X-Daylight-Drop-Filename`: UTF-8 string
  - `X-Daylight-Drop-Sha256`: Hexadecimal SHA-256 string
  - `X-Daylight-Drop-Origin`: Device UUID string
- `POST /api/text` -> JSON payload:
  - `{"id": UUID, "type": "prompt"|"clipboard", "text": string, "origin": string, "timestamp": int64}`
- `GET /api/ws` -> WebSocket duplex connection for live state, instant clipboard events, and ping/pong.

### 3. Loop Suppression Contract
- Pasteboard metadata type: `com.daylight.drop.origin` containing device UUID.
- Android ClipDescription extras: `PersistableBundle` containing key `"com.daylight.drop.origin"`.
- If incoming clipboard content matches the local device's UUID, or if its SHA-256 hash exists in the local 60-second LRU cache, outbound broadcast is suppressed.

## Code Layout
```
scratch/daylight_drop/
├── macos/
│   ├── Package.swift                    # Swift Package / Xcode project definition
│   ├── Sources/
│   │   ├── DaylightDropApp/             # App entry point, AppDelegate, StatusItemController
│   │   ├── UI/                          # SwiftUI FloatingTrayView, Shelves, Scratchpad
│   │   ├── Window/                      # FloatingTrayPanel (NSPanel), DragCoordinator, DragSource
│   │   ├── Hotkeys/                     # CarbonHotKeyManager (Cmd+Shift+D, Cmd+Shift+V)
│   │   ├── Transport/                   # BonjourDiscovery, ADBDeviceTracker, HTTPServer, HTTPClient
│   │   └── Staging/                     # StagingManager, ThumbnailProvider
│   └── Tests/                           # Unit & integration tests for macOS components
├── android/
│   ├── app/
│   │   ├── build.gradle.kts             # Kotlin / Android Gradle build script (minSdk 33)
│   │   └── src/main/
│   │       ├── AndroidManifest.xml      # Service, permissions, direct share metadata
│   │       ├── kotlin/com/daylight/drop/
│   │       │   ├── DaylightDropService.kt   # Foreground service, lifecycle, MulticastLock
│   │       │   ├── MediaStoreObserver.kt    # Screenshot content observer (/sdcard/Pictures/Screenshots)
│   │       │   ├── BeamTrampolineActivity.kt# Translucent focus trampoline for clipboard access
│   │       │   ├── DropTileService.kt       # Quick Settings tile service
│   │       │   ├── InboundStorageManager.kt # Atomic file receiver, MediaScanner indexing
│   │       │   ├── transport/               # NsdDiscovery, AndroidHttpServer, AndroidHttpClient
│   │       │   └── ui/                      # Sol:OS theme, token definitions, companion activity
│   │       └── res/                         # Sol:OS 8-bit styles, colors, drawables, shortcuts.xml
│   └── build.gradle.kts
├── shared/
│   └── protocol/                        # Shared protocol definitions, constants, JSON schemas
└── tests/
    ├── e2e/                             # End-to-end integration test runner & suites
    │   ├── runner.py                    # Test orchestrator across macOS & DC1 hardware
    │   ├── tier1_feature_tests.py       # Tier 1: Functional coverage per feature
    │   ├── tier2_boundary_tests.py      # Tier 2: Boundary & stress tests
    │   ├── tier3_pairwise_tests.py      # Tier 3: Cross-feature interactions (USB/Wi-Fi switch, etc.)
    │   └── tier4_application_tests.py   # Tier 4: Real-world workflows (live hardware end-to-end)
    └── fixtures/                        # Test payloads, sample images, documents, prompts
```
