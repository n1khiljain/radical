import json
import numpy as np
import torch
import torch.nn.functional as F
from torchvision import datasets, transforms
from collections import Counter


def load_artifacts():
    arrays = dict(np.load("model_int8.npz"))
    with open("scales.json") as f:
        scales = json.load(f)
    return arrays, scales


def quantize(arr):
    m = float(np.max(np.abs(arr)))
    scale = m / 127 if m != 0 else 1e-8
    q = np.clip(np.round(arr / scale), -128, 127).astype(np.int8)
    return q, scale


def conv_int32(x, w, b, padding=1):
    # float32 is exact for int8 inputs (max sum < 2^24 for all layers here)
    xt = torch.from_numpy(x.astype(np.float32)).unsqueeze(0)
    wt = torch.from_numpy(w.astype(np.float32))
    out = F.conv2d(xt, wt, padding=padding).squeeze(0).numpy().round().astype(np.int32)
    return out + b.astype(np.int32)[:, None, None]


def linear_int32(x, w, b):
    xt = torch.from_numpy(x.astype(np.float32)).unsqueeze(0)
    wt = torch.from_numpy(w.astype(np.float32))
    out = F.linear(xt, wt).squeeze(0).numpy().round().astype(np.int32)
    return out + b.astype(np.int32)


def maxpool(arr, size=2):
    C, H, W = arr.shape
    H2, W2 = H // size, W // size
    return arr[:, :H2*size, :W2*size].reshape(C, H2, size, W2, size).max(axis=(2, 4))


def relu_pool_requantize(int32_arr, combined_scale):
    f = np.maximum(int32_arr.astype(np.float32) * combined_scale, 0)
    return quantize(maxpool(f))


def infer(img_float, arrs, scales):
    x, sx = quantize(img_float.reshape(1, 28, 28))

    post_conv1 = conv_int32(x, arrs["conv1_w"], arrs["conv1_b"])           # (8,28,28) int32
    x2, sx2 = relu_pool_requantize(post_conv1, sx * scales["conv1_w"])

    post_conv2 = conv_int32(x2, arrs["conv2_w"], arrs["conv2_b"])           # (16,14,14) int32
    x3, sx3 = relu_pool_requantize(post_conv2, sx2 * scales["conv2_w"])

    post_fc1 = linear_int32(x3.flatten(), arrs["fc1_w"], arrs["fc1_b"])     # (32,) int32
    f3 = np.maximum(post_fc1.astype(np.float32) * (sx3 * scales["fc1_w"]), 0)
    x4, _ = quantize(f3)

    logits = linear_int32(x4, arrs["fc2_w"], arrs["fc2_b"])                 # (10,) int32

    return post_conv1, post_conv2, post_fc1, logits


def main():
    arrs, scales = load_artifacts()
    ds = datasets.MNIST("data", train=False, download=True, transform=transforms.ToTensor())

    results, preds, trues = [], [], []
    for idx in range(100):
        img, label = ds[idx]
        img_f = img.numpy().squeeze()                               # (28,28) float [0,1]
        raw = (img_f * 255).round().astype(np.uint8)

        pc1, pc2, pf1, logits = infer(img_f, arrs, scales)
        pred = int(logits.argmax())

        results.append({
            "idx": idx,
            "input_bytes": raw.flatten().tolist(),
            "expected_class": pred,
            "post_conv1_int32": pc1.flatten().tolist(),
            "post_conv2_int32": pc2.flatten().tolist(),
            "post_fc1_int32": pf1.tolist(),
            "logits_int32": logits.tolist(),
        })
        preds.append(pred)
        trues.append(int(label))

    with open("reference_outputs.json", "w") as f:
        json.dump(results, f)

    acc = sum(p == t for p, t in zip(preds, trues)) / 100
    print("Predicted class distribution:", dict(sorted(Counter(preds).items())))
    print(f"Accuracy on first 100: {acc:.0%}")


if __name__ == "__main__":
    main()
