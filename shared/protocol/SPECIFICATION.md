# Daylight Drop Wire Protocol & Transport Specification

## 1. Protocol Architecture
Daylight Drop is a private peer-to-peer transport protocol operating between macOS (desktop host) and the Daylight Computer DC1 (Android 13 / Sol:OS companion).

### Port Assignments & Routing
- **macOS HTTP/WebSocket Service**: `0.0.0.0:8765`
- **Daylight DC1 HTTP/WebSocket Service**: `0.0.0.0:8766`
- **ADB Reverse Tunnel (DC1 -> Mac)**: `adb reverse tcp:8765 tcp:8765`
- **ADB Forward Tunnel (Mac -> DC1)**: `adb forward tcp:8766 tcp:8766`

### Addressing Invariant
- **Outbound to DC1**: Port `8766` (via Wi-Fi IP or `127.0.0.1:8766` over USB tunnel)
- **Outbound to macOS**: Port `8765` (via Wi-Fi IP or `127.0.0.1:8765` over USB reverse tunnel)

## 2. Service Discovery (mDNS / Bonjour)
- **Service Type**: `_daylightdrop._tcp.`
- **Domain**: `local.`
- **TXT Record Keys**:
  - `devId`: Unique device identifier (UUID or hardware serial)
  - `devName`: Human-readable device name
  - `devModel`: Hardware model (`Mac` or `DC_1`)
  - `role`: Device role (`mac_desktop` or `dc1_tablet`)
  - `port`: Listening port (`8765` or `8766`)
  - `protoVer`: Protocol version (`1.0`)
  - `ip`: IP hint for fast acquisition
  - `wsPath`: `/api/ws`
  - `dropPath`: `/api/drop`

## 3. Wire Protocol Endpoints

### 3.1 `GET /api/health`
- **Request**: No body
- **Response**: `200 OK`
  - Content-Type: `application/json`
  - Body:
    ```json
    {
      "status": "ok",
      "device_id": "mac-7F3A2B1C",
      "device_type": "macos",
      "version": "1.0"
    }
    ```

### 3.2 `POST /api/drop`
Streams binary or multipart content with metadata in HTTP headers:
- **Headers**:
  - `X-Daylight-Drop-Id`: Unique transfer UUID
  - `X-Daylight-Drop-Type`: `screenshot` | `image` | `document` | `file`
  - `X-Daylight-Drop-Filename`: Target UTF-8 filename
  - `X-Daylight-Drop-Sha256`: 64-character hex lowercase SHA-256 checksum
  - `X-Daylight-Drop-Origin`: Sender device ID
  - `Content-Length`: Total payload length in bytes
- **Staging & Verification**:
  1. Staged into `.tmp_<id>_<filename>.part`
  2. SHA-256 computed on-the-fly across chunks
  3. Validated on EOF against `X-Daylight-Drop-Sha256`
  4. On match: atomically renamed to destination `<filename>` and indexed
  5. On mismatch: temporary file deleted, responds `400 Bad Request` with `{"status":"error","error":"checksum_mismatch"}`
- **Success Response**: `200 OK`
  ```json
  {
    "status": "ok",
    "received": true,
    "transfer_id": "a98e72c4-f28a-4081-bb04-4c810d21a201",
    "sha256": "4b227777d4dd1fc61c6f884f48641d02b4d121d3fd328cb08b5531fcacdabf8a",
    "filename": "screenshot.png",
    "bytes": 284192
  }
  ```

### 3.3 `POST /api/text`
Transmits AI prompts and text clips:
- **Request**: `Content-Type: application/json`
  ```json
  {
    "id": "c1f73b08-6a98-48b2-b16f-1262d987d6e4",
    "type": "prompt",
    "text": "Summarize this paper into 3 key takeaways",
    "origin": "mac-7F3A2B1C",
    "timestamp": 1727872800450
  }
  ```
- **Response**: `200 OK`
  ```json
  {
    "status": "ok",
    "received": true,
    "id": "c1f73b08-6a98-48b2-b16f-1262d987d6e4"
  }
  ```

### 3.4 `GET /api/ws`
Full duplex WebSocket connection:
- Handshake via HTTP 101 Switching Protocols
- JSON event frame structure:
  - `type`: `ping` | `pong` | `clipboard` | `status` | `ack`
  - `payload`: Object with event details

## 4. 3-Tier Loop Suppression Strategy
To eliminate infinite ping-pong echo cycles between macOS and Android clipboards:
1. **Tier 1 (Protocol Origin Header)**: Every transfer carries `X-Daylight-Drop-Origin`. Incoming packets originating from the local device ID are immediately dropped.
2. **Tier 2 (OS-Level Clipboard Metadata)**:
   - macOS: AppKit NSPasteboard custom type `com.daylight.drop.origin`
   - Android: `ClipDescription.extras` PersistableBundle containing key `com.daylight.drop.origin`
3. **Tier 3 (In-Memory LRU Deduplication Cache)**:
   - Capacity: 256 items
   - TTL: 60 seconds
   - Entries: SHA-256 of text/content -> timestamp
   - If computed hash is present in cache, outbound beam is suppressed.
