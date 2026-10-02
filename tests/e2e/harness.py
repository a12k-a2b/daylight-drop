"""
Daylight Drop E2E Test Harness
Provides mock endpoints, wire protocol client, SLA measurement, Sol:OS contrast analysis,
and live DC1 hardware bridges for opaque-box testing.
"""

import http.server
import socketserver
import threading
import socket
import json
import time
import uuid
import hashlib
import os
import tempfile
import shutil
import urllib.request
import urllib.error
from typing import Dict, Any, Optional, Tuple, List
import subprocess

# --- Sol:OS Grayscale Color Tokens and WCAG 2.1 AAA Calculations ---

SOL_OS_TOKENS = {
    "--os-0": "#FFFFFF",      # Base paper / ground
    "--os-50": "#F7F7F7",     # Surface panels / cards
    "--os-100": "#DCD5C9",    # Hairline borders / subtle dividers
    "--os-150": "#F5F5F5",    # Recessed canvas / input fields
    "--os-200": "#CCCCCC",    # Disabled controls / inactive indicators
    "--os-300": "#858585",    # Low emphasis / tertiary text / placeholder
    "--os-400": "#535353",    # Secondary text ink / icons
    "--os-800": "#343434",    # Dark fields / pressed states
    "--os-900": "#1A1A1A",    # Primary text ink / headlines
    "--os-1000": "#000000",   # Maximum black ink
}

BRAND_ACCENTS = {
    "yellow": "#CECECE",
    "amber": "#9D9D9E",
    "orange": "#6C6C6D",
}

# SLA Latency Budgets (in milliseconds)
SLA_BUDGETS = {
    "screenshot_sync_ms": 1500.0,
    "quick_prompt_ms": 500.0,
    "file_drop_ms": 2000.0,
    "usb_throughput_mb_s": 31.0,
    "usb_ping_latency_ms": 1.0,
    "livepaper_settle_ms": 150.0,
}


def hex_to_rgb(hex_color: str) -> Tuple[int, int, int]:
    """Parse hex string (#RRGGBB) to (r, g, b) tuple."""
    hex_color = hex_color.lstrip('#')
    if len(hex_color) == 6:
        return int(hex_color[0:2], 16), int(hex_color[2:4], 16), int(hex_color[4:6], 16)
    elif len(hex_color) == 3:
        return int(hex_color[0] * 2, 16), int(hex_color[1] * 2, 16), int(hex_color[2] * 2, 16)
    raise ValueError(f"Invalid hex color: {hex_color}")


def relative_luminance(r: int, g: int, b: int) -> float:
    """Calculate WCAG 2.1 relative luminance for an sRGB / grayscale color."""
    def channel_lum(val: int) -> float:
        c = val / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    return 0.2126 * channel_lum(r) + 0.7152 * channel_lum(g) + 0.0722 * channel_lum(b)


def contrast_ratio(hex1: str, hex2: str) -> float:
    """Compute WCAG 2.1 contrast ratio between two hex colors."""
    l1 = relative_luminance(*hex_to_rgb(hex1))
    l2 = relative_luminance(*hex_to_rgb(hex2))
    lighter = max(l1, l2)
    darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


def evaluate_wcag_aaa(text_hex: str, bg_hex: str, is_large_text: bool = False) -> Tuple[bool, float]:
    """
    Check if color combination passes WCAG 2.1 AAA.
    Threshold: 7.0:1 for normal text, 4.5:1 for large text.
    """
    ratio = contrast_ratio(text_hex, bg_hex)
    threshold = 4.5 if is_large_text else 7.0
    return ratio >= threshold, ratio


# --- Wire Protocol Mock Server ---

class MockDropServerHandler(http.server.BaseHTTPRequestHandler):
    """Handles HTTP wire protocol requests per PROJECT.md interface contracts."""

    def log_message(self, format, *args):
        # Suppress noisy standard HTTP access logging during automated test runs
        pass

    @property
    def server_instance(self):
        return self.server.harness_ref

    def do_GET(self):
        start_time = time.perf_counter()
        if self.path == "/api/health":
            body = json.dumps({
                "status": "ok",
                "device_id": self.server_instance.device_id,
                "device_type": self.server_instance.device_type,
                "version": "1.0",
            }).encode('utf-8')
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.server_instance.record_metric("health_check_ms", (time.perf_counter() - start_time) * 1000)
            return

        if self.path == "/api/ws":
            # Simple simulation of WebSocket handshake upgrade for test suite
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
            self.end_headers()
            self.server_instance.record_metric("ws_handshake_ms", (time.perf_counter() - start_time) * 1000)
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        start_time = time.perf_counter()
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length) if content_length > 0 else b""

        if self.path == "/api/drop":
            drop_id = self.headers.get("X-Daylight-Drop-Id")
            drop_type = self.headers.get("X-Daylight-Drop-Type")
            drop_filename = self.headers.get("X-Daylight-Drop-Filename")
            expected_sha256 = self.headers.get("X-Daylight-Drop-Sha256")
            origin = self.headers.get("X-Daylight-Drop-Origin")

            # Contract verification
            if not drop_id or not drop_type or not drop_filename or not expected_sha256 or not origin:
                self.send_response(400)
                resp = json.dumps({"error": "Missing required X-Daylight-Drop headers"}).encode('utf-8')
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)
                return

            actual_sha256 = hashlib.sha256(body_bytes).hexdigest()
            if actual_sha256.lower() != expected_sha256.lower():
                self.send_response(400)
                resp = json.dumps({
                    "error": "SHA-256 checksum mismatch",
                    "expected": expected_sha256,
                    "actual": actual_sha256
                }).encode('utf-8')
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)
                return

            # Save to staging if configured
            if self.server_instance.staging_dir:
                file_path = os.path.join(self.server_instance.staging_dir, drop_filename)
                with open(file_path, "wb") as f:
                    f.write(body_bytes)

            self.server_instance.record_drop({
                "id": drop_id,
                "type": drop_type,
                "filename": drop_filename,
                "sha256": actual_sha256,
                "origin": origin,
                "bytes": len(body_bytes),
                "timestamp": time.time(),
            })

            elapsed_ms = (time.perf_counter() - start_time) * 1000
            self.server_instance.record_metric("drop_receipt_ms", elapsed_ms)

            self.send_response(200)
            resp = json.dumps({
                "status": "received",
                "id": drop_id,
                "bytes": len(body_bytes),
                "sha256": actual_sha256
            }).encode('utf-8')
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return

        if self.path == "/api/text":
            try:
                data = json.loads(body_bytes.decode('utf-8'))
            except Exception:
                self.send_response(400)
                resp = json.dumps({"error": "Invalid JSON body"}).encode('utf-8')
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)
                return

            req_id = data.get("id")
            text_type = data.get("type")
            text_content = data.get("text")
            origin = data.get("origin")

            if not req_id or not text_type or text_content is None or not origin:
                self.send_response(400)
                resp = json.dumps({"error": "Missing id, type, text, or origin"}).encode('utf-8')
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)
                return

            # Loop suppression check:
            # 1. Match local device ID
            # 2. SHA-256 duplicate within 60s LRU window
            suppressed = False
            text_hash = hashlib.sha256(text_content.encode('utf-8')).hexdigest()
            now = time.time()

            if origin == self.server_instance.device_id:
                suppressed = True
                suppression_reason = "Origin matches local device UUID"
            elif self.server_instance.is_hash_in_lru(text_hash, now):
                suppressed = True
                suppression_reason = "SHA-256 hash in 60s LRU suppression cache"
            else:
                suppression_reason = None
                self.server_instance.add_hash_to_lru(text_hash, now)

            record = {
                "id": req_id,
                "type": text_type,
                "text": text_content,
                "origin": origin,
                "suppressed": suppressed,
                "suppression_reason": suppression_reason,
                "timestamp": now,
            }
            self.server_instance.record_text(record)

            elapsed_ms = (time.perf_counter() - start_time) * 1000
            self.server_instance.record_metric("text_receipt_ms", elapsed_ms)

            self.send_response(200)
            resp = json.dumps({
                "status": "applied",
                "id": req_id,
                "suppressed": suppressed,
                "reason": suppression_reason
            }).encode('utf-8')
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return

        self.send_response(404)
        self.end_headers()


class MockDropServer:
    """Threaded HTTP server exposing Daylight Drop REST / WS endpoints."""

    def __init__(self, port: int = 0, device_id: Optional[str] = None, device_type: str = "macos", staging_dir: Optional[str] = None):
        self.port = port
        self.device_id = device_id or str(uuid.uuid4())
        self.device_type = device_type
        self.staging_dir = staging_dir
        self.received_drops: List[Dict[str, Any]] = []
        self.received_texts: List[Dict[str, Any]] = []
        self.metrics: Dict[str, List[float]] = {}
        self.lru_cache: Dict[str, float] = {}  # sha256 -> timestamp
        self._server: Optional[socketserver.TCPServer] = None
        self._thread: Optional[threading.Thread] = None

    def start(self):
        class ReusableTCPServer(socketserver.TCPServer):
            allow_reuse_address = True

        self._server = ReusableTCPServer(("127.0.0.1", self.port), MockDropServerHandler)
        self._server.harness_ref = self
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def stop(self):
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        if self._thread:
            self._thread.join(timeout=2.0)
            self._thread = None

    def record_drop(self, drop_data: Dict[str, Any]):
        self.received_drops.append(drop_data)

    def record_text(self, text_data: Dict[str, Any]):
        self.received_texts.append(text_data)

    def record_metric(self, name: str, val_ms: float):
        if name not in self.metrics:
            self.metrics[name] = []
        self.metrics[name].append(val_ms)

    def is_hash_in_lru(self, text_hash: str, now: float) -> bool:
        if text_hash in self.lru_cache:
            if now - self.lru_cache[text_hash] <= 60.0:
                return True
        return False

    def add_hash_to_lru(self, text_hash: str, now: float):
        self.lru_cache[text_hash] = now
        # Prune older than 60s
        for h, t in list(self.lru_cache.items()):
            if now - t > 60.0:
                del self.lru_cache[h]


# --- Wire Protocol Client ---

class DropClient:
    """Client for dispatching Daylight Drop requests and profiling timing."""

    def __init__(self, host: str = "127.0.0.1", port: int = 8765, local_device_id: Optional[str] = None):
        self.host = host
        self.port = port
        self.local_device_id = local_device_id or str(uuid.uuid4())

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def check_health(self, timeout: float = 2.0) -> Tuple[int, Dict[str, Any], float]:
        """Perform GET /api/health and measure latency in milliseconds."""
        url = f"{self.base_url}/api/health"
        req = urllib.request.Request(url, method="GET")
        start = time.perf_counter()
        with urllib.request.urlopen(req, timeout=timeout) as response:
            latency_ms = (time.perf_counter() - start) * 1000
            data = json.loads(response.read().decode('utf-8'))
            return response.status, data, latency_ms

    def send_file_drop(
        self,
        filename: str,
        data: bytes,
        drop_type: str = "file",
        drop_id: Optional[str] = None,
        origin: Optional[str] = None,
        custom_sha256: Optional[str] = None,
        timeout: float = 5.0
    ) -> Tuple[int, Dict[str, Any], float]:
        """Send POST /api/drop file payload and return (status, body, latency_ms)."""
        url = f"{self.base_url}/api/drop"
        drop_id = drop_id or str(uuid.uuid4())
        origin = origin or self.local_device_id
        sha256_hash = custom_sha256 if custom_sha256 is not None else hashlib.sha256(data).hexdigest()

        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Content-Type": "application/octet-stream",
                "X-Daylight-Drop-Id": drop_id,
                "X-Daylight-Drop-Type": drop_type,
                "X-Daylight-Drop-Filename": filename,
                "X-Daylight-Drop-Sha256": sha256_hash,
                "X-Daylight-Drop-Origin": origin,
            },
            method="POST"
        )
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                latency_ms = (time.perf_counter() - start) * 1000
                res_body = json.loads(response.read().decode('utf-8'))
                return response.status, res_body, latency_ms
        except urllib.error.HTTPError as e:
            latency_ms = (time.perf_counter() - start) * 1000
            try:
                err_body = json.loads(e.read().decode('utf-8'))
            except Exception:
                err_body = {"raw": str(e)}
            return e.code, err_body, latency_ms

    def send_text(
        self,
        text: str,
        text_type: str = "prompt",
        text_id: Optional[str] = None,
        origin: Optional[str] = None,
        timeout: float = 3.0
    ) -> Tuple[int, Dict[str, Any], float]:
        """Send POST /api/text and return (status, body, latency_ms)."""
        url = f"{self.base_url}/api/text"
        payload = {
            "id": text_id or str(uuid.uuid4()),
            "type": text_type,
            "text": text,
            "origin": origin or self.local_device_id,
            "timestamp": int(time.time() * 1000),
        }
        body_bytes = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(
            url,
            data=body_bytes,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                latency_ms = (time.perf_counter() - start) * 1000
                res_body = json.loads(response.read().decode('utf-8'))
                return response.status, res_body, latency_ms
        except urllib.error.HTTPError as e:
            latency_ms = (time.perf_counter() - start) * 1000
            try:
                err_body = json.loads(e.read().decode('utf-8'))
            except Exception:
                err_body = {"raw": str(e)}
            return e.code, err_body, latency_ms


# --- ADB and Hardware Bridge ---

class DaylightHardwareBridge:
    """Interface to communicate with connected DC1 hardware tablets ('rooted 3', 'rooted 4')."""

    ALIASES = {
        "rooted 3": "JMBR00380",
        "rooted 4": "JMBR00405",
        "JMBR00380": "JMBR00380",
        "JMBR00405": "JMBR00405",
    }

    def __init__(self, target_device: str = "rooted 3"):
        self.serial = self.ALIASES.get(target_device, target_device)

    def is_connected(self) -> bool:
        """Check if target device is present in adb devices output."""
        try:
            out = subprocess.check_output(["adb", "devices"], universal_newlines=True, timeout=3.0)
            for line in out.strip().split("\n")[1:]:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == self.serial and parts[1] == "device":
                    return True
        except Exception:
            pass
        return False

    def run_adb_cmd(self, args: List[str], timeout: float = 5.0) -> str:
        """Execute adb command targeted to this device serial."""
        cmd = ["adb", "-s", self.serial] + args
        return subprocess.check_output(cmd, universal_newlines=True, timeout=timeout)

    def setup_reverse_tunnel(self, remote_port: int = 8765, local_port: int = 8765) -> bool:
        """Execute adb reverse tcp:<remote_port> tcp:<local_port>."""
        try:
            self.run_adb_cmd(["reverse", f"tcp:{remote_port}", f"tcp:{local_port}"])
            return True
        except Exception:
            return False

    def setup_forward_tunnel(self, local_port: int = 8766, remote_port: int = 8766) -> bool:
        """Execute adb forward tcp:<local_port> tcp:<remote_port>."""
        try:
            self.run_adb_cmd(["forward", f"tcp:{local_port}", f"tcp:{remote_port}"])
            return True
        except Exception:
            return False

    def remove_tunnels(self):
        """Remove tunnels for this device."""
        try:
            self.run_adb_cmd(["reverse", "--remove-all"])
            self.run_adb_cmd(["forward", "--remove-all"])
        except Exception:
            pass
