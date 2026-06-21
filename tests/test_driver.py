import time
import pytest
from mock.fake_chip import FakeChip
from host.driver import AcceleratorDriver, CTRL, STATUS, LAST_OUTPUT, EVENT_POP


@pytest.fixture
def chip():
    return FakeChip()

@pytest.fixture
def driver(chip):
    return AcceleratorDriver(chip)


# --- CTRL shadow -----------------------------------------------------------

def test_set_hardening_sets_bit2(chip, driver):
    driver.set_hardening(True)
    assert chip.read(CTRL) & (1 << 2)

def test_set_hardening_clears_bit2(chip, driver):
    driver.set_hardening(True)
    driver.set_hardening(False)
    assert not (chip.read(CTRL) & (1 << 2))

def test_set_scrubber_sets_bit1(chip, driver):
    driver.set_scrubber(True)
    assert chip.read(CTRL) & (1 << 1)

def test_ctrl_bits_do_not_clobber_each_other(chip, driver):
    driver.set_hardening(True)
    driver.set_scrubber(True)
    val = chip.read(CTRL)
    assert val & (1 << 2) and val & (1 << 1)

def test_start_infer_does_not_persist_in_shadow(chip, driver):
    driver.run_inference(bytes(784))
    # after inference, shadow bit 0 must be clear so next set_hardening doesn't re-trigger
    driver.set_hardening(False)
    assert not (chip.read(CTRL) & 0x01)


# --- load_weights ----------------------------------------------------------

def test_load_weights_streams_bytes(chip, driver):
    driver.load_weights("weights.bin")
    with chip._lock:
        assert len(chip._input_buf) > 0

def test_load_weights_exact_size(chip, driver):
    driver.load_weights("weights.bin")
    import os
    expected = os.path.getsize("weights.bin")
    with chip._lock:
        assert len(chip._input_buf) == expected


# --- run_inference ---------------------------------------------------------

def test_run_inference_accepts_784_bytes(driver):
    driver.run_inference(bytes(784))   # should not raise

def test_run_inference_rejects_wrong_size(driver):
    with pytest.raises(ValueError):
        driver.run_inference(bytes(100))

def test_run_inference_streams_image(chip, driver):
    payload = bytes(range(256)) * 3 + bytes(16)   # 784 bytes
    driver.run_inference(payload)
    with chip._lock:
        assert payload in bytes(chip._input_buf)

def test_run_inference_timeout(chip):
    """A backend that never sets done bit should raise TimeoutError."""
    class NeverDoneChip:
        mem = bytearray(256)
        def read(self, addr): return 0
        def write(self, addr, val): pass
        def stream_input(self, data): pass

    d = AcceleratorDriver(NeverDoneChip())
    with pytest.raises(TimeoutError):
        d.run_inference(bytes(784))


# --- read_result -----------------------------------------------------------

def test_read_result_masks_low_4_bits(chip, driver):
    chip.write(LAST_OUTPUT, 0b11001010)   # high nibble should be stripped
    assert driver.read_result() == 0b1010

def test_read_result_range(chip, driver):
    for v in range(256):
        chip.write(LAST_OUTPUT, v)
        assert 0 <= driver.read_result() <= 15


# --- read_telemetry --------------------------------------------------------

def test_read_telemetry_keys(driver):
    t = driver.read_telemetry()
    assert set(t) == {"scrub_corrections", "ecc_double_errors", "tmr_disagreements", "inferences_total"}

def test_read_telemetry_values(chip, driver):
    chip.write(0x10, 7)
    assert driver.read_telemetry()["scrub_corrections"] == 7


# --- pop_event -------------------------------------------------------------

def test_pop_event_returns_none_when_zero(driver):
    assert driver.pop_event() is None

def test_pop_event_unpacks_type_addr_ts(chip, driver):
    # type=1 (ECC_UNCORRECTABLE), addr=0x1F, ts=0x3
    val = (1 & 0x3) | ((0x1F & 0xFFFF) << 2) | ((0x3 & 0x3FFF) << 18)
    chip.write(EVENT_POP, val & 0xFF)   # FakeChip stores low byte; test low bits
    event = driver.pop_event()
    assert event is not None
    assert event["type"] == "ECC_UNCORRECTABLE"

def test_pop_event_type_scrub_correct(chip, driver):
    # type=0 (SCRUB_CORRECT), addr_bit0=1 so full value != 0
    chip.write(EVENT_POP, 0b100)        # bits[1:0]=00 → SCRUB_CORRECT, bit2=1 → addr=1
    assert driver.pop_event()["type"] == "SCRUB_CORRECT"
