"""
verify_e2e.py — run one MNIST image through the RTL sim and compare
against the hardware-accurate Python reference (hw_reference.py).

Usage (from repo root):
    python3 scripts/verify_e2e.py          # image index 0 (default)
    python3 scripts/verify_e2e.py --idx 7  # specific image
"""

import argparse
import os
import sys
import time
import numpy as np
from torchvision import datasets, transforms

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from model.gen_reference import load_artifacts, infer
from mock.behavioral_chip import BehavioralChip
from host.driver import AcceleratorDriver


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idx", type=int, default=0, help="MNIST test-set image index")
    args = ap.parse_args()

    arrs, scales = load_artifacts()
    ds = datasets.MNIST("data", train=False, download=True,
                        transform=transforms.ToTensor())
    img_tensor, true_label = ds[args.idx]
    img_float = img_tensor.numpy().squeeze()           # (28,28) float [0,1]
    img_bytes = (img_float * 255).round().astype(np.uint8).flatten().tobytes()

    # ------------------------------------------------------------------ #
    # Python reference (gen_reference — INT8 inference with conv biases)
    # ------------------------------------------------------------------ #
    print(f"\n[ref] computing Python INT8 reference for image {args.idx} ...")
    _, _, _, logits = infer(img_float, arrs, scales)
    ref_class = int(logits.argmax())
    print(f"[ref] predicted_class = {ref_class}  (true label = {true_label})")

    # ------------------------------------------------------------------ #
    # RTL simulation
    # ------------------------------------------------------------------ #
    print("\n[sim] launching behavioral model ...")
    chip   = BehavioralChip()
    driver = AcceleratorDriver(chip)

    print("[sim] loading weights ...")
    t0 = time.monotonic()
    driver.load_weights("weights.bin")
    print(f"[sim] weights loaded in {time.monotonic()-t0:.3f}s")

    print(f"[sim] running inference on image {args.idx} ...")
    t0 = time.monotonic()
    driver.run_inference(img_bytes)
    print(f"[sim] inference done in {time.monotonic()-t0:.3f}s")

    sim_class = driver.read_result()
    telem     = driver.read_telemetry()

    print(f"[sim] predicted_class = {sim_class}")
    print(f"[sim] telemetry       = {telem}")

    # ------------------------------------------------------------------ #
    # Compare
    # ------------------------------------------------------------------ #
    print("\n--- verification ---")
    match = sim_class == ref_class
    print(f"predicted class : ref={ref_class}  sim={sim_class}  "
          f"{'MATCH ✓' if match else 'MISMATCH ✗'}")
    print(f"true label      : {true_label}")
    print(f"inferences_total: {telem['inferences_total']} (expected 1)")

    sys.exit(0 if match else 1)


if __name__ == "__main__":
    main()
