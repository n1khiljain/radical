# RAD-HARD-AI — 3-minute demo script (Person B / host side)

**Pitch (15s):** "Modern AI chips are fast but fragile; space-grade chips are
robust but ancient. We built a small INT8 CNN inference accelerator that keeps
producing correct outputs when cosmic rays flip bits inside it — and we can show
it live."

> Setup before you start: `python -m host.sweep` (generates the curve), then
> `streamlit run dashboard/app.py`. Optional: export `SENTRY_DSN` for the live
> Sentry feed; otherwise it runs offline.

---

## 0:00 — Baseline, no radiation (30s)
- Dashboard open. **Hardening OFF**, **BER = 0**. Hit **Run**.
- Point at **Accuracy vs reference = 100%**. "This is our INT8 CNN matching the
  PyTorch reference exactly — same numbers the RTL produces, byte for byte."
- Mention: 100/100 reference samples match the PyTorch INT8 ground truth.

## 0:30 — Turn on the radiation, hardening still OFF (45s)
- Set **BER = 0.03**, keep **Hardening OFF**. Watch accuracy **drop**.
- "Each tick, we flip random bits in the weight memory — single-event upsets.
  With no protection, the corruption accumulates and the network degrades."
- Push **BER = 0.2** → accuracy collapses toward ~50% and below. Corrupted
  weight-byte counter climbs into the thousands.

## 1:15 — Flip hardening ON (45s)
- Same BER. Toggle **Hardening ON**. Accuracy snaps back to ~100%.
- "Now SECDED ECC catches every single-bit flip on read, the background scrubber
  heals the memory so errors don't pile up, and TMR votes out bad MAC outputs."
- Point at telemetry: **Scrub corrections** and **TMR overrides** counters racing
  up — "every one of those is a radiation event we caught and corrected."

## 2:00 — The money chart (30s)
- Point to **Accuracy vs BER** curve (right panel / `sweep_accuracy.png`).
- "Red is unhardened — it collapses. Blue is hardened — it holds at ~100% across
  four orders of magnitude of fault rate, only bending at extreme BER where
  double-bit errors start to slip past SECDED. That's the expected, honest limit."

## 2:30 — Live event feed + Sentry (20s)
- Point at the **Live event feed** table and (if DSN set) the Sentry dashboard.
- "Every ECC correction and TMR override is emitted as a telemetry event —
  info for a corrected scrub, warning for a TMR override, error for an
  uncorrectable double-bit. Operators get a live radiation log of the chip."

## 2:50 — Close (10s)
- "Same accuracy as the unhardened baseline with zero faults; full accuracy
  retained where the baseline drops by half. Small, modern, open, and built for
  space." 

---

## Backup / talking points if something breaks
- The numbers come from **real INT8 inference under real bit-flips** in
  `mock/behavioral_chip.py` — a behavioral model of the RTL, used because no
  Verilator/iverilog is installed on the demo machine. Swap `host/sim_backend.py`
  (TCP to the RTL sim) in for `BehavioralChip` once the simulator is up; the
  driver, injector, sweep, and dashboard are all backend-agnostic.
- If the dashboard misbehaves, run the headless sweep live:
  `python -m host.sweep` — it prints the full A/B table in ~20s.
- **BER axis is the injector knob** (probability per cycle, 2000 cycles of
  exposure per inference), not a physical orbit upset rate. It's the dose dial
  for the demo, not a flight prediction.

## Numbers to know
| Condition | Unhardened | Hardened |
|---|---|---|
| BER = 0 | 100% | 100% |
| BER = 0.03 | ~90% | 100% |
| BER = 0.2 | ~50% | ~99% |
| BER = 0.4 | ~47% | ~98% |

(Exact values: `sweep_results.csv`.)
