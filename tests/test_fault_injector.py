import pytest
from collections import Counter
from mock.fake_chip import FakeChip
from injector.fault_injector import FaultInjector


@pytest.fixture
def chip():
    return FakeChip()

@pytest.fixture
def injector(chip):
    return FaultInjector(chip, ber=1.0, seed=42)   # ber=1.0 → fault every cycle


# --- log structure ---------------------------------------------------------

def test_log_entry_keys(injector):
    injector.tick(1)
    assert set(injector.log[0]) == {"timestamp", "mem_id", "addr", "bit_idx"}

def test_log_length_matches_faults(injector):
    injector.tick(10)
    assert len(injector.log) == 10     # ber=1.0 → one fault per cycle

def test_timestamp_equals_cycle_number(injector):
    injector.tick(5)
    assert [e["timestamp"] for e in injector.log] == [1, 2, 3, 4, 5]

def test_timestamps_are_monotonic(injector):
    injector.tick(50)
    ts = [e["timestamp"] for e in injector.log]
    assert ts == sorted(ts)


# --- mem_id / addr / bit constraints ---------------------------------------

def test_mem_id_is_0_or_1(injector):
    injector.tick(100)
    assert all(e["mem_id"] in (0, 1) for e in injector.log)

def test_addr_in_range_weight_mem(chip):
    fi = FaultInjector(chip, ber=1.0, seed=0)
    fi.tick(500)
    weight = [e for e in fi.log if e["mem_id"] == 0]
    assert all(0 <= e["addr"] < 4096 for e in weight)

def test_addr_in_range_act_mem(chip):
    fi = FaultInjector(chip, ber=1.0, seed=0)
    fi.tick(500)
    act = [e for e in fi.log if e["mem_id"] == 1]
    assert all(0 <= e["addr"] < 8192 for e in act)

def test_bit_idx_in_range_weight_mem(chip):
    fi = FaultInjector(chip, ber=1.0, seed=0)
    fi.tick(500)
    weight = [e for e in fi.log if e["mem_id"] == 0]
    assert all(0 <= e["bit_idx"] < 16 for e in weight)

def test_bit_idx_in_range_act_mem(chip):
    fi = FaultInjector(chip, ber=1.0, seed=0)
    fi.tick(500)
    act = [e for e in fi.log if e["mem_id"] == 1]
    assert all(0 <= e["bit_idx"] < 8 for e in act)


# --- BER / reproducibility -------------------------------------------------

def test_no_faults_at_zero_ber(chip):
    fi = FaultInjector(chip, ber=0.0)
    fi.tick(10_000)
    assert len(fi.log) == 0

def test_fault_rate_approximately_matches_ber(chip):
    fi = FaultInjector(chip, ber=0.01, seed=7)
    fi.tick(10_000)
    assert 50 <= len(fi.log) <= 150    # expect ~100, ±50 is very generous

def test_same_seed_reproducible(chip):
    fi1 = FaultInjector(FakeChip(), ber=0.1, seed=99)
    fi2 = FaultInjector(FakeChip(), ber=0.1, seed=99)
    fi1.tick(1000)
    fi2.tick(1000)
    assert fi1.log == fi2.log

def test_different_seeds_differ(chip):
    fi1 = FaultInjector(FakeChip(), ber=0.1, seed=1)
    fi2 = FaultInjector(FakeChip(), ber=0.1, seed=2)
    fi1.tick(1000)
    fi2.tick(1000)
    assert fi1.log != fi2.log


# --- set_ber / reset_log ---------------------------------------------------

def test_set_ber_changes_rate(chip):
    fi = FaultInjector(chip, ber=0.0)
    fi.tick(1000)
    assert len(fi.log) == 0
    fi.set_ber(1.0)
    fi.tick(10)
    assert len(fi.log) == 10

def test_reset_log_clears(injector):
    injector.tick(20)
    injector.reset_log()
    assert injector.log == []

def test_reset_log_preserves_cycle_counter(injector):
    injector.tick(5)
    injector.reset_log()
    injector.tick(1)
    assert injector.log[0]["timestamp"] == 6


# --- FakeChip backdoor -----------------------------------------------------

def test_inject_bit_flip_flips_weight_mem_bit(chip):
    chip.inject_bit_flip(0, addr=0, bit_idx=0)
    assert chip.weight_mem[0] == 0x01

def test_inject_bit_flip_flips_act_mem_bit(chip):
    chip.inject_bit_flip(1, addr=0, bit_idx=7)
    assert chip.act_mem[0] == 0x80

def test_inject_bit_flip_double_flip_restores(chip):
    chip.inject_bit_flip(0, addr=10, bit_idx=3)
    chip.inject_bit_flip(0, addr=10, bit_idx=3)
    assert chip.weight_mem[10 * 2] == 0x00

def test_inject_bit_flip_high_byte_of_word(chip):
    chip.inject_bit_flip(0, addr=0, bit_idx=8)   # bit 8 → second byte of word 0
    assert chip.weight_mem[1] == 0x01
