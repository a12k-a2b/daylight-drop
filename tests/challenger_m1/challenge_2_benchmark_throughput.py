#!/usr/bin/env python3
"""
Empirical Challenge 2: Large Payload Throughput Benchmark
Evaluates transport throughput against the SLA requirement:
  usb_throughput_mb_s: >= 31.0 MB/s

Tests:
1. Swift transport engine (DaylightHTTPServer + DaylightHTTPClient) across 5MB, 10MB, 25MB, 50MB
2. Kotlin transport engine (AndroidHttpServer + AndroidHttpClient) across 5MB, 10MB, 25MB
3. Hardware ADB Forward Tunnel socket streaming (25MB over physical USB to DC1 JMBR00380)
4. Hardware ADB direct push baseline (25MB to DC1 JMBR00380)
"""

import subprocess
import time
import socket
import os
import sys

DEVICE_SERIAL = "JMBR00380"
SWIFT_BENCH_BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), "swift_benchmark"))
SLA_TARGET_MBPS = 31.0

def run_cmd(cmd, check=True, cwd=None):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=cwd)
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {p.stderr.strip()}")
    return p

def main():
    print("=== EMPIRICAL CHALLENGE 2: THROUGHPUT BENCHMARK (>= 31 MB/s TARGET) ===")
    
    # Check device
    devs = run_cmd(["adb", "devices"]).stdout
    if DEVICE_SERIAL not in devs:
        print(f"[WARN] Device {DEVICE_SERIAL} not connected. Skipping hardware link benchmark.")
        has_hw = False
    else:
        has_hw = True
        print(f"[INFO] Hardware device {DEVICE_SERIAL} available.")

    summary_records = []

    # 1. Swift Transport Engine
    print("\n--- Part 1: Swift Transport Engine (DaylightHTTPServer + DaylightHTTPClient) ---")
    p_swift = run_cmd([SWIFT_BENCH_BIN])
    print(p_swift.stdout.strip())
    # Parse swift outputs
    for line in p_swift.stdout.splitlines():
        if "[PASS]" in line or "[FAIL]" in line:
            summary_records.append(f"Swift {line.strip()}")

    # 2. Kotlin Android Transport Engine
    print("\n--- Part 2: Kotlin Transport Engine (AndroidHttpServer + AndroidHttpClient) ---")
    gradle_bin = "/Users/anjan/.gradle/wrapper/dists/gradle-8.14.3-all/10utluxaxniiv4wxiphsi49nj/gradle-8.14.3/bin/gradle"
    android_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../android"))
    p_gradle = run_cmd([gradle_bin, ":app:testDebugUnitTest", "--tests", "com.daylight.drop.transport.AndroidChallengerBenchmarkTests"], check=False, cwd=android_dir)
    
    # Read test report XML
    xml_path = os.path.join(android_dir, "app/build/test-results/testDebugUnitTest/TEST-com.daylight.drop.transport.AndroidChallengerBenchmarkTests.xml")
    if os.path.exists(xml_path):
        with open(xml_path, "r") as f:
            xml_content = f.read()
            for line in xml_content.splitlines():
                if "[KOTLIN_BENCH_SUMMARY]" in line or "[PASS]" in line or "[FAIL]" in line:
                    clean_line = line.replace("<![CDATA[", "").replace("]]>", "").strip()
                    if clean_line:
                        print(f"  {clean_line}")
                        summary_records.append(f"Kotlin: {clean_line}")
    else:
        print(f"[ERROR] XML report not found at {xml_path}")

    # 3. Hardware ADB Forward Tunnel Socket Streaming (25MB)
    if has_hw:
        print("\n--- Part 3: Physical Hardware ADB Forward Socket Tunnel (25MB to DC1) ---")
        run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", "tcp:8766", "tcp:8766"])
        run_cmd(["adb", "-s", DEVICE_SERIAL, "shell", "pkill -f 'toybox nc'"], check=False)
        time.sleep(0.5)

        sink_proc = subprocess.Popen(["adb", "-s", DEVICE_SERIAL, "shell", "toybox nc -l -p 8766 > /dev/null"])
        time.sleep(1.0)

        payload_size_mb = 25
        payload = b"Z" * (payload_size_mb * 1024 * 1024)
        
        sock = socket.create_connection(("127.0.0.1", 8766), timeout=15)
        t0 = time.perf_counter()
        sock.sendall(payload)
        sock.close()
        t1 = time.perf_counter()
        sink_proc.wait(timeout=3)
        run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", "--remove", "tcp:8766"])

        duration = t1 - t0
        hw_socket_mbps = payload_size_mb / duration
        hw_pass = hw_socket_mbps >= SLA_TARGET_MBPS
        hw_tag = "PASS" if hw_pass else "FAIL"
        print(f"[{hw_tag}] 25MB over USB ADB Forward Socket: {hw_socket_mbps:.2f} MB/s in {duration:.3f}s (Target >= {SLA_TARGET_MBPS} MB/s)")
        summary_records.append(f"Hardware USB Socket (25MB): {hw_socket_mbps:.2f} MB/s [{hw_tag}]")

        # 4. Hardware ADB Push Baseline
        print("\n--- Part 4: Hardware ADB Push Protocol Baseline (25MB to DC1) ---")
        import tempfile
        temp_file = os.path.join(tempfile.gettempdir(), "adb_push_bench.bin")
        with open(temp_file, "wb") as f:
            f.write(payload)
        
        t0_push = time.perf_counter()
        push_res = run_cmd(["adb", "-s", DEVICE_SERIAL, "push", temp_file, "/sdcard/Download/adb_push_bench.bin"])
        t1_push = time.perf_counter()
        os.remove(temp_file)
        run_cmd(["adb", "-s", DEVICE_SERIAL, "shell", "rm -f /sdcard/Download/adb_push_bench.bin"])

        push_dur = t1_push - t0_push
        push_mbps = payload_size_mb / push_dur
        print(f"[INFO] Raw ADB push output: {push_res.stdout.strip()} {push_res.stderr.strip()}")
        print(f"[INFO] 25MB Raw ADB Push Throughput: {push_mbps:.2f} MB/s in {push_dur:.3f}s")
        summary_records.append(f"Hardware ADB Push Baseline: {push_mbps:.2f} MB/s")

    print("\n=================================================================")
    print("=== CHALLENGE 2 SUMMARY TABLE & VERDICT ===")
    print(f"Target SLA: >= {SLA_TARGET_MBPS} MB/s")
    for r in summary_records:
        print(f"  • {r}")
    print("=================================================================")

if __name__ == "__main__":
    main()
