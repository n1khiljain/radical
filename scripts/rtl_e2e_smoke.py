"""
rtl_e2e_smoke.py — drive ONE MNIST inference through the REAL RTL via SimBridge
(named-FIFO + iverilog path, tb_chip.sv -> chip.sv) and compare the predicted
class against reference_outputs.json.

This is the buildability/integration gate: image in -> prediction out over the
actual SystemVerilog, not the Python BehavioralChip.

Run from repo root:  python3 scripts/rtl_e2e_smoke.py [--idx N]
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from host.sim_bridge import SimBridge
from host.driver import AcceleratorDriver


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idx", type=int, default=0)
    ap.add_argument("--n", type=int, default=1, help="how many images to run")
    args = ap.parse_args()

    ref = json.load(open("reference_outputs.json"))

    print("[e2e] launching SimBridge (compiles RTL if stale, then vvp) ...")
    t0 = time.monotonic()
    chip = SimBridge()
    print(f"[e2e] sim ready in {time.monotonic()-t0:.1f}s")

    driver = AcceleratorDriver(chip)

    print("[e2e] loading weights.bin into RTL ...")
    t0 = time.monotonic()
    driver.load_weights("weights.bin")
    print(f"[e2e] weights loaded in {time.monotonic()-t0:.2f}s")

    passes = 0
    total = 0
    for k in range(args.n):
        entry = ref[args.idx + k]
        img = bytes(entry["input_bytes"])
        exp = entry["expected_class"]

        t0 = time.monotonic()
        driver.run_inference(img)
        got = driver.read_result()
        dt = time.monotonic() - t0

        ok = (got == exp)
        passes += ok
        total += 1
        print(f"[e2e] idx={entry['idx']:3d}  rtl={got}  ref={exp}  "
              f"{'MATCH' if ok else 'MISMATCH'}  ({dt:.2f}s)")

    print(f"[e2e] telemetry = {driver.read_telemetry()}")
    print(f"[e2e] {passes}/{total} matched reference")

    chip.close()
    sys.exit(0 if passes == total else 1)


if __name__ == "__main__":
    main()
