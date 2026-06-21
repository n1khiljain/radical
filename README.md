# RAD-HARD-AI

A small **radiation-hardened INT8 CNN inference accelerator** that keeps producing
correct outputs when cosmic rays flip bits inside it — bridging modern ML silicon
(fast, fragile) and space-grade processors (robust, ancient).

Workload: MNIST digit classification. Hardening: SECDED ECC on weight memory, a
background scrubber, and TMR on the MAC path — all gated by `HARDENING_EN` so we
can A/B test hardened vs unhardened under simulated single-event upsets.

## Repository layout

```
rtl/            Synthesizable SystemVerilog design modules
tb/             Testbenches + sim C/VPI bridges (sim-only, incl. fault_replay backdoor)
model/          PyTorch training, INT8 quantization, weight export, golden references
host/           AXI driver, validation runner, BER sweep, sim backends/bridge
injector/       Fault injector (random bit-flip scheduling at a target BER)
mock/           fake_chip (stub) + behavioral_chip (real INT8 inference under faults)
integrations/   Sentry (radiation-event feed) + Redis (telemetry buffer)
dashboard/      Streamlit live demo
scripts/        verify_e2e.py — RTL sim vs hardware-accurate Python reference
tests/          pytest suite
docs/           specA.md (Person A / RTL), specB.md (Person B / host)
data/           MNIST
DEPS.yml        Per-bench RTL file lists for the EDA/sim flow
```

Generated data artifacts live at the repo root (`weights.bin`, `model_int8.npz`,
`scales.json`, `reference_outputs.json`, `model.pt`) — they are the runtime I/O
contract between the model, host, and chip.

## Quickstart

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Model pipeline (artifacts are checked in, so this is optional)
python -m model.train          # -> model.pt
python -m model.quantize       # -> model_int8.npz, scales.json
python -m model.export         # -> weights.bin
python -m model.gen_reference  # -> reference_outputs.json

# Tests
pytest -q

# The demo: accuracy-vs-BER sweep, then the live dashboard
python -m host.sweep                 # -> sweep_results.csv, sweep_accuracy.png
streamlit run dashboard/app.py
```

See `demo/script.md` for the 3-minute demo narration.

## Hardened vs unhardened (from `host/sweep.py`)

The baseline collapses as bit-flips accumulate in weight memory; the hardened
design holds, only bending at extreme fault rates where double-bit errors slip
past SECDED.

| Injected BER | Unhardened | Hardened |
|---|---|---|
| 0     | 100% | 100% |
| 0.03  | ~90% | 100% |
| 0.2   | ~50% | ~99% |
| 0.4   | ~47% | ~98% |

> The numbers come from real INT8 inference under real bit-flips in
> `mock/behavioral_chip.py`, a behavioral model of the RTL. To drive the actual
> RTL instead, swap `BehavioralChip` for `host/sim_bridge.py` (compiles the RTL
> with `iverilog` and speaks the same backend API) — the driver, injector,
> sweep, and dashboard are all backend-agnostic.

## RTL simulation

```bash
# Compile + run a single bench (file lists are in DEPS.yml)
iverilog -g2012 -o /tmp/mac.vvp rtl/mac_array.sv tb/tb_mac_array.sv && vvp /tmp/mac.vvp

# End-to-end: one image through the RTL sim vs the hardware-accurate reference
python scripts/verify_e2e.py --idx 0
```

## Sponsor integrations

- **Sentry** — every ECC correction / TMR override / double-bit error is emitted
  as an event (info / warning / error). Offline-safe without a DSN.
- **Redis** — telemetry counters are buffered for the dashboard. Falls back to
  in-memory without a server.
