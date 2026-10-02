# TEST_INFRA — Daylight Drop Test Infrastructure Specification

## 1. Test Philosophy: Opaque-Box, Requirement-Driven Testing

Daylight Drop connects macOS and the Daylight Computer DC1 tablet over local Wi-Fi and automatic USB ADB fallback tunneling. Testing must be strictly **opaque-box** and **requirement-driven**:
- **Interface Contract Focus**: Tests exercise external boundaries defined in `PROJECT.md` and `ORIGINAL_REQUEST.md`. They do not bind to internal class names or private implementations in Swift or Kotlin.
- **Protocol & Network Boundaries**:
  - macOS HTTP/WS service listening on port `8765`.
  - Daylight DC1 companion service listening on port `8766`.
  - ADB reverse tunneling (`adb reverse tcp:8765 tcp:8765`) and forward tunneling (`adb forward tcp:8766 tcp:8766`).
  - Wire protocol REST endpoints (`GET /api/health`, `POST /api/drop`, `POST /api/text`, `GET /api/ws`).
  - Protocol loop suppression headers (`X-Daylight-Drop-Origin`) and OS clipboard extras (`com.daylight.drop.origin`).
- **Filesystem & Media Boundaries**:
  - macOS local staging paths: `~/DaylightDrop/incoming/` and `~/DaylightDrop/outgoing/`.
  - DC1 inbound storage: `/sdcard/Download/DaylightDrop/`.
  - Android MediaStore screenshot directory: `/sdcard/Pictures/Screenshots/`.
  - MediaScanner indexing notifications.
- **Hardware & Sol:OS Display Boundaries**:
  - LivePaper display characteristics: 60Hz/120Hz native refresh rate, 8-bit grayscale (256 discrete levels), pure amber frontlight.
  - Zero-EPD principles: zero waveform clear flashes, zero ghosting artifacts, 150ms fluid settling time, no `ACTION_REFRESH_SCREEN` broadcasts.
  - Sol:OS design tokens (`--os-0` to `--os-1000`) and WCAG 2.1 AAA contrast compliance (>= 7.0:1 for normal text, >= 4.5:1 for large text).
  - Target hardware fleet: `rooted 3` (serial `JMBR00380`) and `rooted 4` (serial `JMBR00405`).

---

## 2. Directory Layout

The test infrastructure is located under `tests/` in the project root:

```
tests/
├── e2e/
│   ├── __init__.py                  # Package initializer
│   ├── harness.py                   # Test harness: mock servers, wire protocol stubs, ADB bridge, contrast math
│   ├── runner.py                    # Test orchestrator, CLI interface, TAP/JSON reporter, SLA latency tracker
│   ├── tier1_feature_tests.py       # Tier 1: Functional isolation (>=5 tests per feature, >=115 tests for F1..F23)
│   ├── tier2_boundary_tests.py      # Tier 2: Boundary & stress tests (>=5 tests per feature, >=115 tests for F1..F23)
│   ├── tier3_pairwise_tests.py      # Tier 3: Pairwise combinatorial interactions (>=23 tests)
│   └── tier4_application_tests.py   # Tier 4: Real-world workflows & live hardware verification (>=12 tests)
└── fixtures/
    ├── __init__.py                  # Fixtures package
    ├── generator.py                 # Dynamic test asset generator (images, PDFs, text, payloads)
    ├── sample_screenshots/          # Sample DC1 and macOS screenshots
    ├── sample_documents/            # Sample PDFs and Markdown notes
    └── sample_prompts/              # Sample multiline prompts, code snippets, emojis, UTF-8 text
```

---

## 3. Comprehensive Feature Coverage Inventory (F1 to F23)

Every feature defined in `PROJECT.md` is covered across all four tiers:

| Feature ID | Feature Name | Milestone | Tier 1 Tests | Tier 2 Tests | Tier 3 Coverage | Tier 4 Coverage | SLA Latency Target |
|---|---|---|---|---|---|---|---|
| **F1** | macOS Menu Bar Status Item | M2 | 5 | 5 | Pairwise with F6, F7 | End-to-end tray lifecycle | < 100ms click-to-tray |
| **F2** | "From Daylight" Inbound Shelf | M2 | 5 | 5 | Pairwise with F3, F18 | Inbound receipt & preview | < 200ms preview render |
| **F3** | Drag-Out Retention | M2 | 5 | 5 | Pairwise with F2, F13 | Drag-out to Finder | Seamless (no dismiss) |
| **F4** | "From Mac" Outbound Shelf & Drop Zone | M2 | 5 | 5 | Pairwise with F18, F19 | Drag-in drop beam | < 2000ms transfer |
| **F5** | Status Bar Icon Drag-In | M2 | 5 | 5 | Pairwise with F1, F20 | Direct icon drop beam | < 2000ms transfer |
| **F6** | Quick AI Scratchpad | M2 | 5 | 5 | Pairwise with F16, F22 | Scratchpad Cmd+Enter beam | < 500ms prompt delivery |
| **F7** | Carbon Global Hotkeys | M2 | 5 | 5 | Pairwise with F1, F6 | Hotkey toggle & beam | < 50ms key reaction |
| **F8** | macOS Local Staging | M2 | 5 | 5 | Pairwise with F4, F15 | Atomic file staging | Immediate |
| **F9** | macOS Standalone Utility Packaging | M2 | 5 | 5 | Pairwise with F1, F7 | Accessory process lifecycle | N/A |
| **F10** | Sol:OS 8-Bit Grayscale Tokens | M3 | 5 | 5 | Pairwise with F11, F16 | LivePaper token contrast | WCAG 2.1 AAA (>=7.0:1) |
| **F11** | Zero-EPD Display Compliance | M3 | 5 | 5 | Pairwise with F10, F14 | Fluid 60/120Hz, no clear flash | 150ms fluid settle |
| **F12** | Direct Share Sheet Target | M3 | 5 | 5 | Pairwise with F18, F20 | Android Share Sheet beam | < 2000ms transfer |
| **F13** | Auto Screenshot Sync | M3 | 5 | 5 | Pairwise with F2, F3 | Hardware screenshot to Mac | < 1500ms sync |
| **F14** | Quick Settings Tile | M3 | 5 | 5 | Pairwise with F18, F22 | 1-tap clipboard drop | < 500ms clipboard sync |
| **F15** | Inbound Atomic Storage & Indexing | M3 | 5 | 5 | Pairwise with F8, F21 | DC1 atomic write & MediaScan | < 2000ms file write |
| **F16** | Sol:OS Heads-Up Notification | M3 | 5 | 5 | Pairwise with F6, F10 | Prompt banner & clipboard | < 500ms notification |
| **F17** | Wi-Fi mDNS / Bonjour Discovery | M1 | 5 | 5 | Pairwise with F19, F20 | Subnet discovery failover | < 1000ms discovery |
| **F18** | Embedded HTTP / WebSocket Streaming | M1 | 5 | 5 | Pairwise with F4, F13 | Chunked drop & WS prompt | < 50ms connect |
| **F19** | Asymmetric Port Binding & Tunneling | M1 | 5 | 5 | Pairwise with F18, F20 | Ports 8765/8766 collision test | < 5ms bind |
| **F20** | Automatic USB ADB Fallback | M1 | 5 | 5 | Pairwise with F17, F21 | Wi-Fi disconnect to USB | < 250ms link switch |
| **F21** | High-Speed USB Offline Throughput | M1 | 5 | 5 | Pairwise with F15, F20 | USB-C 50MB payload transfer | >= 31 MB/s, <1ms ping |
| **F22** | 3-Tier Loop Suppression | M1 | 5 | 5 | Pairwise with F6, F14 | Clipboard echo suppression | 0 echo loops |
| **F23** | System End-to-End Integration | M4 | 5 | 5 | Pairwise with all M1-M3 | Full multi-device lifecycle | 100% SLA pass |
| **F24** | Drag-Hover Spring Open | M2 | 5 | 5 | Pairwise with F1, F5 | Hover spring-open workflow | < 300ms spring open |
| **F25** | In-Tray Cmd+V Paste | M2 | 5 | 5 | Pairwise with F4, F6 | In-tray paste-and-beam | < 500ms paste-to-beam |
| **TOTAL** | **25 Features** | | **125** | **125** | **25** | **14** | **289 Total Tests** |

---

## 4. Test Tier Breakdown and Thresholds

### Tier 1: Functional Feature Isolation (>= 125 Tests)
- Tests each feature F1 through F25 independently with positive happy paths and contract expectations.
- 5 targeted test cases per feature covering specification requirements from `PROJECT.md` and `ORIGINAL_REQUEST.md` (including F24 and F25 addenda).
- Verifies exact header names (`X-Daylight-Drop-Id`, `X-Daylight-Drop-Type`, `X-Daylight-Drop-Filename`, `X-Daylight-Drop-Sha256`, `X-Daylight-Drop-Origin`), payload JSON schemas, HTTP status codes (`200 OK`, `400 Bad Request`, `404 Not Found`), and expected responses.

### Tier 2: Boundary Value, Malformed Data & Stress Testing (>= 125 Tests)
- Tests edge cases, resource boundaries, and extreme inputs for all 25 features:
  - 0-byte empty files, 1-byte minimal payloads, and large files (>50MB).
  - Malformed HTTP chunked encoding, missing SHA-256 header, mismatched SHA-256 checksum.
  - Unicode edge cases: multi-byte UTF-8, 4-byte astral plane emojis, RTL Arabic/Hebrew strings, zero-width joiners, newline variations (`\r\n`, `\n`, `\r`), and shell meta-characters.
  - Network stress: rapid-fire bursts (50 requests in rapid succession), simulated port collision on 8765/8766, unexpected socket drops mid-chunk.
  - Loop suppression boundary tests: repeated identical clips, clips with identical text but different origins, expired LRU cache entries.
  - Drag-hover rapid enter/exit boundary timing and in-tray Cmd+V clipboard paste stress.

### Tier 3: Pairwise Combinatorial Interactions (>= 25 Tests)
- Validates cross-feature interactions where subsystems run concurrently:
  - Simultaneous bi-directional transfers (Mac streaming to DC1 while DC1 is streaming screenshot to Mac).
  - Network transition during active file drop (Wi-Fi dropped, USB ADB tunnel takes over mid-transfer).
  - Rapid clipboard copy-paste loops between Mac and DC1 verifying 3-tier suppression across device boundaries.
  - Inbound screenshot arrival while user is actively dragging an item out of the macOS shelf.
  - Drag-hover spring-open during active background drop.
  - In-tray Cmd+V paste during incoming screenshot arrival.

### Tier 4: Real-World Workflows & Live Hardware Verification (>= 14 Tests)
- Comprehensive end-to-end user workflows executed across macOS and Daylight DC1 hardware (`rooted 3` / `rooted 4`):
  - **Workflow 1**: DC1 Hardware Screenshot Zero-Tap Sync to macOS Shelf within 1500ms.
  - **Workflow 2**: macOS Finder Drag-and-Drop to DC1 `/sdcard/Download/DaylightDrop/` within 2000ms with MediaScanner indexing.
  - **Workflow 3**: Quick AI Scratchpad Prompt from macOS Tray (`Cmd + Enter`) setting DC1 Clipboard within 500ms and posting Sol:OS Heads-Up Notification.
  - **Workflow 4**: Android Quick Settings Tile 1-tap clipboard drop to macOS Outbound Shelf within 500ms.
  - **Workflow 5**: Android Direct Share Sheet target (`ACTION_SEND`) beaming image to Mac within 2000ms.
  - **Workflow 6**: Drag-out retention test: item dragged out of "From Daylight" shelf into desktop folder without tray dismissal.
  - **Workflow 7**: Complete Wi-Fi disablement with automated USB ADB fallback failover delivering >= 31 MB/s throughput.
  - **Workflow 8**: Global Hotkey `Cmd + Shift + D` toggle and `Cmd + Shift + V` clipboard beaming without Accessibility permissions.
  - **Workflow 9**: Sol:OS 8-Bit Grayscale Contrast Audit on DC1 LivePaper screen verifying WCAG 2.1 AAA compliance (ratio >= 7.0:1) across `--os-0` through `--os-1000`.
  - **Workflow 10**: Zero-EPD Display Verification on DC1: confirming 60Hz/120Hz refresh, zero waveform clear flashes, no `ACTION_REFRESH_SCREEN` broadcasts, and fluid 150ms settling time.
  - **Workflow 11**: Bi-directional loopback suppression: copying prompt on DC1 does not echo back to Mac, copying on Mac does not echo back to DC1.
  - **Workflow 12**: High-throughput multi-file batch beam (10 screenshots + notes) maintaining sub-2000ms per-item latency under load.
  - **Workflow 13**: Drag-hover spring open on status bar icon automatically reveals floating tray within 300ms.
  - **Workflow 14**: In-tray Cmd+V paste reads Finder copied files or pasteboard images/text and dispatches beam to DC1 within 500ms.

---

## 5. SLA Latency Budgets & Performance Metrics

| Operation | SLA Budget | Metric Target | Verification Method |
|---|---|---|---|
| Hardware Screenshot Sync | < 1500 ms | MediaStore write -> Mac Shelf render | Monotonic clock timestamp difference |
| Quick AI Scratchpad Prompt | < 500 ms | `Cmd + Enter` dispatch -> DC1 clipboard & heads-up banner | WebSocket packet round-trip timing |
| File Drop (Mac to DC1) | < 2000 ms | Drag-in drop -> atomic file write & MediaScanner indexed | REST POST completion & file stat |
| File Drop (DC1 to Mac) | < 2000 ms | Share Sheet action -> Mac incoming staging & thumbnail | REST POST completion & file stat |
| USB-C Offline Throughput | >= 31 MB/s | Transfer speed over `127.0.0.1` ADB tunnel | Bytes transferred / elapsed seconds |
| USB-C Ping Latency | < 1 ms | Local socket ping over forward/reverse tunnel | Socket round-trip ping |
| Sol:OS Settling Time | <= 150 ms | Fluid LivePaper VSYNC frame settling | Post-action perception timestamp delta |
| Sol:OS Token Contrast | WCAG 2.1 AAA | Normal text >= 7.0:1, Large text >= 4.5:1 | Luminance calculation on 8-bit gray scale |

---

## 6. Test Runner Architecture & CLI Invocation

The test runner `tests/e2e/runner.py` is written in pure Python 3 without heavy external dependencies, ensuring instantaneous setup and execution on any developer machine or CI environment.

### CLI Syntax
```bash
# Run all test tiers (mock transport / contract validation)
python3 tests/e2e/runner.py

# Run a specific tier
python3 tests/e2e/runner.py --tier 1
python3 tests/e2e/runner.py --tier 2
python3 tests/e2e/runner.py --tier 3
python3 tests/e2e/runner.py --tier 4

# Run tests for a specific feature
python3 tests/e2e/runner.py --feature F13
python3 tests/e2e/runner.py --feature F6

# Output formats: summary (default), json, or tap (Test Anything Protocol)
python3 tests/e2e/runner.py --format json --output-file /tmp/test_report.json
python3 tests/e2e/runner.py --format tap

# Run against live connected DC1 hardware (rooted 3 / rooted 4)
python3 tests/e2e/runner.py --hardware --device "rooted 3"

# Enforce strict SLA latency checking (fail if any SLA target is breached)
python3 tests/e2e/runner.py --sla-strict
```

### Exit Codes
- `0`: All executed tests passed cleanly and all SLA criteria were satisfied.
- `1`: One or more tests failed, timed out, or breached strict SLA thresholds.
- `2`: Harness error (e.g. invalid arguments, missing hardware when `--hardware` specified).

---

## 7. Mock/Stub Wire Protocol Engine

To enable test execution before, during, and after application implementation, `tests/e2e/harness.py` includes a built-in wire protocol server engine that implements:
1. macOS Service Mock (`0.0.0.0:8765` or ephemeral test port)
2. DC1 Companion Service Mock (`0.0.0.0:8766` or ephemeral test port)
3. Simulated ADB Forward/Reverse Tunneling
4. Simulated MediaStore and File Staging Monitors
5. Sol:OS Grayscale & WCAG Contrast Evaluator
6. Biomechanical touch & LivePaper Zero-EPD assertion verifier

This dual-mode architecture guarantees that the test suite is immediately runnable and acts as an authoritative executable specification for implementation workers.
