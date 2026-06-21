import json
import numpy as np
import pytest

KEYS = {"idx", "input_bytes", "expected_class", "post_conv1_int32", "post_conv2_int32",
        "post_fc1_int32", "logits_int32"}

EXPECTED_LENGTHS = {
    "input_bytes":      784,       # 28*28
    "post_conv1_int32": 6272,      # 8*28*28
    "post_conv2_int32": 3136,      # 16*14*14
    "post_fc1_int32":   32,
    "logits_int32":     10,
}


@pytest.fixture(scope="module")
def entries():
    with open("reference_outputs.json") as f:
        return json.load(f)


def test_entry_count(entries):
    assert len(entries) == 100


def test_indices_sequential(entries):
    assert [e["idx"] for e in entries] == list(range(100))


def test_all_keys_present(entries):
    for e in entries:
        assert set(e.keys()) == KEYS, f"idx {e['idx']} has wrong keys"


def test_list_lengths(entries):
    for e in entries:
        for field, expected_len in EXPECTED_LENGTHS.items():
            assert len(e[field]) == expected_len, \
                f"idx {e['idx']} {field}: expected {expected_len}, got {len(e[field])}"


def test_input_bytes_uint8_range(entries):
    for e in entries:
        arr = np.array(e["input_bytes"])
        assert arr.min() >= 0 and arr.max() <= 255, f"idx {e['idx']} input out of [0,255]"


def test_expected_class_valid(entries):
    for e in entries:
        assert 0 <= e["expected_class"] <= 9


def test_expected_class_matches_argmax_logits(entries):
    for e in entries:
        assert e["expected_class"] == int(np.argmax(e["logits_int32"])), \
            f"idx {e['idx']} class/logits mismatch"


def test_post_conv1_values_are_ints(entries):
    for e in entries[:5]:      # spot-check first 5
        assert all(isinstance(v, int) for v in e["post_conv1_int32"])


def test_intermediate_values_in_int32_range(entries):
    INT32_MIN, INT32_MAX = -(2**31), 2**31 - 1
    for e in entries:
        for field in ("post_conv1_int32", "post_conv2_int32", "post_fc1_int32", "logits_int32"):
            arr = np.array(e[field])
            assert arr.min() >= INT32_MIN and arr.max() <= INT32_MAX, \
                f"idx {e['idx']} {field} overflows int32"


def test_accuracy_above_90pct(entries):
    from torchvision import datasets, transforms
    ds = datasets.MNIST("data", train=False, download=True, transform=transforms.ToTensor())
    true_labels = [int(ds[i][1]) for i in range(100)]
    correct = sum(e["expected_class"] == t for e, t in zip(entries, true_labels))
    assert correct / 100 >= 0.90, f"INT8 reference accuracy too low: {correct}%"


def test_class_distribution_sums_to_100(entries):
    assert sum(1 for e in entries) == 100
    preds = [e["expected_class"] for e in entries]
    from collections import Counter
    assert sum(Counter(preds).values()) == 100
