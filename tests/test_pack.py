import struct
import numpy as np
import pytest

ORDER = ["conv1_w", "conv1_b", "conv2_w", "conv2_b", "fc1_w", "fc1_b", "fc2_w", "fc2_b"]


@pytest.fixture(scope="module")
def arrays():
    return dict(np.load("model_int8.npz"))


@pytest.fixture(scope="module")
def bin_data():
    with open("weights.bin", "rb") as f:
        return f.read()


def test_file_exists():
    import os
    assert os.path.exists("weights.bin")


def test_total_size(arrays, bin_data):
    expected = sum(4 + arrays[n].nbytes for n in ORDER)
    assert len(bin_data) == expected


def test_tensor_order_and_lengths(arrays, bin_data):
    pos = 0
    for name in ORDER:
        n_bytes = struct.unpack_from("<I", bin_data, pos)[0]
        assert n_bytes == arrays[name].nbytes, f"{name}: length header wrong"
        pos += 4 + n_bytes


def test_length_headers_are_little_endian(bin_data):
    # first header is conv1_w: 8*1*3*3 = 72 bytes
    val = struct.unpack_from("<I", bin_data, 0)[0]
    assert val == 72


def test_all_values_deserialize_correctly(arrays, bin_data):
    pos = 0
    for name in ORDER:
        n_bytes = struct.unpack_from("<I", bin_data, pos)[0]
        pos += 4
        raw = np.frombuffer(bin_data[pos:pos + n_bytes], dtype=np.int8)
        assert np.array_equal(raw, arrays[name].flatten()), f"{name} roundtrip failed"
        pos += n_bytes


def test_arrays_are_c_order_flattened(arrays, bin_data):
    # read conv1_w (first tensor, offset 4) and confirm it matches C-order flatten
    n_bytes = struct.unpack_from("<I", bin_data, 0)[0]
    raw = np.frombuffer(bin_data[4:4 + n_bytes], dtype=np.int8)
    assert np.array_equal(raw, arrays["conv1_w"].flatten(order="C"))


def test_offsets_are_contiguous(arrays, bin_data):
    pos = 0
    for name in ORDER:
        n_bytes = struct.unpack_from("<I", bin_data, pos)[0]
        pos += 4 + n_bytes
    assert pos == len(bin_data), "trailing bytes in file"
