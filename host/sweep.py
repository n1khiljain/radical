"""
host/sweep.py

Hardened-vs-unhardened accuracy sweep over a grid of bit-error rates.

For each BER, and for each of {unhardened, hardened}, we:
  * reset the chip's weight memory to golden
  * stream every reference MNIST image through the accelerator while the
    FaultInjector flips bits in weight_mem at the configured BER
  * compare the chip's prediction against the clean INT8 reference prediction

The "accuracy" we report is *agreement with the clean INT8 reference* -- i.e.
the fraction of inferences the radiation faults did NOT change. That is exactly
the metric the demo cares about: does the chip keep producing correct outputs
under radiation?

Writes `sweep_results.csv` and `sweep_accuracy.png`.

Run:  python -m host.sweep
"""

import argparse
import csv
import json

from mock.behavioral_chip import BehavioralChip
from host.driver import AcceleratorDriver
from injector.fault_injector import FaultInjector

# Injected BER per cycle, with CYCLES_PER_INF cycles of exposure between each
# inference. Calibrated so the unhardened baseline degrades smoothly to collapse
# while the hardened design holds. (The BER axis is the injector knob, not a
# physical orbit rate -- see demo/script.md.)
DEFAULT_BERS = [0.0, 0.003, 0.01, 0.03, 0.1, 0.2, 0.4]
CYCLES_PER_INF = 2000


def run_sweep(bers=DEFAULT_BERS, n_samples=100, cycles_per_inf=CYCLES_PER_INF,
              seed=42, ref_path="reference_outputs.json",
              out_csv="sweep_results.csv", progress=None):
    with open(ref_path) as f:
        ref = json.load(f)[:n_samples]

    chip = BehavioralChip()
    driver = AcceleratorDriver(chip)
    rows = []

    for ber in bers:
        for harden in (False, True):
            chip.reset_faults()
            chip.reset_counters()
            driver.set_hardening(harden)
            driver.set_scrubber(harden)
            inj = FaultInjector(chip, ber=ber, seed=seed)

            correct = 0
            for entry in ref:
                inj.tick(cycles_per_inf)
                driver.run_inference(bytes(entry["input_bytes"]))
                if driver.read_result() == entry["expected_class"]:
                    correct += 1

            tel = driver.read_telemetry()
            row = {
                "ber": ber,
                "hardened": int(harden),
                "accuracy": correct / len(ref),
                "corrupted_weight_bytes": chip.corrupted_weight_bytes,
                **tel,
            }
            rows.append(row)
            line = (f"BER={ber:<6g} hardened={int(harden)} "
                    f"acc={row['accuracy']:.0%} "
                    f"scrub={tel['scrub_corrections']:>5} "
                    f"ecc2={tel['ecc_double_errors']:>4} "
                    f"tmr={tel['tmr_disagreements']:>4}")
            print(line)
            if progress:
                progress(row)

    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"\nWrote {out_csv} ({len(rows)} rows)")
    return rows


def plot_sweep(csv_path="sweep_results.csv", out_png="sweep_accuracy.png"):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    rows = list(csv.DictReader(open(csv_path)))
    series = {0: ([], []), 1: ([], [])}
    for r in rows:
        h = int(r["hardened"])
        series[h][0].append(float(r["ber"]))
        series[h][1].append(float(r["accuracy"]) * 100)

    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.plot(series[0][0], series[0][1], "o-", color="#d6336c",
            label="Unhardened (baseline)", linewidth=2)
    ax.plot(series[1][0], series[1][1], "s-", color="#1c7ed6",
            label="Hardened (ECC + scrubber + TMR)", linewidth=2)
    ax.set_xscale("symlog", linthresh=1e-3)
    ax.set_xlabel("Injected bit-error rate (per cycle)")
    ax.set_ylabel("Accuracy vs clean INT8 reference (%)")
    ax.set_title("RAD-HARD-AI: accuracy under simulated radiation")
    ax.set_ylim(0, 105)
    ax.grid(True, alpha=0.3)
    ax.legend(loc="lower left")
    fig.tight_layout()
    fig.savefig(out_png, dpi=130)
    print(f"Wrote {out_png}")
    return out_png


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="RAD-HARD-AI BER sweep")
    p.add_argument("--samples", type=int, default=100)
    p.add_argument("--cycles", type=int, default=CYCLES_PER_INF)
    p.add_argument("--no-plot", action="store_true")
    args = p.parse_args()

    run_sweep(n_samples=args.samples, cycles_per_inf=args.cycles)
    if not args.no_plot:
        plot_sweep()
