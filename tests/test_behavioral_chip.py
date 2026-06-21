import json

import pytest

from mock.behavioral_chip import (
    BehavioralChip, CTRL, STATUS, LAST_OUTPUT, INFERENCES_TOTAL,
    SCRUB_CORRECTIONS, ECC_DOUBLE_ERRORS, EVENT_POP,
)
from host.driver import AcceleratorDriver
from injector.fault_injector import FaultInjector


@pytest.fixture(scope="module")
def ref():
    with open("reference_outputs.json") as f:
        return json.load(f)


@pytest.fixture
def chip():
    return BehavioralChip()


# --- clean inference matches the INT8 reference ----------------------------

def test_clean_inference_matches_reference(chip, ref):
    drv = AcceleratorDriver(chip)
    drv.set_hardening(False)
    for entry in ref[:25]:
        drv.run_inference(bytes(entry["input_bytes"]))
        assert drv.read_result() == entry["expected_class"]


def test_done_bit_set_after_inference(chip):
    chip.stream_input(bytes(784))
    chip.write(CTRL, 0x01)
    assert chip.read(STATUS) & 0x02


def test_inferences_counter_increments(chip):
    for _ in range(3):
        chip.stream_input(bytes(784))
        chip.write(CTRL, 0x01)
    assert chip.read(INFERENCES_TOTAL) == 3


# --- fault injection geometry ----------------------------------------------

def test_mem_geometry_advertised(chip):
    assert chip.mem_geometry[0][1] == 8          # INT8 weight bytes
    assert chip.mem_geometry[0][0] == chip._n_weight_bytes


def test_injector_uses_chip_geometry(chip):
    fi = FaultInjector(chip, ber=1.0, seed=0)
    fi.tick(300)
    weight = [e for e in fi.log if e["mem_id"] == 0]
    assert weight, "expected some weight faults"
    assert all(0 <= e["addr"] < chip._n_weight_bytes for e in weight)
    assert all(0 <= e["bit_idx"] < 8 for e in weight)


def test_inject_flips_weight_byte(chip):
    before = chip._weight_mem[0]
    chip.inject_bit_flip(0, addr=0, bit_idx=2)
    assert chip._weight_mem[0] == (before ^ 0x04)
    assert chip.corrupted_weight_bytes == 1


# --- hardening model --------------------------------------------------------

def test_hardening_corrects_single_bit_and_counts_scrub(chip):
    chip.inject_bit_flip(0, addr=5, bit_idx=1)     # single-bit error
    chip.stream_input(bytes(784))
    chip.write(CTRL, 0x01 | (1 << 2))              # start + harden
    assert chip.read(SCRUB_CORRECTIONS) >= 1
    assert chip.corrupted_weight_bytes == 0        # healed back to golden


def test_unhardened_leaves_corruption(chip):
    chip.inject_bit_flip(0, addr=5, bit_idx=1)
    chip.stream_input(bytes(784))
    chip.write(CTRL, 0x01)                          # start, no harden
    assert chip.read(SCRUB_CORRECTIONS) == 0
    assert chip.corrupted_weight_bytes == 1


def test_double_bit_is_uncorrectable(chip):
    chip.inject_bit_flip(0, addr=7, bit_idx=0)
    chip.inject_bit_flip(0, addr=7, bit_idx=3)     # two bits in one byte
    chip.stream_input(bytes(784))
    chip.write(CTRL, 0x01 | (1 << 2))              # harden
    assert chip.read(ECC_DOUBLE_ERRORS) >= 1
    assert chip.corrupted_weight_bytes == 1        # left corrupted


def test_hardened_beats_unhardened_under_faults(ref):
    def accuracy(harden):
        chip = BehavioralChip()
        drv = AcceleratorDriver(chip)
        drv.set_hardening(harden)
        drv.set_scrubber(harden)
        inj = FaultInjector(chip, ber=0.1, seed=3)
        ok = 0
        for e in ref:
            inj.tick(2000)
            drv.run_inference(bytes(e["input_bytes"]))
            ok += drv.read_result() == e["expected_class"]
        return ok / len(ref)

    hardened = accuracy(True)
    baseline = accuracy(False)
    assert hardened > 0.95
    assert baseline < hardened


# --- event FIFO -------------------------------------------------------------

def test_event_pop_zero_when_empty(chip):
    assert chip.read(EVENT_POP) == 0


def test_event_pop_returns_packed_event(chip):
    chip.inject_bit_flip(0, addr=9, bit_idx=4)
    chip.stream_input(bytes(784))
    chip.write(CTRL, 0x01 | (1 << 2))
    val = chip.read(EVENT_POP)
    assert val != 0
    assert (val & 0x3) == 0                          # SCRUB_CORRECT
    assert ((val >> 2) & 0xFFFF) == 9                # addr


def test_reset_faults_restores_golden(chip):
    chip.inject_bit_flip(0, addr=3, bit_idx=5)
    assert chip.corrupted_weight_bytes == 1
    chip.reset_faults()
    assert chip.corrupted_weight_bytes == 0
