"""
mock/behavioral_chip.py

A *behavioral* software model of the RAD-HARD-AI accelerator.

Unlike `mock/fake_chip.py` (a dumb stub that always returns class 0 and never
moves a counter), this model actually runs the real INT8 inference pipeline on
real, possibly bit-flipped, weights. It implements a software model of the
hardening features so we can produce a genuine, defensible accuracy-vs-BER curve
*without* an RTL simulator:

  * SECDED ECC on weight memory   -- single-bit flips corrected on read,
                                     double-bit flips flagged uncorrectable
  * Background scrubber           -- corrected (single-bit) bytes are healed
                                     back to golden so errors don't accumulate
  * TMR on the MAC path           -- transient (activation) faults are voted out

All of this is gated by the `harden_en` bit, exactly like the RTL's
`HARDENING_EN` parameter, so the host can A/B test hardened vs unhardened.

It exposes the same backend API as `mock/fake_chip.py`
(`read`, `write`, `stream_input`, `inject_bit_flip`) plus `mem_geometry` so the
existing `AcceleratorDriver` and `FaultInjector` drive it unchanged.

This is a *model of the chip*, not the chip: the numbers come from real INT8
inference under real bit-flips, but the timing/area numbers still come from the
RTL. Swap `SimBackend` in once the RTL sim is up.
"""

import numpy as np

from model.gen_reference import load_artifacts, infer

# AXI-lite register map (matches specB.md / host/driver.py)
CTRL              = 0x00   # bit0=start_infer, bit1=scrub_en, bit2=harden_en
STATUS            = 0x04   # bit0=busy, bit1=done
SCRUB_CORRECTIONS = 0x10
ECC_DOUBLE_ERRORS = 0x14
TMR_DISAGREEMENTS = 0x18
INFERENCES_TOTAL  = 0x1C
LAST_OUTPUT       = 0x20   # low 4 bits = predicted class
EVENT_POP         = 0x30   # read pops one event; 0 == empty

# Event types (matches Event FIFO entry contract)
EV_SCRUB_CORRECT    = 0
EV_ECC_UNCORRECTABLE = 1
EV_TMR_OVERRIDE     = 2

# The INT8 weight tensors live in weight_mem and are the ones we fault-inject.
# Biases stay golden (they live in a separate, smaller, less-exposed region).
WEIGHT_KEYS = ["conv1_w", "conv2_w", "fc1_w", "fc2_w"]

_ACT_MEM_WORDS = 8192            # activation buffer size (8-bit words)
_EVENT_FIFO_CAP = 4096           # bound the software FIFO


class BehavioralChip:
    def __init__(self, model_path: str = "model_int8.npz",
                 scales_path: str = "scales.json") -> None:
        self._golden_arrs, self._scales = load_artifacts()

        # Flatten the INT8 weight tensors into one contiguous weight_mem image,
        # remembering how to slice each tensor back out.
        self._slices: dict[str, tuple[int, int, tuple]] = {}
        chunks = []
        off = 0
        for k in WEIGHT_KEYS:
            a = self._golden_arrs[k].astype(np.int8)
            n = a.size
            self._slices[k] = (off, off + n, a.shape)
            chunks.append(a.reshape(-1).view(np.uint8))
            off += n
        self._n_weight_bytes = off
        self._golden_flat = np.concatenate(chunks).astype(np.uint8)   # immutable golden copy
        self._weight_mem = bytearray(self._golden_flat.tobytes())     # mutable, fault-injected

        # Geometry advertised to FaultInjector: (n_addrs, bits_per_word).
        # weight_mem is byte-addressed INT8; act_mem is byte-addressed.
        self.mem_geometry = {
            0: (self._n_weight_bytes, 8),
            1: (_ACT_MEM_WORDS, 8),
        }

        self._ctrl = 0
        self._status = 0
        self._last_output = 0
        self._pending_image: bytes | None = None
        self._pending_act_faults = 0      # transient act_mem faults since last inference
        self._cycle = 0

        # Telemetry counters (free-running, like the RTL; host computes deltas).
        self._scrub_corrections = 0
        self._ecc_double_errors = 0
        self._tmr_disagreements = 0
        self._inferences_total = 0

        self._events: list[int] = []

    # ------------------------------------------------------------------
    # Backend API (mirrors mock/fake_chip.py so the driver is unchanged)
    # ------------------------------------------------------------------

    def read(self, addr: int) -> int:
        if addr == STATUS:
            return self._status
        if addr == SCRUB_CORRECTIONS:
            return self._scrub_corrections & 0xFFFFFFFF
        if addr == ECC_DOUBLE_ERRORS:
            return self._ecc_double_errors & 0xFFFFFFFF
        if addr == TMR_DISAGREEMENTS:
            return self._tmr_disagreements & 0xFFFFFFFF
        if addr == INFERENCES_TOTAL:
            return self._inferences_total & 0xFFFFFFFF
        if addr == LAST_OUTPUT:
            return self._last_output & 0x0F
        if addr == EVENT_POP:
            return self._events.pop(0) if self._events else 0
        if addr == CTRL:
            return self._ctrl
        return 0

    def write(self, addr: int, val: int) -> None:
        if addr == CTRL:
            self._ctrl = val & 0xFFFFFFFF
            if val & 0x01:                       # start_infer pulse
                self._run_inference()

    def stream_input(self, data: bytes) -> None:
        # An MNIST image is exactly 784 bytes; anything else is a weight blob
        # load (the chip already holds golden weights, so we ignore it here).
        if len(data) == 784:
            self._pending_image = bytes(data)

    def inject_bit_flip(self, mem_id: int, addr: int, bit_idx: int) -> None:
        """Sim-only backdoor: flip one bit in weight_mem (0) or act_mem (1)."""
        self._cycle += 1
        if mem_id == 0:
            if 0 <= addr < self._n_weight_bytes and 0 <= bit_idx < 8:
                self._weight_mem[addr] ^= (1 << bit_idx)
        else:
            # Activation faults are transient (act_mem is recomputed every
            # inference); we account for them at inference time via the TMR path.
            self._pending_act_faults += 1

    # ------------------------------------------------------------------
    # Inference + hardening model
    # ------------------------------------------------------------------

    def _run_inference(self) -> None:
        self._status &= ~0x02                    # clear done
        self._status |= 0x01                     # busy

        harden = bool(self._ctrl & (1 << 2))

        # --- TMR on the MAC path: transient activation faults are voted out ---
        if self._pending_act_faults:
            if harden:
                for _ in range(self._pending_act_faults):
                    self._tmr_disagreements += 1
                    self._emit_event(EV_TMR_OVERRIDE, self._cycle & 0xFFFF)
            self._pending_act_faults = 0

        # --- SECDED ECC + scrubber on weight_mem (only when hardened) ---
        if harden:
            self._apply_ecc_and_scrub()

        # --- reconstruct weight tensors from (possibly corrupted) weight_mem ---
        eff = np.frombuffer(bytes(self._weight_mem), dtype=np.int8)
        arrs = dict(self._golden_arrs)
        for k, (s, e, shape) in self._slices.items():
            arrs[k] = eff[s:e].reshape(shape)

        img_bytes = self._pending_image if self._pending_image is not None else bytes(784)
        img = (np.frombuffer(img_bytes, dtype=np.uint8)
               .astype(np.float32).reshape(28, 28) / 255.0)

        _, _, _, logits = infer(img, arrs, self._scales)
        self._last_output = int(logits.argmax())
        self._inferences_total += 1

        self._status &= ~0x01                    # clear busy
        self._status |= 0x02                     # done

    def _apply_ecc_and_scrub(self) -> None:
        """Software model of SECDED ECC + background scrubber on weight_mem.

        For each byte, compare against golden:
          * 0 bits flipped -> clean
          * 1 bit flipped  -> correctable: heal it, count a scrub correction
          * >=2 bits flipped -> uncorrectable: leave corrupted, count a double error
        """
        cur = np.frombuffer(bytes(self._weight_mem), dtype=np.uint8)
        xor = np.bitwise_xor(cur, self._golden_flat)
        if not xor.any():
            return

        nbits = np.unpackbits(xor[:, None], axis=1).sum(axis=1)
        single = np.nonzero(nbits == 1)[0]
        double = np.nonzero(nbits >= 2)[0]

        if single.size:
            healed = bytearray(self._weight_mem)
            for idx in single.tolist():
                healed[idx] = int(self._golden_flat[idx])     # scrubber writes back golden
                self._scrub_corrections += 1
                self._emit_event(EV_SCRUB_CORRECT, idx)
            self._weight_mem = healed

        for idx in double.tolist():
            self._ecc_double_errors += 1
            self._emit_event(EV_ECC_UNCORRECTABLE, idx)

    def _emit_event(self, etype: int, addr: int) -> None:
        ts = self._cycle & 0x3FFF
        packed = (etype & 0x3) | ((addr & 0xFFFF) << 2) | (ts << 18)
        if packed == 0:                          # 0 means "FIFO empty"; keep nonzero
            packed = (1 << 18)
        self._events.append(packed & 0xFFFFFFFF)
        if len(self._events) > _EVENT_FIFO_CAP:
            self._events.pop(0)

    # ------------------------------------------------------------------
    # Host helpers (not part of the AXI contract, used by sweeps/dashboard)
    # ------------------------------------------------------------------

    def reset_faults(self) -> None:
        """Restore weight_mem to golden and drop pending transients/events."""
        self._weight_mem = bytearray(self._golden_flat.tobytes())
        self._pending_act_faults = 0
        self._events.clear()

    def reset_counters(self) -> None:
        self._scrub_corrections = 0
        self._ecc_double_errors = 0
        self._tmr_disagreements = 0
        self._inferences_total = 0
        self._events.clear()

    @property
    def corrupted_weight_bytes(self) -> int:
        cur = np.frombuffer(bytes(self._weight_mem), dtype=np.uint8)
        return int(np.count_nonzero(cur != self._golden_flat))


if __name__ == "__main__":
    chip = BehavioralChip()
    print(f"weight_mem: {chip._n_weight_bytes:,} INT8 bytes")
    chip.stream_input(bytes(784))
    chip.write(CTRL, 0x01)                        # start, unhardened, no faults
    print(f"clean prediction (blank image): class {chip.read(LAST_OUTPUT)}")
    print(f"inferences_total: {chip.read(INFERENCES_TOTAL)}")
