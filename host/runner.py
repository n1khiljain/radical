"""
Validation runner: replays every entry in reference_outputs.json through
the INT8 inference pipeline (same computation the hardware chip will do)
and checks each intermediate tensor and final class against the reference.
"""

import json
import sys
import numpy as np

sys.path.insert(0, ".")                    # run from project root
from model.gen_reference import load_artifacts, infer


def run():
    arrs, scales = load_artifacts()

    with open("reference_outputs.json") as f:
        reference = json.load(f)

    passes = failures = 0

    for entry in reference:
        idx   = entry["idx"]
        # Reconstruct float image from stored uint8 pixels
        img_f = np.array(entry["input_bytes"], dtype=np.float32).reshape(28, 28) / 255.0

        pc1, pc2, pf1, logits = infer(img_f, arrs, scales)
        pred = int(logits.argmax())

        # Compare every intermediate tensor + final class
        mismatches = []
        checks = [
            ("post_conv1_int32", pc1.flatten().tolist(),  entry["post_conv1_int32"]),
            ("post_conv2_int32", pc2.flatten().tolist(),  entry["post_conv2_int32"]),
            ("post_fc1_int32",   pf1.tolist(),            entry["post_fc1_int32"]),
            ("logits_int32",     logits.tolist(),          entry["logits_int32"]),
        ]
        for name, got, want in checks:
            if got != want:
                diff = sum(g != w for g, w in zip(got, want))
                mismatches.append(f"{name}: {diff}/{len(want)} values differ")

        if pred != entry["expected_class"]:
            mismatches.append(
                f"class: got {pred}, expected {entry['expected_class']}"
            )

        if mismatches:
            failures += 1
            print(f"[FAIL] idx={idx:3d}  " + " | ".join(mismatches))
        else:
            passes += 1
            print(f"[PASS] idx={idx:3d}  class={pred}")

    print()
    print(f"Results: {passes}/100 passed, {failures}/100 failed")
    return failures == 0


if __name__ == "__main__":
    ok = run()
    sys.exit(0 if ok else 1)
