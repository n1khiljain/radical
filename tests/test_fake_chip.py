import time
import pytest
from mock.fake_chip import FakeChip


@pytest.fixture
def chip():
    return FakeChip()


def test_write_then_read(chip):
    chip.write(0x00, 0xFF)
    assert chip.read(0x00) == 0xFF


def test_write_masks_to_byte(chip):
    chip.write(0x01, 0x1FF)       # 0x1FF & 0xFF == 0xFF
    assert chip.read(0x01) == 0xFF


def test_read_default_zero(chip):
    assert chip.read(0x05) == 0x00


def test_stream_input_accepted(chip):
    chip.stream_input(b"\xDE\xAD\xBE\xEF")
    # no crash; bytes land in the internal buffer
    with chip._lock:
        assert chip._input_buf == bytearray(b"\xDE\xAD\xBE\xEF")


def test_inject_flips_bit(chip):
    chip.write(0x10, 0b0000_0001)
    chip.inject(chip.mem, 0x10, 0)   # flip bit 0 → 0b0000_0000
    assert chip.read(0x10) == 0b0000_0000


def test_inject_flips_bit_twice_restores(chip):
    chip.write(0x10, 0xAB)
    chip.inject(chip.mem, 0x10, 3)
    chip.inject(chip.mem, 0x10, 3)
    assert chip.read(0x10) == 0xAB


def test_inject_increments_fault_counter(chip):
    chip.inject(chip.mem, 0x20, 0)
    time.sleep(0.05)                 # let the tick drain the queue
    assert chip.fault_counts.get(0x20) == 1


def test_inject_multiple_faults_same_addr(chip):
    chip.inject(chip.mem, 0x30, 0)
    chip.inject(chip.mem, 0x30, 0)
    chip.inject(chip.mem, 0x30, 0)
    time.sleep(0.05)
    assert chip.fault_counts.get(0x30) == 3


def test_inject_different_addresses_tracked_separately(chip):
    chip.inject(chip.mem, 0x01, 0)
    chip.inject(chip.mem, 0x02, 1)
    time.sleep(0.05)
    counts = chip.fault_counts
    assert counts.get(0x01) == 1
    assert counts.get(0x02) == 1


def test_tick_is_running(chip):
    time.sleep(0.05)
    assert chip.tick_count > 0


def test_inject_on_external_bytearray(chip):
    buf = bytearray(4)
    chip.inject(buf, 0, 7)           # inject works on any bytearray, not just chip.mem
    assert buf[0] == 0b1000_0000
    time.sleep(0.05)
    assert chip.fault_counts.get(0) == 1
