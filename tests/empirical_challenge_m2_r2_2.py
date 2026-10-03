#!/usr/bin/env python3
"""
Daylight Drop - Milestone 2 Iteration 2 Empirical Challenge Suite (Challenger 2)
Authoritative adversarial verification of remediated Carbon hotkeys, Scratchpad dispatch, and local staging:
1. Swift XCTest Suite (58/58 tests passing including EmpiricalChallengeM2Tests)
2. Native Empirical Stress Binary (tests/empirical_m2_r2_stress)
   - 100 rapid prompt dispatches in <1s (entropy & APFS isolation)
   - 25 concurrent tasks multithreaded staging
   - PNG and TIFF image pasteboard support in CarbonHotKeyManager
   - Dynamic loop suppression (daylight-dc1, peer IDs, local origin, untagged)
3. Python Empirical Challenge Runner (tests/empirical_challenge_m2_2.py)
4. Full E2E Test Suite (tests/e2e/runner.py --tier all)
"""

import sys
import os
import time
import subprocess

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

def run_command(desc: str, cmd: list, cwd: str = PROJECT_ROOT) -> int:
    print("\n" + "=" * 70)
    print(f"RUNNING: {desc}")
    print(f"COMMAND: {' '.join(cmd)}")
    print("=" * 70)
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, cwd=cwd, text=True)
    elapsed = time.perf_counter() - t0
    print(f"\nCompleted in {elapsed:.2f}s (Exit code: {proc.returncode})")
    if proc.returncode != 0:
        print(f"❌ FAILED: {desc}")
    else:
        print(f"✅ PASSED: {desc}")
    return proc.returncode

def main():
    print("=" * 70)
    print("DAYLIGHT DROP: MILESTONE 2 ITERATION 2 CHALLENGER 2 EMPIRICAL SUITE")
    print("=" * 70)
    
    failures = 0
    
    # 1. Swift Test Suite
    if run_command("Swift Package Tests (58 tests)", ["swift", "test", "--package-path", "macos"]) != 0:
        failures += 1
        
    # 2. Native Swift Stress Binary
    stress_bin = os.path.join(PROJECT_ROOT, "tests", "empirical_m2_r2_stress")
    if os.path.exists(stress_bin):
        if run_command("Native Stress Harness (empirical_m2_r2_stress)", [stress_bin]) != 0:
            failures += 1
    else:
        print("⚠️ Warning: empirical_m2_r2_stress binary not found, recompiling...")
        compile_cmd = [
            "swiftc", "-parse-as-library",
            "-I", "macos/.build/arm64-apple-macosx/debug/Modules",
            *subprocess.check_output(
                f"ls {os.path.join(PROJECT_ROOT, 'macos/.build/arm64-apple-macosx/debug/DaylightDropKit.build/*.swift.o')} {os.path.join(PROJECT_ROOT, 'macos/.build/arm64-apple-macosx/debug/DaylightDropTransport.build/*.swift.o')}",
                shell=True, text=True
            ).split(),
            "-o", stress_bin,
            os.path.join(PROJECT_ROOT, "tests", "empirical_m2_r2_stress.swift")
        ]
        if subprocess.run(compile_cmd, cwd=PROJECT_ROOT).returncode == 0:
            if run_command("Native Stress Harness (empirical_m2_r2_stress)", [stress_bin]) != 0:
                failures += 1
        else:
            failures += 1
            
    # 3. Challenger 2 Runner
    if run_command("Empirical Challenge Runner (empirical_challenge_m2_2.py)", ["python3", "tests/empirical_challenge_m2_2.py"]) != 0:
        failures += 1
        
    # 4. Full E2E Test Suite
    if run_command("E2E Test Runner (--tier all)", ["python3", "tests/e2e/runner.py", "--tier", "all"]) != 0:
        failures += 1

    print("\n" + "=" * 70)
    print("EMPIRICAL CHALLENGER 2 ITERATION 2 VERDICT")
    print("=" * 70)
    if failures == 0:
        print("🎉 ALL EMPIRICAL CHALLENGES PASSED (0 FAILURES). APPROVE MILESTONE 2.")
        return 0
    else:
        print(f"❌ {failures} CHALLENGE STEP(S) FAILED. REQUEST CHANGES.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
