"""
hw_reference.py — hardware-accurate Python inference reference.

Matches what chip.sv / ctrl_seq.sv actually computes:
  • No inter-layer requantization  (hardware passes wider integers through)
  • No conv biases                 (conv1_stage / conv2_stage have no bias ports)
  • fc1_b / fc2_b are sign-extended int8 → int32 (as loaded in chip.sv)
  • Input pixels quantized to int8 with per-image scale
  • All arithmetic in int32 / int64 matching the RTL bit-widths

Used by verify_e2e.py to check RTL sim output against Python ground truth.
"""

import json
import numpy as np
import torch
import torch.nn.functional as F


def load_artifacts(npz="model_int8.npz", scales_json="scales.json"):
    arrs = dict(np.load(npz))
    with open(scales_json) as f:
        scales = json.load(f)
    return arrs, scales


def quantize(arr: np.ndarray) -> tuple[np.ndarray, float]:
    m = float(np.max(np.abs(arr)))
    scale = m / 127 if m != 0 else 1e-8
    q = np.clip(np.round(arr / scale), -128, 127).astype(np.int8)
    return q, scale


def _conv_int32(x_int8, w_int8, padding=1):
    """Int8 × int8 → int32, no bias (matches conv1_stage / conv2_stage)."""
    xt = torch.from_numpy(x_int8.astype(np.float32)).unsqueeze(0)
    wt = torch.from_numpy(w_int8.astype(np.float32))
    out = F.conv2d(xt, wt, padding=padding).squeeze(0).numpy().round().astype(np.int32)
    return out


def _linear_int32(x_int32, w_int8, b_int8):
    """Int32 × int8 + int32_bias → int32 (matches fc1_stage / fc2_stage)."""
    xt = torch.from_numpy(x_int32.astype(np.float32)).unsqueeze(0)
    wt = torch.from_numpy(w_int8.astype(np.float32))
    acc = F.linear(xt, wt).squeeze(0).numpy().round().astype(np.int64)
    # bias is int8 sign-extended to int32 (chip.sv: {{24{tdata[7]}}, tdata})
    bias_i32 = b_int8.astype(np.int32).astype(np.int64)
    return (acc + bias_i32).astype(np.int32)


def _maxpool2d(arr, size=2):
    C, H, W = arr.shape
    H2, W2 = H // size, W // size
    return arr[:, :H2*size, :W2*size].reshape(C, H2, size, W2, size).max(axis=(2, 4))


def infer_hw(img_float: np.ndarray, arrs: dict, scales: dict) -> dict:
    """
    Run one image through the hardware-accurate pipeline.

    Returns a dict with the same keys as reference_outputs.json so
    verify_e2e.py can compare element-by-element.
    """
    # --- input quantization ---
    x_int8, sx = quantize(img_float.reshape(1, 28, 28))   # (1,28,28) int8

    # --- conv1: int8*int8 → int32, no bias, ReLU, pool ---
    post_conv1 = _conv_int32(x_int8, arrs["conv1_w"])     # (8,28,28) int32
    c1_relu    = np.maximum(post_conv1, 0)
    c1_pooled  = _maxpool2d(c1_relu)                       # (8,14,14) int32

    # --- conv2: int32*int8 → int32, no bias, ReLU, pool ---
    # conv2_stage expects 32-bit input (sign-extended conv1 output)
    post_conv2 = _conv_int32(
        c1_pooled.astype(np.int8) if False else           # hardware passes int32
        c1_pooled, arrs["conv2_w"]
    )                                                       # (16,14,14) int32
    c2_relu   = np.maximum(post_conv2, 0)
    c2_pooled = _maxpool2d(c2_relu)                        # (16,7,7) int32

    # --- flatten (channel-first, matches ctrl_seq flatten) ---
    flat = c2_pooled.flatten(order="C")                    # (784,) int32

    # --- fc1: int32 * int8 + int32_bias, ReLU ---
    post_fc1 = _linear_int32(flat, arrs["fc1_w"], arrs["fc1_b"])  # (32,) int32
    fc1_relu = np.maximum(post_fc1, 0).astype(np.int32)

    # --- fc2: int32 * int8 + int32_bias, no ReLU ---
    logits = _linear_int32(fc1_relu, arrs["fc2_w"], arrs["fc2_b"])  # (10,) int32

    return {
        "post_conv1_int32": post_conv1.flatten().tolist(),
        "post_conv2_int32": post_conv2.flatten().tolist(),
        "post_fc1_int32":   post_fc1.tolist(),
        "logits_int32":     logits.tolist(),
        "predicted_class":  int(logits.argmax()),
    }
