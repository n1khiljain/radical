import struct
import numpy as np
import pytest

ORDER = ["conv1_w", "conv1_b", "conv2_w", "conv2_b", "fc1_w", "fc1_b", "fc2_w", "fc2_b"]


@pytest.fixture(scope="module")
def arrays():
    return dict(np.load("model_int8.npz"))


@pytest.fixture(scope="module")
def raw():
    with open("weights.bin", "rb") as f:
        return f.read()


def test_total_file_size(arrays, raw):
    expected = sum(4 + arrays[n].nbytes for n in ORDER)
    assert len(raw) == expected


def test_first_header_is_conv1_w_size(arrays, raw):
    n = struct.unpack_from("<I", raw, 0)[0]
    assert n == arrays["conv1_w"].nbytes


def test_all_headers_little_endian_and_correct(arrays, raw):
    pos = 0
    for name in ORDER:
        n = struct.unpack_from("<I", raw, pos)[0]
        assert n == arrays[name].nbytes, f"{name}: header {n} != {arrays[name].nbytes}"
        pos += 4 + n


def test_roundtrip_all_tensors(arrays, raw):
    pos = 0
    for name in ORDER:
        n = struct.unpack_from("<I", raw, pos)[0]
        pos += 4
        got = np.frombuffer(raw[pos:pos + n], dtype=np.int8)
        want = arrays[name].flatten(order="C")
        assert np.array_equal(got, want), f"{name} roundtrip mismatch"
        pos += n


def test_c_order_flatten(arrays, raw):
    n = struct.unpack_from("<I", raw, 0)[0]
    got = np.frombuffer(raw[4:4 + n], dtype=np.int8)
    assert np.array_equal(got, arrays["conv1_w"].flatten(order="C"))


def test_no_trailing_bytes(arrays, raw):
    pos = sum(4 + arrays[n].nbytes for n in ORDER)
    assert pos == len(raw)


def test_all_values_int8_range(raw):
    pos = 0
    while pos < len(raw):
        n = struct.unpack_from("<I", raw, pos)[0]
        pos += 4
        chunk = np.frombuffer(raw[pos:pos + n], dtype=np.int8)
        assert chunk.min() >= -128 and chunk.max() <= 127
        pos += n
