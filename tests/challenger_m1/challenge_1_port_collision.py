#!/usr/bin/env python3
"""
Empirical Challenge 1: Asymmetric Port Binding & Tunnel Collision Avoidance
Verifies that:
1. macOS binds 8765, DC1 binds 8766.
2. Simultaneous `adb forward tcp:8766 tcp:8766` + `adb reverse tcp:8765 tcp:8765`
   operate without port conflicts or traffic hijacking.
3. Symmetric forwarding (tcp:8765 tcp:8765) creates a severe port shadowing hazard
   where ADB hijacks traffic intended for macOS DaylightHTTPServer.
4. Bidirectional live traffic succeeds concurrently across the asymmetric tunnels.
"""

import subprocess
import time
import socket
import json
import sys
import os

DEVICE_SERIAL = "JMBR00380"
MAC_PORT = 8765
DC1_PORT = 8766
SWIFT_SERVER_BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), "swift_server_runner"))

def run_cmd(cmd, check=True):
    print(f"[CMD] {' '.join(cmd)}")
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed ({p.returncode}): {p.stderr.strip()}")
    return p

def main():
    print("=== EMPIRICAL CHALLENGE 1: ASYMMETRIC PORT BINDING & ADB TUNNEL COLLISION ===")
    
    # 0. Check device connectivity
    res = run_cmd(["adb", "devices"])
    if DEVICE_SERIAL not in res.stdout:
        print(f"[ERROR] Target device {DEVICE_SERIAL} not found in adb devices!")
        sys.exit(1)
    print(f"[PASS] Hardware tablet {DEVICE_SERIAL} confirmed connected via USB.")

    # 1. Clean up any existing tunnels
    run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", "--remove", f"tcp:{DC1_PORT}"], check=False)
    run_cmd(["adb", "-s", DEVICE_SERIAL, "reverse", "--remove", f"tcp:{MAC_PORT}"], check=False)
    run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", "--remove", f"tcp:{MAC_PORT}"], check=False)
    run_cmd(["adb", "-s", DEVICE_SERIAL, "reverse", "--remove", f"tcp:{DC1_PORT}"], check=False)

    # 2. Launch DaylightHTTPServer on macOS port 8765
    print("\n--- Step 1: Starting DaylightHTTPServer on macOS 0.0.0.0:8765 ---")
    server_proc = subprocess.Popen(
        [SWIFT_SERVER_BIN, str(MAC_PORT)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    
    server_ready = False
    start_time = time.time()
    while time.time() - start_time < 5.0:
        line = server_proc.stdout.readline()
        if "[SERVER_READY]" in line:
            server_ready = True
            print(f"[SERVER_LOG] {line.strip()}")
            break
        elif line:
            print(f"[SERVER_LOG] {line.strip()}")
    
    if not server_ready:
        print("[FAIL] DaylightHTTPServer failed to start on port 8765")
        server_proc.kill()
        sys.exit(1)
    print("[PASS] DaylightHTTPServer listening on port 8765 on macOS.")

    try:
        # 3. Test direct local connection to DaylightHTTPServer on 8765
        sock = socket.create_connection(("127.0.0.1", MAC_PORT), timeout=2)
        sock.sendall(b"GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        resp = sock.recv(4096).decode("utf-8")
        sock.close()
        assert "200 OK" in resp and '"device_type":"macos"' in resp, f"Unexpected response: {resp}"
        print("[PASS] Direct macOS health endpoint verified (HTTP 200 OK, device_type: macos).")

        # 4. Establish simultaneous asymmetric ADB tunnels
        print("\n--- Step 2: Provisioning Simultaneous Asymmetric ADB Tunnels ---")
        # adb forward: host listens on 8766, forwards to DC1 8766
        fwd_res = run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", f"tcp:{DC1_PORT}", f"tcp:{DC1_PORT}"])
        print(f"[OUTPUT] adb forward: {fwd_res.stdout.strip()}")
        
        # adb reverse: DC1 listens on 8765, forwards to host 8765
        rev_res = run_cmd(["adb", "-s", DEVICE_SERIAL, "reverse", f"tcp:{MAC_PORT}", f"tcp:{MAC_PORT}"])
        print(f"[OUTPUT] adb reverse: {rev_res.stdout.strip()}")

        # Check forward list
        fwd_list = run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", "--list"]).stdout
        print(f"[TUNNEL_LIST] forward:\n{fwd_list.strip()}")
        assert f"tcp:{DC1_PORT} tcp:{DC1_PORT}" in fwd_list, "Forward tunnel missing from list"

        # Check reverse list
        rev_list = run_cmd(["adb", "-s", DEVICE_SERIAL, "reverse", "--list"]).stdout
        print(f"[TUNNEL_LIST] reverse:\n{rev_list.strip()}")
        assert f"tcp:{MAC_PORT} tcp:{MAC_PORT}" in rev_list, "Reverse tunnel missing from list"
        print("[PASS] Simultaneous asymmetric tunnels established without collision or failure!")

        # 5. Verify local port 8765 remains accessible to local clients while forward 8766 is active
        sock = socket.create_connection(("127.0.0.1", MAC_PORT), timeout=2)
        sock.sendall(b"GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        resp = sock.recv(4096).decode("utf-8")
        sock.close()
        assert "200 OK" in resp and '"device_type":"macos"' in resp
        print("[PASS] macOS DaylightHTTPServer on 8765 unaffected by adb forward on 8766.")

        # 6. Empirical Negative Demonstration: Why symmetric ports (forward 8765:8765) break the system
        print("\n--- Step 3: Empirical Demonstration of Symmetric Port Shadowing Hazard ---")
        run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", f"tcp:{MAC_PORT}", f"tcp:{MAC_PORT}"])
        time.sleep(0.5)
        hijacked = False
        try:
            shadow_sock = socket.create_connection(("127.0.0.1", MAC_PORT), timeout=2)
            shadow_sock.sendall(b"GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            shadow_resp = shadow_sock.recv(4096).decode("utf-8")
            shadow_sock.close()
            if not shadow_resp or "200 OK" not in shadow_resp:
                hijacked = True
        except Exception:
            hijacked = True
        
        # Restore state by removing symmetric forward
        run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", "--remove", f"tcp:{MAC_PORT}"])
        assert hijacked, "Symmetric forward should have shadowed and broken local 8765 traffic!"
        print("[PASS] Confirmed: Symmetric forward on 8765 creates socket shadowing/traffic blackholing.")
        print("       Asymmetric architecture (8765 vs 8766) strictly prevents this failure mode.")

        # 7. Live Traffic DC1 -> macOS through Reverse Tunnel (8765)
        print("\n--- Step 4: Live Traffic Test — DC1 -> macOS via Reverse Tunnel (8765) ---")
        nc_cmd = f"(printf 'GET /api/health HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n' ; sleep 1) | toybox nc 127.0.0.1 {MAC_PORT}"
        dc1_to_mac = run_cmd(["adb", "-s", DEVICE_SERIAL, "shell", nc_cmd])
        print(f"[DC1_TO_MAC_OUTPUT]\n{dc1_to_mac.stdout.strip()}")
        assert "200 OK" in dc1_to_mac.stdout and '"device_type":"macos"' in dc1_to_mac.stdout, \
            "DC1 failed to reach macOS DaylightHTTPServer via reverse tunnel!"
        print("[PASS] DC1 successfully reached macOS DaylightHTTPServer over USB reverse tunnel on 8765!")

        # 8. Live Traffic macOS -> DC1 through Forward Tunnel (8766)
        print("\n--- Step 5: Live Traffic Test — macOS -> DC1 via Forward Tunnel (8766) ---")
        run_cmd(["adb", "-s", DEVICE_SERIAL, "shell", "pkill -f 'toybox nc'"], check=False)
        time.sleep(0.5)

        # Launch netcat responder on DC1 on port 8766
        dc1_cmd = f"toybox nc -l -p {DC1_PORT}"
        dc1_p = subprocess.Popen(["adb", "-s", DEVICE_SERIAL, "shell", dc1_cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        time.sleep(1.0)

        mac_sock = socket.create_connection(("127.0.0.1", DC1_PORT), timeout=3)
        mac_sock.sendall(b"PING_FROM_MAC_VIA_FORWARD_TUNNEL\n")
        dc1_p.stdin.write("PONG_FROM_DC1_OVER_FORWARD_TUNNEL\n")
        dc1_p.stdin.flush()
        mac_received = mac_sock.recv(1024).decode("utf-8")
        mac_sock.close()
        dc1_p.kill()

        print(f"[MAC_RECEIVED_FROM_DC1]\n{mac_received.strip()}")
        assert "PONG_FROM_DC1" in mac_received, "Failed to receive response from DC1 via forward tunnel"
        print("[PASS] macOS successfully exchanged live data with DC1 over USB forward tunnel on 8766!")

        print("\n=== CHALLENGE 1 VERDICT: COMPLETE PASS ===")
        print("Asymmetric port allocation (8765 macOS / 8766 DC1) completely eliminates ADB forward/reverse collision and enables simultaneous bidirectional traffic over USB.")

    finally:
        # Cleanup
        print("\n--- Teardown: Cleaning up ADB tunnels and stopping server ---")
        run_cmd(["adb", "-s", DEVICE_SERIAL, "forward", "--remove", f"tcp:{DC1_PORT}"], check=False)
        run_cmd(["adb", "-s", DEVICE_SERIAL, "reverse", "--remove", f"tcp:{MAC_PORT}"], check=False)
        run_cmd(["adb", "-s", DEVICE_SERIAL, "shell", "pkill -f 'toybox nc'"], check=False)
        
        try:
            server_proc.stdin.write("STOP\n")
            server_proc.stdin.flush()
            server_proc.wait(timeout=2.0)
        except Exception:
            server_proc.kill()
        print("[CLEANUP] Tunnels and server cleanly torn down.")

if __name__ == "__main__":
    main()
