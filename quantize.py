import json
import numpy as np
import torch
import torch.nn.functional as F
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
from train import TinyMNIST

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")


def quantize(tensor: torch.Tensor):
    arr = tensor.detach().cpu().numpy().astype(np.float32)
    scale = float(np.max(np.abs(arr)) / 127)
    q = np.clip(np.round(arr / scale), -128, 127).astype(np.int8)
    return q, scale


def get_test_loader():
    ds = datasets.MNIST("data", train=False, download=True, transform=transforms.ToTensor())
    return DataLoader(ds, batch_size=256)


def fp32_accuracy(model, loader):
    model.eval()
    correct = total = 0
    with torch.no_grad():
        for x, y in loader:
            x, y = x.to(DEVICE), y.to(DEVICE)
            correct += (model(x).argmax(1) == y).sum().item()
            total += len(y)
    return correct / total


def int8_accuracy(arrays, scales, loader):
    def dq(name):
        return torch.tensor(arrays[name].astype(np.float32) * scales[name])

    conv1_w, conv1_b = dq("conv1_w"), dq("conv1_b")
    conv2_w, conv2_b = dq("conv2_w"), dq("conv2_b")
    fc1_w,   fc1_b   = dq("fc1_w"),   dq("fc1_b")
    fc2_w,   fc2_b   = dq("fc2_w"),   dq("fc2_b")

    correct = total = 0
    for x, y in loader:
        with torch.no_grad():
            x = F.conv2d(x, conv1_w, conv1_b, padding=1).clamp(min=0)
            x = F.max_pool2d(x, 2)
            x = F.conv2d(x, conv2_w, conv2_b, padding=1).clamp(min=0)
            x = F.max_pool2d(x, 2)
            x = x.flatten(1)
            x = F.linear(x, fc1_w, fc1_b).clamp(min=0)
            x = F.linear(x, fc2_w, fc2_b)
        correct += (x.argmax(1) == y).sum().item()
        total += len(y)
    return correct / total


def main():
    model = TinyMNIST().to(DEVICE)
    model.load_state_dict(torch.load("model.pt", map_location=DEVICE))

    # extract and quantize
    sd = model.state_dict()
    pairs = [
        ("conv1_w", "net.0.weight"), ("conv1_b", "net.0.bias"),
        ("conv2_w", "net.3.weight"), ("conv2_b", "net.3.bias"),
        ("fc1_w",   "net.7.weight"), ("fc1_b",   "net.7.bias"),
        ("fc2_w",   "net.9.weight"), ("fc2_b",   "net.9.bias"),
    ]
    arrays, scales = {}, {}
    for name, key in pairs:
        arrays[name], scales[name] = quantize(sd[key])

    np.savez("model_int8.npz", **arrays)
    with open("scales.json", "w") as f:
        json.dump(scales, f, indent=2)

    # validate
    loader = get_test_loader()
    fp32 = fp32_accuracy(model, loader)
    int8 = int8_accuracy(arrays, scales, loader)
    print(f"FP32 accuracy: {fp32:.4f}")
    print(f"INT8 accuracy: {int8:.4f}")
    print(f"Drop:          {(fp32 - int8):.4f}")


if __name__ == "__main__":
    main()
