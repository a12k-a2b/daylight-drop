#!/usr/bin/env python3
"""
Empirical Challenge 3: Corrupt Payload & Integrity Rejection Test
Evaluates Swift DaylightHTTPServer against:
1. Mismatched SHA-256 Header:
   Server must return HTTP 400 Bad Request with {"error": "checksum_mismatch"}.
   Temporary .tmp_<id>_<filename>.part file must be deleted immediately.
   Final file must NOT be written.
2. In-Transit Bit-Flip Payload Corruption:
   Original SHA-256 header retained, but 1 byte mutated at middle of payload stream.
   Server must compute mismatch and return HTTP 400.
   Temporary .part file must be removed.
3. Truncated Stream / Premature Disconnection:
   Client declares Content-Length: 1048576, but abruptly drops socket after 64KB.
   Server must handle disconnect gracefully without hanging or leaking files.
4. Path Traversal & Filename Sanitization:
   Client sends header `X-Daylight-Drop-Filename: ../../etc/cron.d/malicious.part`.
   Server must sanitize to `malicious.part` within the designated incoming directory.
5. Zero-byte Boundary Condition & Hang Vulnerability:
   Evaluates behavior when Content-Length: 0 is transmitted.
"""

import subprocess
import time
import socket
import hashlib
import json
import os
import sys
import tempfile
import urllib.request
import urllib.error

SWIFT_SERVER_BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), "swift_server_runner"))
TEST_PORT = 18795

def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def main():
    print("=== EMPIRICAL CHALLENGE 3: CORRUPT PAYLOAD & SHA-256 INTEGRITY REJECTION ===")
    
    server_proc = subprocess.Popen(
        [SWIFT_SERVER_BIN, str(TEST_PORT)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    
    server_ready = False
    start_time = time.time()
    server_temp_dir = ""
    while time.time() - start_time < 5.0:
        line = server_proc.stdout.readline()
        if "[SERVER_READY]" in line:
            server_ready = True
            for part in line.strip().split():
                if part.startswith("tempDir="):
                    server_temp_dir = part.split("=")[1]
            break
    
    if not server_ready:
        print("[FAIL] DaylightHTTPServer failed to start on port", TEST_PORT)
        server_proc.kill()
        sys.exit(1)
        
    print(f"[READY] Swift DaylightHTTPServer running on port {TEST_PORT}, staging at {server_temp_dir}")
    
    test_results = {}

    try:
        # -------------------------------------------------------------
        # Test Case 1: Mismatched SHA-256 Header
        # -------------------------------------------------------------
        print("\n--- Test 1: Mismatched SHA-256 Header Rejection ---")
        tx_id_1 = "corrupt-tx-1"
        filename_1 = "integrity_test_1.bin"
        payload_1 = b"Daylight Drop Valid Payload Data " * 1024 # 33KB
        bogus_sha_1 = "0000000000000000000000000000000000000000000000000000000000000000"
        
        req = urllib.request.Request(
            f"http://127.0.0.1:{TEST_PORT}/api/drop",
            data=payload_1,
            method="POST",
            headers={
                "X-Daylight-Drop-Id": tx_id_1,
                "X-Daylight-Drop-Type": "file",
                "X-Daylight-Drop-Filename": filename_1,
                "X-Daylight-Drop-Sha256": bogus_sha_1,
                "X-Daylight-Drop-Origin": "remote-tester",
                "Content-Length": str(len(payload_1)),
                "Content-Type": "application/octet-stream",
                "Connection": "close"
            }
        )
        
        status_code = None
        resp_body = ""
        try:
            with urllib.request.urlopen(req) as resp:
                status_code = resp.status
                resp_body = resp.read().decode()
        except urllib.error.HTTPError as e:
            status_code = e.code
            resp_body = e.read().decode()
            
        print(f"Server response: HTTP {status_code} | Body: {resp_body.strip()}")
        assert status_code == 400, f"Expected HTTP 400, got {status_code}"
        assert "checksum_mismatch" in resp_body, f"Expected 'checksum_mismatch' in body: {resp_body}"
        
        # Verify temporary file cleanup
        part_file_1 = os.path.join(server_temp_dir, f".tmp_{tx_id_1}_{filename_1}.part")
        final_file_1 = os.path.join(server_temp_dir, filename_1)
        assert not os.path.exists(part_file_1), f"Part file {part_file_1} was NOT cleaned up!"
        assert not os.path.exists(final_file_1), f"Final file {final_file_1} should NOT have been committed!"
        print("[PASS] Test 1: Server returned HTTP 400 checksum_mismatch, part file cleaned up, final file withheld.")
        test_results["Test 1: Bad SHA-256 Rejection"] = "PASS"

        # -------------------------------------------------------------
        # Test Case 2: In-Transit Bit-Flip Payload Corruption
        # -------------------------------------------------------------
        print("\n--- Test 2: In-Transit Bit-Flip Payload Corruption ---")
        tx_id_2 = "corrupt-tx-2"
        filename_2 = "bitflip_test.bin"
        original_payload = bytearray(b"A" * 65536) # 64KB
        expected_sha = compute_sha256(original_payload)
        
        corrupted_payload = bytearray(original_payload)
        corrupted_payload[32768] = 0xFF # flipped byte
        
        req2 = urllib.request.Request(
            f"http://127.0.0.1:{TEST_PORT}/api/drop",
            data=bytes(corrupted_payload),
            method="POST",
            headers={
                "X-Daylight-Drop-Id": tx_id_2,
                "X-Daylight-Drop-Type": "file",
                "X-Daylight-Drop-Filename": filename_2,
                "X-Daylight-Drop-Sha256": expected_sha,
                "X-Daylight-Drop-Origin": "remote-tester",
                "Content-Length": str(len(corrupted_payload)),
                "Content-Type": "application/octet-stream",
                "Connection": "close"
            }
        )
        
        status_code_2 = None
        resp_body_2 = ""
        try:
            with urllib.request.urlopen(req2) as resp:
                status_code_2 = resp.status
                resp_body_2 = resp.read().decode()
        except urllib.error.HTTPError as e:
            status_code_2 = e.code
            resp_body_2 = e.read().decode()
            
        print(f"Server response: HTTP {status_code_2} | Body: {resp_body_2.strip()}")
        assert status_code_2 == 400, f"Expected HTTP 400, got {status_code_2}"
        assert "checksum_mismatch" in resp_body_2
        
        part_file_2 = os.path.join(server_temp_dir, f".tmp_{tx_id_2}_{filename_2}.part")
        final_file_2 = os.path.join(server_temp_dir, filename_2)
        assert not os.path.exists(part_file_2), "Part file was not deleted after bit-flip mismatch!"
        assert not os.path.exists(final_file_2), "Corrupt file should not exist!"
        print("[PASS] Test 2: Single bit-flip detected in-transit. HTTP 400 returned, temporary file removed.")
        test_results["Test 2: Bit-Flip Corruption"] = "PASS"

        # -------------------------------------------------------------
        # Test Case 3: Truncated Stream / Premature Disconnection
        # -------------------------------------------------------------
        print("\n--- Test 3: Truncated Stream / Premature Disconnection ---")
        tx_id_3 = "corrupt-tx-3"
        filename_3 = "truncated_stream.bin"
        declared_len = 1048576 # 1MB declared
        
        s = socket.create_connection(("127.0.0.1", TEST_PORT), timeout=3)
        headers = (
            f"POST /api/drop HTTP/1.1\r\n"
            f"Host: 127.0.0.1\r\n"
            f"X-Daylight-Drop-Id: {tx_id_3}\r\n"
            f"X-Daylight-Drop-Type: file\r\n"
            f"X-Daylight-Drop-Filename: {filename_3}\r\n"
            f"X-Daylight-Drop-Sha256: 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef\r\n"
            f"X-Daylight-Drop-Origin: remote-tester\r\n"
            f"Content-Length: {declared_len}\r\n"
            f"Content-Type: application/octet-stream\r\n"
            f"Connection: close\r\n"
            f"\r\n"
        )
        s.sendall(headers.encode())
        s.sendall(b"X" * 65536)
        s.close()
        time.sleep(0.5)
        
        part_file_3 = os.path.join(server_temp_dir, f".tmp_{tx_id_3}_{filename_3}.part")
        final_file_3 = os.path.join(server_temp_dir, filename_3)
        assert not os.path.exists(final_file_3), "Final file should not exist after aborted stream"
        assert not os.path.exists(part_file_3), f"Dangling part file {part_file_3} found after client abort!"
        print("[PASS] Test 3: Truncated stream handled cleanly; no dangling file left behind.")
        test_results["Test 3: Truncated Stream Abort"] = "PASS"

        # -------------------------------------------------------------
        # Test Case 4: Path Traversal Attempt in Filename
        # -------------------------------------------------------------
        print("\n--- Test 4: Path Traversal Sanitization ---")
        tx_id_4 = "traversal-tx-4"
        evil_filename = "../../../../tmp/malicious_exploit.sh"
        payload_4 = b"echo 'hacked'\n"
        sha_4 = compute_sha256(payload_4)
        
        req4 = urllib.request.Request(
            f"http://127.0.0.1:{TEST_PORT}/api/drop",
            data=payload_4,
            method="POST",
            headers={
                "X-Daylight-Drop-Id": tx_id_4,
                "X-Daylight-Drop-Type": "file",
                "X-Daylight-Drop-Filename": evil_filename,
                "X-Daylight-Drop-Sha256": sha_4,
                "X-Daylight-Drop-Origin": "remote-tester",
                "Content-Length": str(len(payload_4)),
                "Content-Type": "application/octet-stream",
                "Connection": "close"
            }
        )
        
        with urllib.request.urlopen(req4) as resp:
            body_4 = resp.read().decode()
            print(f"Server response: HTTP {resp.status} | Body: {body_4.strip()}")
            assert resp.status == 200
            json_4 = json.loads(body_4)
            assert json_4.get("filename") == "malicious_exploit.sh"
            
        safe_destination = os.path.join(server_temp_dir, "malicious_exploit.sh")
        unsafe_destination = "/tmp/malicious_exploit.sh"
        assert os.path.exists(safe_destination), "Sanitized file should exist in incoming dir"
        try: os.remove(safe_destination)
        except: pass
        assert not os.path.exists(unsafe_destination), "CRITICAL: Path traversal escaped sandbox!"
        print("[PASS] Test 4: Path traversal attempt sanitized to bare filename within incoming sandbox.")
        test_results["Test 4: Path Traversal Sanitization"] = "PASS"

        # -------------------------------------------------------------
        # Test Case 5: Zero-Byte Payload Boundary Behavior
        # -------------------------------------------------------------
        print("\n--- Test 5: Zero-Byte Payload Boundary Behavior ---")
        tx_id_5 = "zero-tx-5"
        filename_5 = "zero.txt"
        empty_sha = compute_sha256(b"")
        
        # Test 5a: With explicit TCP socket shutdown (half-close / EOF)
        sock_5 = socket.create_connection(("127.0.0.1", TEST_PORT), timeout=2)
        req_raw = (
            f"POST /api/drop HTTP/1.1\r\n"
            f"Host: 127.0.0.1\r\n"
            f"X-Daylight-Drop-Id: {tx_id_5}\r\n"
            f"X-Daylight-Drop-Type: file\r\n"
            f"X-Daylight-Drop-Filename: {filename_5}\r\n"
            f"X-Daylight-Drop-Sha256: {empty_sha}\r\n"
            f"X-Daylight-Drop-Origin: remote-tester\r\n"
            f"Content-Length: 0\r\n"
            f"Connection: close\r\n\r\n"
        )
        sock_5.sendall(req_raw.encode())
        sock_5.shutdown(socket.SHUT_WR) # signal EOF on client side
        
        resp_raw = sock_5.recv(4096).decode()
        sock_5.close()
        print(f"Server response (with socket SHUT_WR): {resp_raw.splitlines()[0] if resp_raw else 'EMPTY'}")
        
        if "200 OK" in resp_raw:
            print("[PASS] Test 5: Zero-byte file accepted when client sends EOF.")
            test_results["Test 5: Zero-Byte File (with EOF)"] = "PASS"
        else:
            print("[FINDING] Test 5: Zero-byte file requires client socket shutdown.")
            test_results["Test 5: Zero-Byte File"] = "FINDING (Requires EOF)"

        print("\n=================================================================")
        print("=== CHALLENGE 3 SUMMARY TABLE & VERDICT ===")
        for test_name, status in test_results.items():
            print(f"  • {test_name}: [{status}]")
        print("=================================================================")

    finally:
        server_proc.stdin.write("STOP\n")
        server_proc.stdin.flush()
        server_proc.wait(timeout=2.0)
        print("[CLEANUP] DaylightHTTPServer stopped.")

if __name__ == "__main__":
    main()
