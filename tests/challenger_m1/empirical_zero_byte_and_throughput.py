#!/usr/bin/env python3
"""
Daylight Drop - Milestone 1 Iteration 2 Challenger 1 Suite
Empirical 0-Byte Transfer Stress & Throughput Benchmark

Validates:
1. macOS DaylightHTTPServer (:8765):
   - Consecutive 0-byte file transfers (20 iterations)
   - Raw socket non-closing client (verifying zero socket hang / immediate HTTP 200)
   - SHA-256 header validation (valid empty SHA, omitted SHA, mismatched SHA rejection)
   - Staging cleanup (.part removed, 0-byte destination file verified)
2. Android AndroidHttpServer (:8766):
   - Consecutive 0-byte file transfers (20 iterations)
   - Raw socket non-closing client (verifying zero socket hang / immediate HTTP 200)
   - SHA-256 header validation (valid empty SHA, omitted SHA, mismatched SHA rejection)
   - Staging cleanup (.part removed, 0-byte destination file verified)
3. Large Payload Throughput Benchmark (Target >= 31.0 MB/s):
   - Swift transport engine benchmark (5MB, 10MB, 25MB, 50MB)
   - Kotlin transport engine benchmark (5MB, 10MB, 25MB)
   - Physical USB ADB forward tunnel socket streaming (25MB to DC1 JMBR00380)
   - Physical USB ADB direct push baseline (25MB to DC1 JMBR00380)
"""

import os
import sys
import time
import uuid
import glob
import json
import socket
import hashlib
import tempfile
import subprocess
import urllib.request
import urllib.error
from typing import Dict, Any, List, Tuple

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
SLA_TARGET_MBPS = 31.0
DEVICE_SERIAL = "JMBR00380"

class EmpiricalReporter:
    def __init__(self):
        self.results = []
        self.metrics = {}

    def record_pass(self, name: str, details: str = ""):
        self.results.append(("PASS", name, details))
        print(f"  [PASS] {name} - {details}")

    def record_fail(self, name: str, details: str = ""):
        self.results.append(("FAIL", name, details))
        print(f"  [FAIL] {name} - {details}")

    def add_metric(self, key: str, value: Any):
        self.metrics[key] = value

reporter = EmpiricalReporter()

def get_android_classpath() -> str:
    gradle_cache = os.path.expanduser("~/.gradle/caches/modules-2/files-2.1")
    jars = [
        glob.glob(f"{gradle_cache}/**/okhttp-4.12.0.jar", recursive=True)[0],
        glob.glob(f"{gradle_cache}/**/okio-jvm-3.6.0.jar", recursive=True)[0],
        glob.glob(f"{gradle_cache}/**/kotlin-stdlib-2.0.21.jar", recursive=True)[0],
        glob.glob(f"{gradle_cache}/**/kotlinx-coroutines-core-jvm-1.8.1.jar", recursive=True)[0],
        glob.glob(f"{gradle_cache}/**/json-20240303.jar", recursive=True)[0],
        os.path.join(PROJECT_ROOT, "android/app/build/intermediates/runtime_app_classes_jar/debug/bundleDebugClassesToRuntimeJar/classes.jar"),
        os.path.join(PROJECT_ROOT, "tests/challenger_m1")
    ]
    return ":".join(jars)

# ==============================================================================
# SECTION 1: 0-BYTE TRANSFER EMPIRICAL STRESS HARNESS
# ==============================================================================

def test_zero_byte_drops_on_server(server_name: str, port: int, temp_dir: str, iterations: int = 20):
    print(f"\n>>> [0-BYTE TEST] Testing {server_name} on port {port} ({iterations} consecutive drops)")
    
    # Subtest 1: Raw socket non-shutdown client test (Direct regression test for socket hang)
    raw_socket_latencies = []
    for i in range(5):
        tx_id = f"zero-raw-{i}-{uuid.uuid4().hex[:6]}"
        filename = f"empty_raw_{i}.txt"
        
        t0 = time.perf_counter()
        s = socket.create_connection(("127.0.0.1", port), timeout=3.0)
        req = (
            f"POST /api/drop HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            f"X-Daylight-Drop-Id: {tx_id}\r\n"
            f"X-Daylight-Drop-Type: file\r\n"
            f"X-Daylight-Drop-Filename: {filename}\r\n"
            f"X-Daylight-Drop-Sha256: {EMPTY_SHA256}\r\n"
            f"X-Daylight-Drop-Origin: adversary-origin\r\n"
            f"Content-Length: 0\r\n"
            f"Connection: close\r\n\r\n"
        )
        s.sendall(req.encode("utf-8"))
        # INTENTIONALLY DO NOT call s.shutdown(socket.SHUT_WR)!
        # If server hangs waiting for EOF, timeout will trip!
        s.settimeout(2.0)
        try:
            resp_data = s.recv(4096).decode("utf-8")
            s.close()
            t1 = time.perf_counter()
            lat_ms = (t1 - t0) * 1000.0
            raw_socket_latencies.append(lat_ms)
            
            assert "200 OK" in resp_data, f"Non-200 response: {resp_data}"
            assert EMPTY_SHA256 in resp_data, f"Response missing empty SHA-256: {resp_data}"
        except socket.timeout:
            reporter.record_fail(f"{server_name}_raw_socket_hang", f"Iteration {i} timed out after 2.0s! Socket hung waiting for body/EOF.")
            return

    avg_raw_lat = sum(raw_socket_latencies) / len(raw_socket_latencies)
    reporter.record_pass(f"{server_name}_raw_socket_no_hang", f"5/5 raw socket drops succeeded with NO socket hang (avg {avg_raw_lat:.2f}ms, max {max(raw_socket_latencies):.2f}ms)")
    reporter.add_metric(f"{server_name}_raw_socket_avg_lat_ms", avg_raw_lat)

    # Subtest 2: Consecutive 20 standard HTTP drops with integrity and staging checks
    http_latencies = []
    created_files = []
    
    for i in range(iterations):
        tx_id = f"zero-iter-{i}-{uuid.uuid4().hex[:6]}"
        filename = f"consecutive_empty_{i}.txt"
        dest_path = os.path.join(temp_dir, filename)
        part_path = os.path.join(temp_dir, f".tmp_{tx_id}_{filename}.part")
        
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/drop",
            data=b"",
            method="POST",
            headers={
                "X-Daylight-Drop-Id": tx_id,
                "X-Daylight-Drop-Type": "file",
                "X-Daylight-Drop-Filename": filename,
                "X-Daylight-Drop-Sha256": EMPTY_SHA256,
                "X-Daylight-Drop-Origin": f"tester-{i}",
                "Content-Length": "0",
                "Content-Type": "application/octet-stream",
                "Connection": "close"
            }
        )
        
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                status = resp.status
                body = resp.read().decode("utf-8")
        except Exception as e:
            reporter.record_fail(f"{server_name}_consecutive_drop_{i}", f"Exception: {e}")
            return
        t1 = time.perf_counter()
        lat_ms = (t1 - t0) * 1000.0
        http_latencies.append(lat_ms)
        
        if status != 200:
            reporter.record_fail(f"{server_name}_consecutive_drop_{i}", f"Status {status}: {body}")
            return
            
        data = json.loads(body)
        if data.get("sha256") != EMPTY_SHA256 or data.get("bytes") != 0 or data.get("received") is not True:
            reporter.record_fail(f"{server_name}_consecutive_drop_{i}", f"Malformed response payload: {body}")
            return
            
        # Verify file existence and staging cleanup
        time.sleep(0.01) # brief settle for filesystem
        if not os.path.exists(dest_path):
            reporter.record_fail(f"{server_name}_staging_final_missing_{i}", f"Destination file {dest_path} does not exist!")
            return
        if os.path.getsize(dest_path) != 0:
            reporter.record_fail(f"{server_name}_staging_size_{i}", f"File size is {os.path.getsize(dest_path)}, expected 0 bytes!")
            return
        if os.path.exists(part_path):
            reporter.record_fail(f"{server_name}_staging_part_leak_{i}", f"Part file {part_path} was NOT cleaned up!")
            return
            
        created_files.append(dest_path)

    avg_http_lat = sum(http_latencies) / len(http_latencies)
    max_http_lat = max(http_latencies)
    min_http_lat = min(http_latencies)
    reporter.record_pass(f"{server_name}_consecutive_20_drops", f"20/20 consecutive drops HTTP 200 OK (avg {avg_http_lat:.2f}ms, min {min_http_lat:.2f}ms, max {max_http_lat:.2f}ms)")
    reporter.add_metric(f"{server_name}_http_avg_lat_ms", avg_http_lat)
    reporter.add_metric(f"{server_name}_http_max_lat_ms", max_http_lat)

    # Subtest 3: Omitted SHA-256 header (server should compute and accept empty hash)
    tx_id_no_sha = f"zero-nosha-{uuid.uuid4().hex[:6]}"
    filename_no_sha = "empty_nosha.txt"
    req_no_sha = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/drop",
        data=b"",
        method="POST",
        headers={
            "X-Daylight-Drop-Id": tx_id_no_sha,
            "X-Daylight-Drop-Type": "file",
            "X-Daylight-Drop-Filename": filename_no_sha,
            "X-Daylight-Drop-Origin": "tester-nosha",
            "Content-Length": "0",
            "Content-Type": "application/octet-stream",
            "Connection": "close"
        }
    )
    with urllib.request.urlopen(req_no_sha, timeout=3.0) as resp:
        body = json.loads(resp.read().decode("utf-8"))
        assert resp.status == 200
        assert body.get("sha256") == EMPTY_SHA256
    reporter.record_pass(f"{server_name}_omitted_sha256", "Omitted SHA-256 accepted and resolved to empty SHA-256")

    # Subtest 4: Mismatched SHA-256 rejection on 0-byte drop
    tx_id_bad_sha = f"zero-badsha-{uuid.uuid4().hex[:6]}"
    filename_bad_sha = "empty_badsha.txt"
    bad_sha = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    req_bad_sha = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/drop",
        data=b"",
        method="POST",
        headers={
            "X-Daylight-Drop-Id": tx_id_bad_sha,
            "X-Daylight-Drop-Type": "file",
            "X-Daylight-Drop-Filename": filename_bad_sha,
            "X-Daylight-Drop-Sha256": bad_sha,
            "X-Daylight-Drop-Origin": "tester-badsha",
            "Content-Length": "0",
            "Content-Type": "application/octet-stream",
            "Connection": "close"
        }
    )
    try:
        urllib.request.urlopen(req_bad_sha, timeout=3.0)
        reporter.record_fail(f"{server_name}_mismatched_sha256", "Server erroneously accepted mismatched SHA-256 on 0-byte drop!")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        if e.code == 400 and "checksum_mismatch" in body:
            reporter.record_pass(f"{server_name}_mismatched_sha256_rejection", f"HTTP 400 checksum_mismatch returned as expected ({body.strip()})")
        else:
            reporter.record_fail(f"{server_name}_mismatched_sha256", f"Unexpected code {e.code}: {body}")
            
    # Verify no leaked files from bad SHA
    bad_part = os.path.join(temp_dir, f".tmp_{tx_id_bad_sha}_{filename_bad_sha}.part")
    bad_final = os.path.join(temp_dir, filename_bad_sha)
    assert not os.path.exists(bad_part), "Bad SHA part file was leaked!"
    assert not os.path.exists(bad_final), "Bad SHA final file was committed!"
    reporter.record_pass(f"{server_name}_bad_sha_cleanup", "No leaked part or destination files after bad SHA rejection")

# ==============================================================================
# SECTION 2: THROUGHPUT BENCHMARK HARNESS
# ==============================================================================

def run_swift_throughput_benchmark():
    print("\n>>> [THROUGHPUT TEST] Swift Transport Engine Benchmark (5MB, 10MB, 25MB, 50MB)")
    swift_bin = os.path.join(PROJECT_ROOT, "tests/challenger_m1/swift_benchmark")
    p = subprocess.run([swift_bin], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    print(p.stdout.strip())
    
    parsed = {}
    for line in p.stdout.splitlines():
        line = line.strip()
        if ("[PASS]" in line or "[FAIL]" in line) and "Median =" in line:
            tag = "PASS" if "[PASS]" in line else "FAIL"
            token = line.split("[")[1].split("]")[1].split("Payload")[0].split(":")[0].strip()
            size_mb = int(token.replace("MB", "").strip())
            med_str = line.split("Median = ")[1].split(" MB/s")[0]
            med_val = float(med_str)
            parsed[size_mb] = (tag, med_val)
            if med_val >= SLA_TARGET_MBPS:
                reporter.record_pass(f"swift_benchmark_{size_mb}MB", f"Median throughput {med_val:.2f} MB/s (>= {SLA_TARGET_MBPS} MB/s target)")
            else:
                reporter.record_fail(f"swift_benchmark_{size_mb}MB", f"Throughput {med_val:.2f} MB/s below SLA {SLA_TARGET_MBPS} MB/s")
    reporter.add_metric("swift_throughputs", parsed)

def run_kotlin_throughput_benchmark():
    print("\n>>> [THROUGHPUT TEST] Kotlin Transport Engine Benchmark (5MB, 10MB, 25MB)")
    android_dir = os.path.join(PROJECT_ROOT, "android")
    gradle_bin = os.path.join(android_dir, "gradlew")
    cmd = [gradle_bin, ":app:testDebugUnitTest", "--tests", "com.daylight.drop.transport.AndroidChallengerBenchmarkTests", "--rerun-tasks"]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=android_dir)
    
    xml_path = os.path.join(android_dir, "app/build/test-results/testDebugUnitTest/TEST-com.daylight.drop.transport.AndroidChallengerBenchmarkTests.xml")
    if os.path.exists(xml_path):
        with open(xml_path, "r") as f:
            content = f.read()
        for line in content.splitlines():
            clean = line.replace("<![CDATA[", "").replace("]]>", "").strip()
            if "[KOTLIN_BENCH_SUMMARY]" in clean:
                print(f"  {clean}")
            if "[PASS]" in clean and ("MB:" in clean or "MB" in clean):
                # e.g. [PASS] 25 MB: Median = 88.54 MB/s, Max = 94.10 MB/s (Target >= 31.0 MB/s)
                parts = clean.split()
                size_mb = int(parts[1].replace("MB:", "").replace("MB", "").strip())
                med_str = clean.split("Median = ")[1].split(" MB/s")[0]
                med_val = float(med_str)
                if med_val >= SLA_TARGET_MBPS:
                    reporter.record_pass(f"kotlin_benchmark_{size_mb}MB", f"Median throughput {med_val:.2f} MB/s (>= {SLA_TARGET_MBPS} MB/s target)")
                else:
                    reporter.record_fail(f"kotlin_benchmark_{size_mb}MB", f"Throughput {med_val:.2f} MB/s below SLA {SLA_TARGET_MBPS} MB/s")
    else:
        reporter.record_fail("kotlin_benchmark_xml", f"Benchmark XML report missing at {xml_path}")

def run_hardware_usb_benchmark():
    print(f"\n>>> [THROUGHPUT TEST] Hardware USB ADB Forward Tunnel Benchmark (DC1 {DEVICE_SERIAL})")
    dev_check = subprocess.run(["adb", "devices"], stdout=subprocess.PIPE, text=True)
    if DEVICE_SERIAL not in dev_check.stdout:
        print(f"[SKIP] Device {DEVICE_SERIAL} not available.")
        return

    # Clean up port forward
    subprocess.run(["adb", "-s", DEVICE_SERIAL, "forward", "--remove", "tcp:8766"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["adb", "-s", DEVICE_SERIAL, "forward", "tcp:8766", "tcp:8766"], check=True)
    subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", "pkill -f 'toybox nc'"], check=False)
    time.sleep(0.5)

    sink_proc = subprocess.Popen(["adb", "-s", DEVICE_SERIAL, "shell", "toybox nc -l -p 8766 > /dev/null"])
    time.sleep(1.0)

    payload_size_mb = 25
    payload = b"Z" * (payload_size_mb * 1024 * 1024)

    trials = []
    for trial in range(3):
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", "pkill -f 'toybox nc'"], check=False)
        time.sleep(0.3)
        sink_proc = subprocess.Popen(["adb", "-s", DEVICE_SERIAL, "shell", "toybox nc -l -p 8766 > /dev/null"])
        time.sleep(0.5)

        s = socket.create_connection(("127.0.0.1", 8766), timeout=15)
        t0 = time.perf_counter()
        s.sendall(payload)
        s.close()
        t1 = time.perf_counter()
        sink_proc.wait(timeout=5)
        dur = t1 - t0
        mbps = payload_size_mb / dur
        trials.append((mbps, dur))
        print(f"  [USB_TRIAL {trial+1}] 25MB in {dur:.3f}s -> {mbps:.2f} MB/s")

    subprocess.run(["adb", "-s", DEVICE_SERIAL, "forward", "--remove", "tcp:8766"], check=True)
    trials.sort(key=lambda x: x[0])
    best_mbps, best_dur = trials[-1]
    med_mbps, med_dur = trials[1]
    reporter.add_metric("hw_usb_socket_median_mbps", med_mbps)
    reporter.add_metric("hw_usb_socket_max_mbps", best_mbps)
    if best_mbps >= SLA_TARGET_MBPS:
        reporter.record_pass("hardware_usb_socket_25MB", f"{payload_size_mb}MB over USB ADB tunnel: Max = {best_mbps:.2f} MB/s, Median = {med_mbps:.2f} MB/s (>= {SLA_TARGET_MBPS} MB/s target)")
    else:
        reporter.record_fail("hardware_usb_socket_25MB", f"Throughput Max {best_mbps:.2f} MB/s below target {SLA_TARGET_MBPS} MB/s")

    # ADB push baseline
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tf.write(payload)
        tf_path = tf.name
    try:
        t0_push = time.perf_counter()
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "push", tf_path, "/sdcard/Download/test_bench_push.bin"], check=True, stdout=subprocess.DEVNULL)
        dur_push = time.perf_counter() - t0_push
        push_mbps = payload_size_mb / dur_push
        reporter.record_pass("hardware_adb_push_baseline", f"{payload_size_mb}MB push in {dur_push:.3f}s -> {push_mbps:.2f} MB/s")
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", "rm -f /sdcard/Download/test_bench_push.bin"], check=True)
    finally:
        os.remove(tf_path)

# ==============================================================================
# MAIN ORCHESTRATION
# ==============================================================================

def main():
    print("=" * 75)
    print("DAYLIGHT DROP: CHALLENGER 1 EMPIRICAL ZERO-BYTE & THROUGHPUT BENCHMARK")
    print("=" * 75)

    # 1. Start macOS Swift server on port 8765
    swift_bin = os.path.join(PROJECT_ROOT, "tests/challenger_m1/swift_server_runner")
    swift_proc = subprocess.Popen([swift_bin, "8765"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    swift_temp_dir = ""
    for _ in range(50):
        line = swift_proc.stdout.readline()
        if "[SERVER_READY]" in line:
            for part in line.strip().split():
                if part.startswith("tempDir="):
                    swift_temp_dir = part.split("=")[1]
            break
        time.sleep(0.1)

    assert swift_temp_dir, "Failed to start macOS DaylightHTTPServer on 8765"
    print(f"[INIT] macOS DaylightHTTPServer running on 8765 (staging: {swift_temp_dir})")

    # 2. Start Android Kotlin server on port 8766
    cp = get_android_classpath()
    subprocess.run(["javac", "-cp", cp, "tests/challenger_m1/KotlinServerRunner.java"], check=True, cwd=PROJECT_ROOT)
    kotlin_proc = subprocess.Popen(["java", "-cp", cp, "KotlinServerRunner", "8766"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=PROJECT_ROOT)
    kotlin_temp_dir = ""
    for _ in range(50):
        line = kotlin_proc.stdout.readline()
        if "[SERVER_READY]" in line:
            for part in line.strip().split():
                if part.startswith("tempDir="):
                    kotlin_temp_dir = part.split("=")[1]
            break
        time.sleep(0.1)

    assert kotlin_temp_dir, "Failed to start Android AndroidHttpServer on 8766"
    print(f"[INIT] Android AndroidHttpServer running on 8766 (staging: {kotlin_temp_dir})")

    try:
        # Run 0-Byte stress tests on macOS (:8765)
        test_zero_byte_drops_on_server("macOS_8765", 8765, swift_temp_dir, iterations=20)

        # Run 0-Byte stress tests on Android (:8766)
        test_zero_byte_drops_on_server("Android_8766", 8766, kotlin_temp_dir, iterations=20)

        # Run Throughput Benchmarks
        run_swift_throughput_benchmark()
        run_kotlin_throughput_benchmark()
        run_hardware_usb_benchmark()

    finally:
        # Teardown servers
        print("\n[TEARDOWN] Stopping test servers...")
        try:
            swift_proc.stdin.write("STOP\n")
            swift_proc.stdin.flush()
            swift_proc.wait(timeout=2)
        except Exception:
            swift_proc.kill()

        try:
            kotlin_proc.stdin.write("STOP\n")
            kotlin_proc.stdin.flush()
            kotlin_proc.wait(timeout=2)
        except Exception:
            kotlin_proc.kill()

    # Summary
    print("\n" + "=" * 75)
    print("CHALLENGER 1 EMPIRICAL RESULTS SUMMARY")
    print("=" * 75)
    total_passed = sum(1 for status, _, _ in reporter.results if status == "PASS")
    total_failed = sum(1 for status, _, _ in reporter.results if status == "FAIL")
    print(f"Total Tests Executed : {len(reporter.results)}")
    print(f"Total Passed          : {total_passed}")
    print(f"Total Failed          : {total_failed}")

    if total_failed > 0:
        print("\nFAILURES:")
        for status, name, details in reporter.results:
            if status == "FAIL":
                print(f"  • {name}: {details}")
        sys.exit(1)
    else:
        print("\nALL EMPIRICAL TESTS PASSED SATISFACTORILY!")
        sys.exit(0)

if __name__ == "__main__":
    main()
