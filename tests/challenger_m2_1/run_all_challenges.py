#!/usr/bin/env python3
"""
Daylight Drop - Milestone 2 Challenger 1 Test Runner
Executes empirical challenge suites for macOS Native Menu Bar Tray UI & Interactions:
1. Drag-out retention test (DragCoordinator & FloatingTrayPanel)
2. Drag-Hover Spring Open test (F24) (StatusItemDropTargetView & Timing)
3. In-Tray Cmd+V paste test (F25) (FloatingTrayView & Pasteboard Parsing)
"""

import subprocess
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
RUNNER_BIN = os.path.join(SCRIPT_DIR, "empirical_challenge_runner")

def build_runner_if_needed():
    swift_src = os.path.join(SCRIPT_DIR, "run_empirical_challenges.swift")
    if not os.path.exists(RUNNER_BIN) or os.path.getmtime(swift_src) > os.path.getmtime(RUNNER_BIN):
        print(f"[*] Compiling {swift_src}...")
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
            swift_src
        ]
        p = subprocess.run(cmd, cwd=PROJECT_DIR, text=True, capture_output=True)
        if p.returncode != 0:
            print(f"[!] Compilation failed: {p.stderr}")
            sys.exit(1)
        print("[*] Compilation successful.")

def main():
    print("======================================================================")
    print("   DAYLIGHT DROP - MILESTONE 2 EMPIRICAL CHALLENGE SUITE (CHALLENGER 1)")
    print("======================================================================")
    build_runner_if_needed()
    
    t0 = time.perf_counter()
    p = subprocess.run([RUNNER_BIN], cwd=PROJECT_DIR, text=True)
    duration = time.perf_counter() - t0
    
    if p.returncode == 0:
        print(f"Empirical Challenger 1 Suite completed successfully in {duration:.2f}s.")
        sys.exit(0)
    else:
        print(f"Empirical Challenger 1 Suite exited with code {p.returncode}.")
        sys.exit(p.returncode)

if __name__ == "__main__":
    main()
