# Project: RAD-HARD-AI — Radiation-Hardened Neural Inference Accelerator

## One-line pitch
A small AI inference chip that keeps producing correct outputs when cosmic rays
flip bits inside it — bridging the gap between modern ML accelerators (fast, fragile)
and space-grade processors (robust, ancient).

## Problem statement
High-energy particles in space cause single-event effects (SEEs) in silicon:
- Single-event upsets (SEU): a stored bit flips
- Single-event transients (SET): a logic glitch propagates
- Single-event latchups (SEL): chip enters a destructive state

Current spacecraft compute (e.g., RAD750) is decades behind commercial AI silicon.
There is no small, modern, open neural accelerator designed for SEE tolerance.

## Goal
Demonstrate a small INT8 CNN inference accelerator that:
1. Runs a real workload (crater/hazard detection on NASA Mars imagery, or MNIST fallback)
2. Maintains classification accuracy under simulated SEU injection
3. Reports radiation events (corrections, voter disagreements) as live telemetry
4. Quantifies the area/power/throughput overhead of hardening vs an unhardened baseline

## Architecture

### Top-level blocks
- `accel_top` — top wrapper, AXI-lite control + AXI-stream data
- `weight_mem` — ECC-protected SRAM holding INT8 weights (SECDED Hamming)
- `act_mem` — activation buffer (ECC optional, lower priority)
- `mac_array` — TMR'd MAC units (3 copies + majority voter per MAC)
- `scrubber` — background state machine that walks weight_mem, correcting via ECC
- `telemetry` — register file exposing event counters to host
- `ctrl` — sequencer that drives layer-by-layer inference

### Hardening features (implement in this order)
1. SECDED ECC on weight SRAM (13-bit codeword per 8-bit data)
2. Background scrubber with configurable scrub interval
3. TMR on MAC outputs with majority voter
4. Optional: ECC on activation memory, TMR on control state

### Fault injector (testbench only, NOT on chip)
- Random bit-flip into weight_mem, act_mem, or pipeline registers
- Configurable bit error rate (BER) and distribution
- Logs every injection event with timestamp + location

### Telemetry counters (exposed via AXI-lite)
- `scrub_corrections_total`
- `ecc_double_errors_total` (uncorrectable)
- `tmr_disagreements_total`
- `inferences_total`

## Workload
- **Primary:** Mars crater detection CNN (4–5 conv layers, INT8, ~100K params)
  - Dataset: NASA HiRISE crater dataset (public)
- **Fallback:** MNIST CNN if crater dataset proves too heavy

Model trained in PyTorch, quantized to INT8, exported as flat binary for SRAM load.

## Conventions
- All RTL in SystemVerilog
- Module names: `snake_case`
- Signal names: `snake_case`, active-low signals suffixed `_n`
- One module per file, file named after module
- All hardening features behind a `HARDENING_EN` parameter so we can A/B test
- AXI-lite for control, AXI-stream for data

## Non-goals
- Not taping out real silicon. Target is FPGA/simulator deliverable.
- Not building a full transformer accelerator. Small CNN only.
- Not handling latchup recovery in hardware (out of scope for weekend).

## Sponsor integrations
- **QNX** hosts the demo control plane (model loader, fault injector controller, dashboard)
- **Arize** logs inference outputs + accuracy drift across fault-injection runs
- **Sentry** receives every ECC correction / TMR disagreement as an event
- **Redis** buffers telemetry between chip sim and dashboard
- **Cognition/Devin** assists with RTL boilerplate (testbenches, AXI wrappers) — NOT the novel hardening logic
- **Runpod** runs PyTorch training + large fault-injection sweeps

## Out-of-scope for Claude assistance
Do not autogenerate the TMR voter, ECC encoder/decoder, or scrubber state machine.
These are the novel parts and the team writes them by hand.
Claude may scaffold testbenches, AXI plumbing, register files, and Python glue.

## Demo flow
1. Show baseline accelerator running crater detection — ~99% accuracy, no faults
2. Enable fault injection at low BER — baseline degrades, hardened version stable
3. Sweep BER higher — show accuracy curve: baseline collapses, hardened holds
4. Show live Sentry feed of radiation events being caught and corrected
5. Show Arize dashboard of inference confidence under fault load
6. Close with area/power/throughput overhead table

## Success metrics
- Baseline accuracy parity with PyTorch INT8 reference (±1%)
- Hardened accuracy maintained at BER where baseline drops >10%
- All radiation events captured and reported in telemetry
- End-to-end demo runs in <3 minutes