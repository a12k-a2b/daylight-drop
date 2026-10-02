#!/usr/bin/env python3
"""
Master Empirical Challenge Runner: Milestone 1 Transport Engine & Protocol
Executes all empirical challenge suites:
1. Port collision avoidance & simultaneous ADB tunnels
2. Large payload throughput benchmark (>= 31 MB/s SLA)
3. Corrupt payload & integrity rejection
"""

import subprocess
import os
import sys
import time

CHALLENGE_DIR = os.path.dirname(os.path.abspath(__file__))

def run_suite(name, script_path):
    print(f"\n{'='*70}")
    print(f"RUNNING: {name}")
    print(f"{'='*70}")
    t0 = time.perf_counter()
    p = subprocess.run([sys.executable, script_path], text=True)
    duration = time.perf_counter() - t0
    status = "PASS" if p.returncode == 0 else "FAIL"
    print(f"\n[SUITE RESULT] {name}: {status} (completed in {duration:.2f}s)")
    return status, duration

def main():
    print("======================================================================")
    print("   DAYLIGHT DROP - MILESTONE 1 EMPIRICAL CHALLENGE SUITE (M1 QA)")
    print("======================================================================")
    start_all = time.perf_counter()
    
    suites = [
        ("Challenge 1: Port Collision & Simultaneous Tunnels", os.path.join(CHALLENGE_DIR, "challenge_1_port_collision.py")),
        ("Challenge 2: Large Payload Throughput Benchmark", os.path.join(CHALLENGE_DIR, "challenge_2_benchmark_throughput.py")),
        ("Challenge 3: Corrupt Payload & Integrity Rejection", os.path.join(CHALLENGE_DIR, "challenge_3_corrupt_payload_rejection.py")),
    ]
    
    results = []
    for name, path in suites:
        status, dur = run_suite(name, path)
        results.append((name, status, dur))
        
    total_duration = time.perf_counter() - start_all
    
    print("\n" + "="*70)
    print("                     FINAL CHALLENGE SUMMARY")
    print("="*70)
    all_passed = True
    for name, status, dur in results:
        print(f"  • {name:<52} : [{status}] ({dur:.2f}s)")
        if status != "PASS":
            all_passed = False
            
    print(f"\nTotal Suite Execution Time: {total_duration:.2f}s")
    if all_passed:
        print("OVERALL VERDICT: PASS (All empirical challenges verified)")
        sys.exit(0)
    else:
        print("OVERALL VERDICT: FAIL")
        sys.exit(1)

if __name__ == "__main__":
    main()
