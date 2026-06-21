import time
from mock.fake_chip import FakeChip

# AXI-lite register map
CTRL               = 0x00   # bit0=start_infer, bit1=scrubber_en, bit2=hardening_en
STATUS             = 0x04   # bit1=done
SCRUB_CORRECTIONS  = 0x10
ECC_DOUBLE_ERRORS  = 0x14
TMR_DISAGREEMENTS  = 0x18
INFERENCES_TOTAL   = 0x1C
LAST_OUTPUT        = 0x20   # bits[3:0] = predicted class
EVENT_POP          = 0x30   # bits[1:0]=type, [17:2]=addr, [31:18]=ts

_EVENT_TYPES = {0: "SCRUB_CORRECT", 1: "ECC_UNCORRECTABLE", 2: "TMR_OVERRIDE"}


class AcceleratorDriver:
    def __init__(self, backend=None) -> None:
        self._b = backend or FakeChip()
        self._ctrl = 0                      # shadow avoids read-modify-write races

    def load_weights(self, path: str) -> None:
        with open(path, "rb") as f:
            data = f.read()
        self._b.stream_input(data)
        print(f"load_weights: streamed {len(data):,} bytes to accelerator")

    def set_hardening(self, enabled: bool) -> None:
        self._ctrl = (self._ctrl | (1 << 2)) if enabled else (self._ctrl & ~(1 << 2))
        self._b.write(CTRL, self._ctrl)

    def set_scrubber(self, enabled: bool) -> None:
        self._ctrl = (self._ctrl | (1 << 1)) if enabled else (self._ctrl & ~(1 << 1))
        self._b.write(CTRL, self._ctrl)

    def run_inference(self, image_bytes: bytes) -> None:
        if len(image_bytes) != 784:
            raise ValueError(f"image_bytes must be exactly 784 bytes, got {len(image_bytes)}")
        self._b.stream_input(image_bytes)
        self._b.write(CTRL, self._ctrl | 0x01)     # pulse start_infer; shadow unchanged

        deadline = time.monotonic() + 2.0
        while not (self._b.read(STATUS) & 0x02):   # poll done bit
            if time.monotonic() > deadline:
                raise TimeoutError("Accelerator did not assert done within 2 s")
            time.sleep(0.001)

    def read_result(self) -> int:
        return self._b.read(LAST_OUTPUT) & 0x0F

    def read_telemetry(self) -> dict:
        return {
            "scrub_corrections": self._b.read(SCRUB_CORRECTIONS),
            "ecc_double_errors": self._b.read(ECC_DOUBLE_ERRORS),
            "tmr_disagreements": self._b.read(TMR_DISAGREEMENTS),
            "inferences_total":  self._b.read(INFERENCES_TOTAL),
        }

    def pop_event(self):
        val = self._b.read(EVENT_POP)
        if val == 0:
            return None
        return {
            "type":      _EVENT_TYPES.get(val & 0x3, "UNKNOWN"),
            "addr":      (val >> 2) & 0xFFFF,
            "timestamp": (val >> 18) & 0x3FFF,
        }


if __name__ == "__main__":
    chip   = FakeChip()
    driver = AcceleratorDriver(chip)

    driver.load_weights("weights.bin")
    driver.set_hardening(True)
    driver.set_scrubber(True)

    driver.run_inference(bytes(784))

    print(f"Predicted class : {driver.read_result()}")
    print(f"Telemetry       : {driver.read_telemetry()}")
    print(f"Pending event   : {driver.pop_event()}")
