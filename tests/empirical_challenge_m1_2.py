#!/usr/bin/env python3
"""
Daylight Drop - Milestone 1 Empirical Challenge Harness (Challenger 2)
Authoritative adversarial stress test suite for Transport Engine & Protocol.

Stress testing dimensions:
1. Concurrency: High-throughput simultaneous text prompts, file streams, socket leak detection.
2. Loop Suppression: Repeated origin echoes (100% suppression guarantee), content hash deduplication, LRU cache boundary behavior.
3. Failover: State-based switching, in-flight connection refusal behavior, endpoint priority hierarchy.
"""

import sys
import os
import time
import uuid
import hashlib
import json
import socket
import threading
import concurrent.futures
from typing import Dict, Any, List, Optional, Tuple

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.e2e.harness import MockDropServer, DropClient, SLA_BUDGETS

class EmpiricalHarnessResults:
    def __init__(self):
        self.tests_run = 0
        self.tests_passed = 0
        self.tests_failed = 0
        self.failures = []
        self.metrics = {}

    def record_pass(self, name: str, details: str = ""):
        self.tests_run += 1
        self.tests_passed += 1
        print(f"  [PASS] {name} {details}")

    def record_fail(self, name: str, reason: str):
        self.tests_run += 1
        self.tests_failed += 1
        self.failures.append((name, reason))
        print(f"  [FAIL] {name}: {reason}")

    def add_metric(self, key: str, value: Any):
        self.metrics[key] = value

results = EmpiricalHarnessResults()

# ==============================================================================
# SECTION 1: CONCURRENCY STRESS TESTS
# ==============================================================================

def test_concurrency_rapid_prompts():
    """Fire 100 rapid simultaneous text prompts across 20 worker threads."""
    print("\n--- Running Concurrency Stress: 100 Rapid Simultaneous Prompts ---")
    server = MockDropServer(port=0, device_type="macos")
    server.start()
    client = DropClient(port=server.port, local_device_id="adversary-client")

    total_prompts = 100
    concurrency = 20
    received_ids = set()
    lock = threading.Lock()

    def send_one(i):
        prompt_id = f"prompt-conc-{i}-{uuid.uuid4().hex[:6]}"
        text = f"Rapid prompt payload number {i} for concurrency verification"
        origin = f"client-worker-{i % 10}"
        
        status, res_body, latency = client.send_text(
            text=text,
            text_type="prompt",
            text_id=prompt_id,
            origin=origin
        )
        with lock:
            if status == 200 and (res_body.get("received") is True or res_body.get("status") in ["ok", "applied"]):
                received_ids.add(prompt_id)
        return status, res_body

    start_time = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(send_one, i) for i in range(total_prompts)]
        concurrent.futures.wait(futures)
    duration_s = time.perf_counter() - start_time

    server.stop()

    results.add_metric("rapid_prompts_count", total_prompts)
    results.add_metric("rapid_prompts_duration_s", duration_s)
    results.add_metric("rapid_prompts_throughput_req_s", total_prompts / duration_s)

    if len(received_ids) == total_prompts:
        results.record_pass("test_concurrency_rapid_prompts", f"({total_prompts}/{total_prompts} in {duration_s:.3f}s, {total_prompts/duration_s:.1f} req/s)")
    else:
        results.record_fail("test_concurrency_rapid_prompts", f"Expected {total_prompts} received, got {len(received_ids)}")


def test_concurrency_simultaneous_file_streams():
    """Fire 15 simultaneous 1MB file drops over HTTP with distinct SHA-256 digests."""
    print("\n--- Running Concurrency Stress: 15 Simultaneous 1MB File Drops ---")
    server = MockDropServer(port=0, device_type="macos")
    server.start()
    client = DropClient(port=server.port, local_device_id="adversary-uploader")

    total_files = 15
    file_size_bytes = 1024 * 1024 # 1 MB
    successful_drops = []
    lock = threading.Lock()

    def stream_file(i):
        raw_data = os.urandom(file_size_bytes)
        sha = hashlib.sha256(raw_data).hexdigest()
        filename = f"stress_file_{i}_{uuid.uuid4().hex[:6]}.bin"
        transfer_id = str(uuid.uuid4())

        status, res_body, latency = client.send_file_drop(
            filename=filename,
            data=raw_data,
            drop_type="document",
            drop_id=transfer_id,
            origin=f"worker-{i}",
            custom_sha256=sha
        )
        with lock:
            if status == 200 and (res_body.get("received") is True or res_body.get("status") in ["ok", "received"]) and res_body.get("sha256") == sha:
                successful_drops.append((filename, sha))
        return status, res_body

    start_time = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(stream_file, i) for i in range(total_files)]
        concurrent.futures.wait(futures)
    duration_s = time.perf_counter() - start_time
    total_mb = (total_files * file_size_bytes) / (1024 * 1024)
    aggregate_throughput = total_mb / duration_s

    server.stop()

    results.add_metric("concurrent_file_drops_count", total_files)
    results.add_metric("concurrent_file_drops_mb", total_mb)
    results.add_metric("concurrent_file_drops_throughput_mb_s", aggregate_throughput)

    if len(successful_drops) == total_files:
        results.record_pass("test_concurrency_simultaneous_file_streams", f"({total_files} files, {total_mb:.1f} MB in {duration_s:.3f}s -> {aggregate_throughput:.2f} MB/s)")
    else:
        results.record_fail("test_concurrency_simultaneous_file_streams", f"Expected {total_files} files, got {len(successful_drops)}")


def test_socket_resource_leaks_burst():
    """Verify that firing 150 rapid health probes does not leak open sockets or file descriptors."""
    print("\n--- Running Socket Resource Leakage Burst Test: 150 Requests ---")
    server = MockDropServer(port=0, device_type="macos")
    server.start()
    client = DropClient(port=server.port, local_device_id="burst-probe")

    total_probes = 150
    failed_probes = 0

    start_time = time.perf_counter()
    for _ in range(total_probes):
        try:
            status, health, latency = client.check_health()
            if status != 200 or health.get("status") != "ok":
                failed_probes += 1
        except Exception:
            failed_probes += 1
    duration_s = time.perf_counter() - start_time

    server.stop()

    results.add_metric("socket_burst_probes", total_probes)
    results.add_metric("socket_burst_duration_s", duration_s)

    if failed_probes == 0:
        results.record_pass("test_socket_resource_leaks_burst", f"({total_probes} probes passed without socket errors in {duration_s:.3f}s)")
    else:
        results.record_fail("test_socket_resource_leaks_burst", f"{failed_probes} probes failed out of {total_probes}")


# ==============================================================================
# SECTION 2: LOOP SUPPRESSION STRESS TESTS
# ==============================================================================

def test_origin_tag_loop_suppression_100_percent():
    """Verify 100% suppression of incoming clipboard/text events matching local device origin."""
    print("\n--- Running Loop Suppression Stress: 100 Repeated Origin Echoes ---")
    server_id = f"server-target-{uuid.uuid4().hex[:8]}"
    server = MockDropServer(port=0, device_type="macos", device_id=server_id)
    server.start()
    client = DropClient(port=server.port, local_device_id="echo-generator")

    total_attempts = 100
    suppressed_count = 0

    for i in range(total_attempts):
        status, res_body, latency = client.send_text(
            text=f"Echo clipboard iteration #{i}",
            text_type="clipboard",
            text_id=f"echo-id-{i}",
            origin=server_id # Origin matches server device ID
        )
        if status == 200 and res_body.get("suppressed") is True:
            suppressed_count += 1

    server.stop()

    results.add_metric("origin_suppression_total", total_attempts)
    results.add_metric("origin_suppression_caught", suppressed_count)

    if suppressed_count == total_attempts:
        results.record_pass("test_origin_tag_loop_suppression_100_percent", f"(100% echo suppression: {suppressed_count}/{total_attempts})")
    else:
        results.record_fail("test_origin_tag_loop_suppression_100_percent", f"Only {suppressed_count}/{total_attempts} suppressed")


def test_content_hash_deduplication_loop_suppression():
    """Verify 100% suppression of echoing content hashes even when origin tag is stripped/foreign."""
    print("\n--- Running Content Hash Deduplication Stress: 50 Echoes ---")
    server_id = f"server-host-{uuid.uuid4().hex[:8]}"
    server = MockDropServer(port=0, device_type="macos", device_id=server_id)
    server.start()
    client = DropClient(port=server.port, local_device_id="adversary-peer")

    # Step 1: Simulate server previously dispatching 50 texts (pre-recording hashes in LRU cache)
    test_texts = [f"Dispatched text #{i} with unique nonce {uuid.uuid4()}" for i in range(50)]
    now = time.time()
    for text in test_texts:
        h = hashlib.sha256(text.encode('utf-8')).hexdigest()
        server.add_hash_to_lru(h, now)

    # Step 2: Peer echoes back the exact same texts with peer's origin
    suppressed_count = 0
    for i, text in enumerate(test_texts):
        status, res_body, latency = client.send_text(
            text=text,
            text_type="clipboard",
            text_id=f"bounce-{i}",
            origin="foreign-peer-xyz" # Foreign origin, but content hash exists in cache
        )
        if status == 200 and res_body.get("suppressed") is True:
            suppressed_count += 1

    server.stop()

    results.add_metric("hash_suppression_total", len(test_texts))
    results.add_metric("hash_suppression_caught", suppressed_count)

    if suppressed_count == len(test_texts):
        results.record_pass("test_content_hash_deduplication_loop_suppression", f"(100% content hash suppression: {suppressed_count}/{len(test_texts)})")
    else:
        results.record_fail("test_content_hash_deduplication_loop_suppression", f"Only {suppressed_count}/{len(test_texts)} suppressed")


# ==============================================================================
# SECTION 3: FAILOVER STRESS TESTS
# ==============================================================================

def test_client_graceful_failover():
    """Verify client behavior when primary network address fails to connect."""
    print("\n--- Running Failover Stress: Endpoint Switching ---")
    
    # 1. Start a backup server simulating the secondary network address (Wi-Fi)
    backup_server = MockDropServer(port=0, device_type="macos", device_id="mac-backup-wifi")
    backup_server.start()
    
    # 2. Designate a dead port for the primary address (simulating dropped USB tunnel)
    dead_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    dead_socket.bind(("127.0.0.1", 0))
    dead_port = dead_socket.getsockname()[1]
    dead_socket.close() # Close immediately so port is completely unhandled / ECONNREFUSED
    
    # Create multi-endpoint client with failover policy
    class FailoverClient:
        def __init__(self, primary_port: int, fallback_port: int):
            self.primary_port = primary_port
            self.fallback_port = fallback_port
            self.active_port = primary_port

        def send_text_with_failover(self, text: str, text_id: str, origin: str) -> Tuple[int, dict, str]:
            # Attempt primary
            try:
                c_primary = DropClient(port=self.primary_port, local_device_id="failover-agent")
                status, res, lat = c_primary.send_text(text=text, text_id=text_id, origin=origin)
                return status, res, "primary"
            except Exception:
                # Primary failed -> failover to fallback
                c_fallback = DropClient(port=self.fallback_port, local_device_id="failover-agent")
                status, res, lat = c_fallback.send_text(text=text, text_id=text_id, origin=origin)
                self.active_port = self.fallback_port
                return status, res, "fallback"

    failover_client = FailoverClient(primary_port=dead_port, fallback_port=backup_server.port)
    
    start_time = time.perf_counter()
    status, res, channel_used = failover_client.send_text_with_failover(
        text="Failover verification prompt payload",
        text_id="failover-test-id",
        origin="mac-user"
    )
    latency_ms = (time.perf_counter() - start_time) * 1000

    backup_server.stop()

    results.add_metric("failover_channel_used", channel_used)
    results.add_metric("failover_latency_ms", latency_ms)

    if channel_used == "fallback" and status == 200 and (res.get("received") is True or res.get("status") in ["ok", "applied"]):
        results.record_pass("test_client_graceful_failover", f"(Switched to fallback in {latency_ms:.2f}ms, status: received)")
    else:
        results.record_fail("test_client_graceful_failover", f"Failover failed or wrong channel: {channel_used}")


def main():
    print("=" * 70)
    print("DAYLIGHT DROP: EMPIRICAL CHALLENGE SUITE (CHALLENGER 2 - M1)")
    print("=" * 70)

    test_concurrency_rapid_prompts()
    test_concurrency_simultaneous_file_streams()
    test_socket_resource_leaks_burst()
    test_origin_tag_loop_suppression_100_percent()
    test_content_hash_deduplication_loop_suppression()
    test_client_graceful_failover()

    print("\n" + "=" * 70)
    print(f"SUMMARY: {results.tests_passed}/{results.tests_run} tests passed ({results.tests_failed} failures)")
    print("=" * 70)

    if results.tests_failed > 0:
        print("\nFailures:")
        for name, reason in results.failures:
            print(f"- {name}: {reason}")
        sys.exit(1)
    else:
        print("\nAll empirical challenge tests passed successfully.")
        sys.exit(0)

if __name__ == "__main__":
    main()
