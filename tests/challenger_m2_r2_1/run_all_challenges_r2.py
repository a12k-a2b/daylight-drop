#!/usr/bin/env python3
"""
Daylight Drop - Milestone 2 Iteration 2 Challenger 1 Test Runner
Executes comprehensive empirical challenge suite for remediated macOS Native Menu Bar Tray UI:
1. Scratchpad TextEditor Cmd+V Focus & Native Paste Delivery
2. StatusItemDropTargetView Drag-Hover Spring-Open (Files & Text) Timing SLA
3. FloatingTrayPanel Drag-Out Retention & DragCoordinator Zero-Lag Synchronization
4. TIFF-to-PNG Genuine Transcoding & Non-File Web URL Fallback
"""

import subprocess
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
RUNNER_BIN = os.path.join(SCRIPT_DIR, "empirical_challenge_runner_r2")
SWIFT_SRC = os.path.join(SCRIPT_DIR, "run_empirical_challenges_r2.swift")

def build_runner_if_needed():
    if not os.path.exists(RUNNER_BIN) or os.path.getmtime(SWIFT_SRC) > os.path.getmtime(RUNNER_BIN):
        print(f"[*] Compiling {SWIFT_SRC}...")
        cmd = [
            "swiftc",
            "-parse-as-library",
            "-I", os.path.join(PROJECT_DIR, "macos/.build/arm64-apple-macosx/debug/Modules"),
            *subprocess.check_output(
                f"ls {os.path.join(PROJECT_DIR, 'macos/.build/arm64-apple-macosx/debug/DaylightDropApp.build/*.swift.o')} {os.path.join(PROJECT_DIR, 'macos/.build/arm64-apple-macosx/debug/DaylightDropTransport.build/*.swift.o')}",
                shell=True,
                text=True
            ).split(),
            "-o", RUNNER_BIN,
            SWIFT_SRC
        ]
        p = subprocess.run(cmd, cwd=PROJECT_DIR, text=True, capture_output=True)
        if p.returncode != 0:
            print(f"[!] Compilation failed:\n{p.stderr}")
            sys.exit(1)
        print("[*] Compilation successful.")

def main():
    print("======================================================================")
    print("   DAYLIGHT DROP - MILESTONE 2 ITERATION 2 EMPIRICAL CHALLENGE SUITE  ")
    print("======================================================================")
    build_runner_if_needed()
    
    t0 = time.perf_counter()
    p = subprocess.run([RUNNER_BIN], cwd=PROJECT_DIR, text=True)
    duration = time.perf_counter() - t0
    
    if p.returncode == 0:
        print(f"Empirical Challenger 1 Iteration 2 Suite completed successfully in {duration:.2f}s.")
        sys.exit(0)
    else:
        print(f"Empirical Challenger 1 Iteration 2 Suite exited with code {p.returncode}.")
        sys.exit(p.returncode)

if __name__ == "__main__":
    main()
