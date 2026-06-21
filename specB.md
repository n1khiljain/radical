# CLAUDE.md — RAD-HARD-AI (Person B: Host/Software)

## Project
Building a small radiation-hardened INT8 CNN inference accelerator that maintains
correctness under simulated single-event upsets. Target workload is MNIST. Demo
shows hardened-vs-unhardened accuracy under fault injection.

## My role (Person B)
I own everything outside the chip: training the model, exporting weights, driving
the chip via AXI, the fault-injection script, the host driver, the dashboard,
and the sponsor integrations (Sentry, Redis). I do NOT touch RTL — that's Person A.

## What I own (files)
- `model/train.py` — PyTorch training of MNIST CNN
- `model/quantize.py` — INT8 quantization
- `model/export.py` — produces `weights.bin` in agreed format
- `model/reference.py` — PyTorch INT8 inference for ground-truth comparison
- `injector/fault_injector.py` — drives `inject_bit_flip` via sim DPI
- `host/driver.py` — AXI-lite read/write wrapper over sim socket
- `host/runner.py` — orchestrates inference + sweeps
- `dashboard/app.py` — Streamlit live demo
- `integrations/sentry_emit.py` — event FIFO → Sentry SDK
- `integrations/redis_bus.py` — telemetry counter buffer
- `mock/fake_chip.py` — Python stub of the accelerator for parallel development
- `demo/script.md`, `demo/backup.mp4`

## Tools
- PyTorch + Brevitas (or native quantization) for INT8 training
- Runpod for GPU training time
- Streamlit for dashboard (fast to build, Pythonic)
- Sentry SDK (Python)
- Redis (in-memory, single-node)
- The host talks to Person A's sim via a socket or file interface — confirm
  which one Person A is using before writing the driver.

## Shared interface contract (DO NOT CHANGE WITHOUT PERSON A SIGNOFF)

### Weight binary format
Flat little-endian INT8 array. Per layer:
- 4-byte length header (uint32 LE, number of bytes that follow)
- Raw INT8 weight bytes
- 4-byte bias length header
- Raw INT8 bias bytes
Layer order: conv1, conv2, fc1, fc2.

### AXI-lite register map (base 0x4000_0000)
- 0x00 CTRL: bit0=start_infer, bit1=scrub_en, bit2=harden_en
- 0x04 STATUS: bit0=busy, bit1=done
- 0x10 SCRUB_CORRECTIONS (32-bit free-running counter)
- 0x14 ECC_DOUBLE_ERRORS (free-running)
- 0x18 TMR_DISAGREEMENTS (free-running)
- 0x1C INFERENCES_TOTAL (free-running)
- 0x20 LAST_OUTPUT (low 4 bits = predicted class)
- 0x30 EVENT_POP (read pops one event; returns 0 if empty)

Counters never reset during a run. I compute deltas on the host.

### AXI-stream input
- 784 bytes per inference (28×28 MNIST), tlast on byte 783
- I normalize on the host BEFORE sending; chip consumes raw bytes

### Event FIFO entry (32 bits packed)
- [1:0] type (0=SCRUB_CORRECT, 1=ECC_UNCORRECTABLE, 2=TMR_OVERRIDE)
- [17:2] addr
- [31:18] timestamp

### Fault injection backdoor (sim only)
Call into sim: `inject_bit_flip(mem_id, addr, bit_idx)`
- mem_id: 0=weight_mem, 1=act_mem

## Sponsor integrations
- **Sentry**: every EVENT_POP result that isn't zero → emit as Sentry event.
  Use `sentry_sdk.capture_message` with tags {type, addr}. Severity:
  SCRUB_CORRECT=info, TMR_OVERRIDE=warning, ECC_UNCORRECTABLE=error.
- **Redis**: write telemetry counter snapshots to keys `telemetry:{name}` every
  100ms. Dashboard reads from Redis, not from chip directly — decouples polling.
- **Runpod**: used only for training. Single A10 or smaller is plenty for MNIST.
- **Cognichips IDE agents**: scaffold AXI driver, dashboard layout, sweep loops.

## Stub-first pattern
I do NOT block on Person A. Start by building `mock/fake_chip.py`: a Python
class with `read(addr)`, `write(addr, val)`, `stream(bytes)` that fakes:
- busy→done transition after N cycles
- LAST_OUTPUT = 7 for any input
- counters increment when fault_injector pokes them
- event FIFO seeded with random events
Then develop driver, dashboard, Sentry wiring against the stub. Swap to real
sim at the hour-3 sync.

## What Claude can do for me
- Scaffold Streamlit layout
- Generate AXI driver wrapper
- Write fault injector loop (random bit selection, BER scheduling)
- Wire Sentry and Redis SDKs
- Generate PyTorch quantization + export scripts
- Plot accuracy-vs-BER from sweep CSVs

## What I write myself
- The interface contract (no improvising)
- The demo script and pitch
- The fault injector's core loop logic (so I can defend it)

## Order of work (~18 hours from now)
See `STEPS.md` for hour-by-hour.

## Pair with
Person A owns RTL. Sync every ~3 hours. Contract changes require both signatures
in `SPEC.md`.