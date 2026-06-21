import random
from collections import Counter
from mock.fake_chip import FakeChip

# mem_id → (number of addresses, bits per word)
_MEM = {
    0: (4096, 16),   # weight_mem
    1: (8192,  8),   # act_mem
}


class FaultInjector:
    def __init__(self, backend, ber: float, seed: int = 42) -> None:
        self._backend = backend
        self.ber      = ber
        self._rng     = random.Random(seed)
        self.log      = []
        self._cycle   = 0

    def tick(self, n_cycles: int = 1) -> None:
        for _ in range(n_cycles):
            self._cycle += 1
            if self._rng.random() < self.ber:
                mem_id          = self._rng.randint(0, 1)
                n_addrs, n_bits = _MEM[mem_id]
                addr            = self._rng.randint(0, n_addrs - 1)
                bit_idx         = self._rng.randint(0, n_bits - 1)
                self._backend.inject_bit_flip(mem_id, addr, bit_idx)
                self.log.append({
                    "timestamp": self._cycle,
                    "mem_id":    mem_id,
                    "addr":      addr,
                    "bit_idx":   bit_idx,
                })

    def set_ber(self, new_ber: float) -> None:
        self.ber = new_ber

    def reset_log(self) -> None:
        self.log.clear()


if __name__ == "__main__":
    chip     = FakeChip()
    injector = FaultInjector(chip, ber=1e-3)
    injector.tick(10_000)

    total = len(injector.log)
    hist  = Counter(e["mem_id"] for e in injector.log)
    print(f"Total faults injected : {total}  (expected ≈10)")
    print(f"  mem_id=0 weight_mem : {hist[0]}")
    print(f"  mem_id=1 act_mem    : {hist[1]}")
