# CLAUDE.md — RAD-HARD-AI (Person A: Chip/RTL)

## Project
Building a small radiation-hardened INT8 CNN inference accelerator that maintains
correctness under simulated single-event upsets. Target workload is MNIST. Demo
shows hardened-vs-unhardened accuracy under fault injection.

## My role (Person A)
I own everything inside the chip. SystemVerilog modules, testbenches, sim setup,
the fault-injection backdoor task. I do NOT touch PyTorch, the host driver,
the dashboard, or sponsor integrations — that's Person B.

## What I own (files)
- `rtl/accel_top.sv` — top wrapper, AXI-lite + AXI-stream interfaces
- `rtl/mac_array.sv`, `rtl/mac_tmr.sv`, `rtl/tmr_voter.sv`
- `rtl/weight_mem.sv`, `rtl/ecc_encoder.sv`, `rtl/ecc_decoder.sv`
- `rtl/act_mem.sv`
- `rtl/scrubber.sv`
- `rtl/ctrl_seq.sv`
- `rtl/telemetry_regs.sv`
- `tb/*_tb.sv` — every block has a testbench
- `tb/fault_inject.sv` — DPI/task backdoor for Person B's injector

## What Claude should NOT write for me
These are the novel parts I write by hand to defend in the demo:
- TMR voter (4-line majority logic)
- ECC encoder/decoder (Hamming SECDED, 8 data + 5 parity = 13 bits)
- Scrubber FSM
- Register map decoding

## What Claude SHOULD scaffold for me
- AXI-lite register file boilerplate
- AXI-stream input handler
- Testbench harnesses (clock, reset, dumpvars)
- Memory model wrappers
- Sim build scripts (Verilator / Cognichips equivalent)

## Workload
- MNIST 28×28 grayscale, INT8 quantized
- Tiny CNN: 2 conv + 2 FC, ~50K params total
- Weights loaded from `weights.bin` produced by Person B
- Expected baseline accuracy: ~98%

## Shared interface contract (DO NOT CHANGE WITHOUT PERSON B SIGNOFF)

### Weight binary format
Flat little-endian INT8 array. Per layer:
- 4-byte length header (uint32 LE, number of bytes that follow)
- Raw INT8 weight bytes
- 4-byte bias length header
- Raw INT8 bias bytes
Layer order: conv1, conv2, fc1, fc2. Loaded into `weight_mem` starting at addr 0.

### AXI-lite register map (base 0x4000_0000)
- 0x00 CTRL: bit0=start_infer, bit1=scrub_en, bit2=harden_en
- 0x04 STATUS: bit0=busy, bit1=done
- 0x10 SCRUB_CORRECTIONS (32-bit counter, free-running, never resets)
- 0x14 ECC_DOUBLE_ERRORS (uncorrectable, free-running)
- 0x18 TMR_DISAGREEMENTS (free-running)
- 0x1C INFERENCES_TOTAL (free-running)
- 0x20 LAST_OUTPUT (low 4 bits = predicted class)
- 0x30 EVENT_POP (read pops one event from FIFO; returns 0 if empty)

### AXI-stream input
- tdata[7:0], tvalid, tready, tlast
- 784 bytes per inference, tlast on byte 783
- Host normalizes; chip consumes raw bytes

### Event FIFO entry (32 bits packed)
- [1:0] type (0=SCRUB_CORRECT, 1=ECC_UNCORRECTABLE, 2=TMR_OVERRIDE)
- [17:2] addr
- [31:18] timestamp (low bits of cycle counter)

### Fault injection backdoor (sim only)
```systemverilog
task inject_bit_flip(input int mem_id, input int addr, input int bit_idx);
  // mem_id: 0=weight_mem, 1=act_mem
endtask
```

## Order of work (~18 hours)
1. Baseline accelerator + AXI plumbing, end-to-end MNIST inference matching PyTorch (~5 hr)
2. SECDED ECC on weight_mem, scrubber FSM (~3 hr)
3. TMR on one representative MAC + voter, wire to telemetry (~3 hr)
4. Telemetry regs + event FIFO finalized (~2 hr)
5. Integration debug with Person B (~3 hr)
6. Demo support (~2 hr)

## Conventions
- SystemVerilog, snake_case modules/signals, active-low signals get `_n`
- One module per file, file named after module
- All hardening features gated by `HARDENING_EN` parameter
- AXI-lite control, AXI-stream data
- Synchronous active-high reset
- No latches, no `initial` outside testbenches

## Build acceptance criteria
- `HARDENING_EN=0`, zero faults → MNIST accuracy within 1% of PyTorch INT8 ref
- `HARDENING_EN=1`, zero faults → same accuracy as above
- `HARDENING_EN=1`, BER=1e-4 → accuracy holds within 5% of clean
- `HARDENING_EN=0`, BER=1e-4 → accuracy collapses (this is the demo)

## Pair with
Person B owns the Python side. Sync every ~3 hours. Contract changes require
both of us to update `SPEC.md` in the same commit.