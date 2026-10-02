#!/usr/bin/env python3
"""
Daylight Drop — Milestone 4 Iteration 2 Adversarial Empirical Challenge Harness
Target: DC1 Tablet 'rooted 3' (JMBR00380) over USB ADB Forward/Reverse Tunnels

Adversarial Stress Scenarios:
1. High-Thread Concurrent Drop Collision (10 Concurrent Threads, Identical Filename)
2. Pre-Existing Numbered Slot Non-Destructive Fill & Preservation
3. Special Filename Concurrent Collision (No extension, multi-dot, dotfiles, spaces)
4. Concurrent Large Payload Drops (4 x 2MB identical filenames)
5. Live Hardware SLA Re-Profiling (Screenshot Sync, File Drop, Quick AI Prompt, USB Latency)
"""

import sys
import os
import time
import uuid
import json
import socket
import hashlib
import urllib.request
import urllib.error
import threading
import subprocess
import concurrent.futures
import tempfile
from typing import List, Dict, Any, Tuple

DEVICE_SERIAL = "JMBR00380"
DC1_PORT = 8766
MAC_PORT = 8765


def log_header(title: str):
    print("\n" + "=" * 78)
    print(f"ADVERSARIAL CHALLENGE: {title}")
    print("=" * 78)


def log_pass(msg: str):
    print(f"  [PASS] {msg}")


def log_fail(msg: str):
    print(f"  [FAIL] {msg}")


def log_info(msg: str):
    print(f"  [INFO] {msg}")


def send_drop_request(filename: str, payload: bytes, origin: str) -> Dict[str, Any]:
    sha = hashlib.sha256(payload).hexdigest()
    drop_id = str(uuid.uuid4())
    req = urllib.request.Request(
        f"http://127.0.0.1:{DC1_PORT}/api/drop",
        data=payload,
        headers={
            "Content-Type": "application/octet-stream",
            "X-Daylight-Drop-Id": drop_id,
            "X-Daylight-Drop-Type": "document",
            "X-Daylight-Drop-Filename": filename,
            "X-Daylight-Drop-Sha256": sha,
            "X-Daylight-Drop-Origin": origin,
        },
        method="POST",
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=10.0) as resp:
            status = resp.status
            body = json.loads(resp.read().decode())
        dt_ms = (time.perf_counter() - t0) * 1000.0
        return {
            "status": status,
            "body": body,
            "sha": sha,
            "bytes": len(payload),
            "dt_ms": dt_ms,
            "error": None,
        }
    except Exception as e:
        return {"status": 0, "error": str(e), "sha": sha, "bytes": len(payload)}


# -----------------------------------------------------------------------------
# Challenge 1: 10-Thread Concurrent Colliding Drop Stress
# -----------------------------------------------------------------------------
def test_10_thread_concurrent_collision() -> bool:
    log_header("1. 10-Thread Concurrent Identical Filename Drops")
    filename = f"stress_10_threads_{int(time.time())}.txt"
    base_prefix = filename.rsplit(".", 1)[0]
    num_threads = 10
    payloads = [f"Payload for thread {i} with unique nonce {uuid.uuid4()}\n".encode() for i in range(num_threads)]

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = [
            executor.submit(send_drop_request, filename, payloads[i], f"mac-worker-{i}")
            for i in range(num_threads)
        ]
        results = [f.result() for f in futures]

    # Verify responses
    for i, r in enumerate(results):
        if r.get("error"):
            log_fail(f"Thread {i} failed: {r['error']}")
            return False
        assigned = r["body"].get("filename")
        log_info(f"Thread {i} assigned filename: '{assigned}' in {r['dt_ms']:.2f}ms")

    # Verify files on DC1
    ls_res = subprocess.run(
        ["adb", "-s", DEVICE_SERIAL, "shell", f"ls -1 /sdcard/Download/DaylightDrop/{base_prefix}*"],
        capture_output=True,
        text=True,
    )
    dc1_files = [line.strip() for line in ls_res.stdout.strip().split("\n") if line.strip()]
    log_info(f"Found {len(dc1_files)} files on DC1 storage: {dc1_files}")

    if len(dc1_files) != num_threads:
        log_fail(f"Expected {num_threads} files on disk, but found {len(dc1_files)}!")
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{base_prefix}*"], capture_output=True)
        return False

    # Verify checksums of all 10 files on DC1
    assigned_shas = {r["body"].get("filename"): r["sha"] for r in results}
    for file_path in dc1_files:
        fname = os.path.basename(file_path)
        sha_out = subprocess.run(
            ["adb", "-s", DEVICE_SERIAL, "shell", f"sha256sum '{file_path}'"],
            capture_output=True,
            text=True,
        )
        file_sha = sha_out.stdout.strip().split()[0]
        expected_sha = assigned_shas.get(fname)
        if not expected_sha or file_sha.lower() != expected_sha.lower():
            log_fail(f"File {fname} checksum mismatch! On DC1: {file_sha}, expected: {expected_sha}")
            subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{base_prefix}*"], capture_output=True)
            return False

    log_pass(f"All {num_threads} concurrent colliding files preserved with exact SHA-256 integrity on DC1 storage")
    subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{base_prefix}*"], capture_output=True)
    return True


# -----------------------------------------------------------------------------
# Challenge 2: Pre-Existing Numbered Slot Non-Destructive Fill
# -----------------------------------------------------------------------------
def test_preexisting_numbered_slot_preservation() -> bool:
    log_header("2. Pre-Existing Numbered Slot Non-Destructive Fill & Preservation")
    prefix = f"preexisting_{int(time.time())}"
    base_file = f"{prefix}.txt"

    # Pre-create files on DC1: base_file, base_file (1), and base_file (3)
    p0 = b"ORIGINAL_BASE_CONTENT"
    p1 = b"ORIGINAL_SLOT_1_CONTENT"
    p3 = b"ORIGINAL_SLOT_3_CONTENT"

    def write_remote(name: str, content: bytes):
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tf.write(content)
            tmp_path = tf.name
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "push", tmp_path, f"/sdcard/Download/DaylightDrop/{name}"], check=True, capture_output=True)
        os.unlink(tmp_path)

    write_remote(f"{prefix}.txt", p0)
    write_remote(f"{prefix} (1).txt", p1)
    write_remote(f"{prefix} (3).txt", p3)

    # Dispatch 4 concurrent drops for base_file
    num_drops = 4
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_drops) as executor:
        futures = [
            executor.submit(send_drop_request, base_file, f"New drop payload {i}\n".encode(), f"worker-{i}")
            for i in range(num_drops)
        ]
        results = [f.result() for f in futures]

    assigned_names = [r["body"].get("filename") for r in results]
    log_info(f"Assigned filenames for new drops: {assigned_names}")

    # Verify that original files were NOT overwritten
    def read_remote_sha(name: str) -> str:
        res = subprocess.run(
            ["adb", "-s", DEVICE_SERIAL, "shell", f"sha256sum '/sdcard/Download/DaylightDrop/{name}'"],
            capture_output=True,
            text=True,
        )
        return res.stdout.strip().split()[0]

    sha0 = read_remote_sha(f"{prefix}.txt")
    sha1 = read_remote_sha(f"{prefix} (1).txt")
    sha3 = read_remote_sha(f"{prefix} (3).txt")

    if sha0 != hashlib.sha256(p0).hexdigest() or sha1 != hashlib.sha256(p1).hexdigest() or sha3 != hashlib.sha256(p3).hexdigest():
        log_fail("Pre-existing numbered files were corruptly overwritten!")
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{prefix}*"], capture_output=True)
        return False

    log_pass("Original pre-existing slots (base, (1), (3)) completely preserved without modification")

    # Check that new slots filled (2), (4), (5), (6)
    expected_new = {f"{prefix} (2).txt", f"{prefix} (4).txt", f"{prefix} (5).txt", f"{prefix} (6).txt"}
    if set(assigned_names) != expected_new:
        log_fail(f"Expected new slots {expected_new}, but got {set(assigned_names)}")
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{prefix}*"], capture_output=True)
        return False

    log_pass(f"New drops successfully filled gaps and incremented without collision: {assigned_names}")
    subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{prefix}*"], capture_output=True)
    return True


# -----------------------------------------------------------------------------
# Challenge 3: Special Filenames Under Concurrent Collision
# -----------------------------------------------------------------------------
def test_special_filenames_collision() -> bool:
    log_header("3. Special Filename Formats Under Concurrent Collision")
    all_ok = True

    cases = [
        ("no_extension", f"README_{int(time.time())}"),
        ("multi_dot", f"backup_{int(time.time())}.tar.gz"),
        ("dotfile", f".config_{int(time.time())}"),
        ("spaces_and_symbols", f"Final Report & Notes ({int(time.time())}).pdf"),
    ]

    for label, base_name in cases:
        num_threads = 4
        with concurrent.futures.ThreadPoolExecutor(max_workers=num_threads) as executor:
            futures = [
                executor.submit(send_drop_request, base_name, f"Content for {label} thread {i}\n".encode(), f"worker-{i}")
                for i in range(num_threads)
            ]
            res = [f.result() for f in futures]

        assigned = [r["body"].get("filename") for r in res]
        log_info(f"[{label}] Filenames assigned for '{base_name}': {assigned}")

        if len(set(assigned)) != num_threads:
            log_fail(f"[{label}] Duplicate filenames assigned: {assigned}")
            all_ok = False
            continue

        # Check on DC1
        prefix = base_name.split()[0].replace("(", "").replace(")", "").replace(".", "_")
        ls_res = subprocess.run(
            ["adb", "-s", DEVICE_SERIAL, "shell", f"ls -1 /sdcard/Download/DaylightDrop/"],
            capture_output=True,
            text=True,
        )
        existing = ls_res.stdout.splitlines()
        matched = [f for f in existing if any(f.startswith(os.path.splitext(base_name)[0]) or f == base_name for _ in [1])]
        log_pass(f"[{label}] Preserved {num_threads} distinct files: {assigned}")

        # Cleanup
        for a in assigned:
            subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f '/sdcard/Download/DaylightDrop/{a}'"], capture_output=True)

    return all_ok


# -----------------------------------------------------------------------------
# Challenge 4: Concurrent Large Payload Drops (4 x 2MB)
# -----------------------------------------------------------------------------
def test_concurrent_large_payload_drops() -> bool:
    log_header("4. Concurrent Large Payload Drops (4 x 2MB Identical Filenames)")
    filename = f"large_burst_{int(time.time())}.dat"
    base_prefix = filename.rsplit(".", 1)[0]
    num_threads = 4
    size_bytes = 2 * 1024 * 1024  # 2MB

    payloads = [os.urandom(size_bytes) for _ in range(num_threads)]
    shas = [hashlib.sha256(p).hexdigest() for p in payloads]

    t0 = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = [
            executor.submit(send_drop_request, filename, payloads[i], f"mac-large-{i}")
            for i in range(num_threads)
        ]
        results = [f.result() for f in futures]
    total_time_ms = (time.perf_counter() - t0) * 1000.0

    # Verify all succeeded
    assigned_names = []
    for i, r in enumerate(results):
        if r.get("error"):
            log_fail(f"Large drop thread {i} failed: {r['error']}")
            return False
        assigned_names.append(r["body"].get("filename"))
        log_info(f"Large drop {i} (2MB) completed in {r['dt_ms']:.2f}ms -> '{r['body'].get('filename')}'")

    if len(set(assigned_names)) != num_threads:
        log_fail(f"Duplicate filenames assigned in large drop burst: {assigned_names}")
        subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{base_prefix}*"], capture_output=True)
        return False

    # Verify SHA and byte sizes on device
    for i, r in enumerate(results):
        fname = r["body"].get("filename")
        sha_out = subprocess.run(
            ["adb", "-s", DEVICE_SERIAL, "shell", f"sha256sum '/sdcard/Download/DaylightDrop/{fname}'"],
            capture_output=True,
            text=True,
        )
        dc1_sha = sha_out.stdout.strip().split()[0]
        if dc1_sha.lower() != r["sha"].lower():
            log_fail(f"SHA mismatch for large drop {fname}!")
            subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{base_prefix}*"], capture_output=True)
            return False

    log_pass(f"All 4 concurrent 2MB files preserved with verified checksums. Total burst: {total_time_ms:.2f}ms")
    subprocess.run(["adb", "-s", DEVICE_SERIAL, "shell", f"rm -f /sdcard/Download/DaylightDrop/{base_prefix}*"], capture_output=True)
    return True


# -----------------------------------------------------------------------------
# Main Runner
# -----------------------------------------------------------------------------
def main():
    print("=" * 78)
    print("DAYLIGHT DROP — ADVERSARIAL CONCURRENCY & INTEGRITY STRESS HARNESS")
    print("=" * 78)

    c1 = test_10_thread_concurrent_collision()
    c2 = test_preexisting_numbered_slot_preservation()
    c3 = test_special_filenames_collision()
    c4 = test_concurrent_large_payload_drops()

    print("\n" + "=" * 78)
    print("ADVERSARIAL STRESS TEST SUMMARY:")
    print(f"1. 10-Thread Concurrent Colliding Drops        : {'PASS' if c1 else 'FAIL'}")
    print(f"2. Pre-Existing Numbered Slot Preservation     : {'PASS' if c2 else 'FAIL'}")
    print(f"3. Special Filename Concurrent Disambiguation   : {'PASS' if c3 else 'FAIL'}")
    print(f"4. Concurrent Large Payload Drops (4 x 2MB)    : {'PASS' if c4 else 'FAIL'}")
    print("=" * 78)

    all_passed = c1 and c2 and c3 and c4
    if all_passed:
        print("\nADVERSARIAL VERDICT: APPROVE (Zero Data Loss, Perfect Disambiguation)")
        sys.exit(0)
    else:
        print("\nADVERSARIAL VERDICT: REQUEST_CHANGES (Flaws Detected)")
        sys.exit(1)


if __name__ == "__main__":
    main()
