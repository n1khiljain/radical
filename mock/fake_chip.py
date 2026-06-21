import threading
import time
from collections import defaultdict


MEM_SIZE = 256


class FakeChip:
    """Software stand-in for a hardware chip with addressable memory."""

    def __init__(self, mem_size: int = MEM_SIZE, tick_hz: int = 100) -> None:
        self.mem = bytearray(mem_size)
        self.weight_mem = bytearray(4096 * 2)   # 4096 × 16-bit words
        self.act_mem    = bytearray(8192)        # 8192 × 8-bit words
        self._input_buf = bytearray()
        self._lock = threading.Lock()
        self._fault_counts: dict[int, int] = defaultdict(int)
        self._pending_faults: list[int] = []
        self._tick_count = 0
        self._tick_interval = 1.0 / tick_hz
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    # ------------------------------------------------------------------
    # Core memory interface
    # ------------------------------------------------------------------

    def read(self, addr: int) -> int:
        with self._lock:
            return self.mem[addr]

    def write(self, addr: int, val: int) -> None:
        with self._lock:
            self.mem[addr] = val & 0xFF
            # Simulate synchronous inference: CTRL bit 0 (start_infer) → STATUS bit 1 (done)
            if addr == 0x00 and (val & 0x01):
                self.mem[0x04] |= 0x02

    def stream_input(self, data: bytes) -> None:
        with self._lock:
            self._input_buf.extend(data)

    # ------------------------------------------------------------------
    # Fault injection hook (called by the fault injector)
    # ------------------------------------------------------------------

    def inject(self, mem: bytearray, addr: int, bit: int) -> None:
        """Flip `bit` in `mem[addr]` and queue a fault counter increment."""
        with self._lock:
            mem[addr] ^= 1 << bit
            self._pending_faults.append(addr)

    def inject_bit_flip(self, mem_id: int, addr: int, bit_idx: int) -> None:
        """Sim-only backdoor: flip one bit in weight_mem (0) or act_mem (1)."""
        with self._lock:
            if mem_id == 0:                              # 16-bit words → two bytes each
                self.weight_mem[addr * 2 + (bit_idx >> 3)] ^= 1 << (bit_idx & 7)
            else:                                        # 8-bit words → one byte each
                self.act_mem[addr] ^= 1 << bit_idx
            self._pending_faults.append(addr)

    # ------------------------------------------------------------------
    # Background tick
    # ------------------------------------------------------------------

    def _run(self) -> None:
        while True:
            time.sleep(self._tick_interval)
            with self._lock:
                self._tick_count += 1
                for addr in self._pending_faults:
                    self._fault_counts[addr] += 1
                self._pending_faults.clear()

    # ------------------------------------------------------------------
    # Inspection helpers
    # ------------------------------------------------------------------

    @property
    def fault_counts(self) -> dict[int, int]:
        with self._lock:
            return dict(self._fault_counts)

    @property
    def tick_count(self) -> int:
        with self._lock:
            return self._tick_count
