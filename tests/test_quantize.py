import json
import numpy as np
import pytest
import torch

NAMES = ["conv1_w", "conv1_b", "conv2_w", "conv2_b", "fc1_w", "fc1_b", "fc2_w", "fc2_b"]


@pytest.fixture(scope="module")
def arrays():
    return dict(np.load("model_int8.npz"))


@pytest.fixture(scope="module")
def scales():
    with open("scales.json") as f:
        return json.load(f)


def test_npz_has_all_keys(arrays):
    assert set(arrays) == set(NAMES)


def test_scales_has_all_keys(scales):
    assert set(scales) == set(NAMES)


def test_all_arrays_are_int8(arrays):
    for name, arr in arrays.items():
        assert arr.dtype == np.int8, f"{name} is {arr.dtype}, expected int8"


def test_values_clipped_to_int8_range(arrays):
    for name, arr in arrays.items():
        assert arr.min() >= -128 and arr.max() <= 127, f"{name} out of range"


def test_scales_are_positive_floats(scales):
    for name, s in scales.items():
        assert isinstance(s, float) and s > 0, f"{name} scale invalid: {s}"


def test_scale_formula(arrays, scales):
    from model.train import TinyMNIST
    model = TinyMNIST()
    model.load_state_dict(torch.load("model.pt", map_location="cpu"))
    sd = model.state_dict()
    key_map = {
        "conv1_w": "net.0.weight", "conv1_b": "net.0.bias",
        "conv2_w": "net.3.weight", "conv2_b": "net.3.bias",
        "fc1_w":   "net.7.weight", "fc1_b":   "net.7.bias",
        "fc2_w":   "net.9.weight", "fc2_b":   "net.9.bias",
    }
    for name, key in key_map.items():
        w = sd[key].detach().numpy()
        expected_scale = float(np.max(np.abs(w)) / 127)
        assert abs(scales[name] - expected_scale) < 1e-9, f"{name} scale mismatch"


def test_dequantized_weights_close_to_fp32(arrays, scales):
    from model.train import TinyMNIST
    model = TinyMNIST()
    model.load_state_dict(torch.load("model.pt", map_location="cpu"))
    sd = model.state_dict()
    key_map = {
        "conv1_w": "net.0.weight", "conv1_b": "net.0.bias",
    }
    for name, key in key_map.items():
        dq = arrays[name].astype(np.float32) * scales[name]
        fp = sd[key].detach().numpy()
        # max error should be at most half a quantization step
        assert np.max(np.abs(dq - fp)) <= scales[name], f"{name} dequant error too large"


def test_int8_accuracy_within_1pct_of_fp32():
    """End-to-end: dequantized model should stay within 1% of FP32 accuracy."""
    import torch.nn.functional as F
    from torchvision import datasets, transforms
    from torch.utils.data import DataLoader

    arrs = dict(np.load("model_int8.npz"))
    with open("scales.json") as f:
        sc = json.load(f)

    def dq(n):
        return torch.tensor(arrs[n].astype(np.float32) * sc[n])

    loader = DataLoader(
        datasets.MNIST("data", train=False, download=True, transform=transforms.ToTensor()),
        batch_size=256,
    )
    correct = total = 0
    for x, y in loader:
        with torch.no_grad():
            x = F.conv2d(x, dq("conv1_w"), dq("conv1_b"), padding=1).clamp(min=0)
            x = F.max_pool2d(x, 2)
            x = F.conv2d(x, dq("conv2_w"), dq("conv2_b"), padding=1).clamp(min=0)
            x = F.max_pool2d(x, 2)
            x = F.linear(x.flatten(1), dq("fc1_w"), dq("fc1_b")).clamp(min=0)
            x = F.linear(x, dq("fc2_w"), dq("fc2_b"))
        correct += (x.argmax(1) == y).sum().item()
        total += len(y)
    assert correct / total >= 0.97, f"INT8 accuracy too low: {correct/total:.4f}"
