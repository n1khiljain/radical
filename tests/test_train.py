import torch
import torch.nn as nn
import sys, os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from model.train import TinyMNIST, evaluate


@torch.no_grad()
def _dummy_loader(n=64, batch=32):
    """Two batches of random 28x28 images with labels 0-9."""
    dataset = [(torch.randn(batch, 1, 28, 28), torch.randint(0, 10, (batch,))) for _ in range(n // batch)]
    return dataset


def test_param_count_under_50k():
    model = TinyMNIST()
    n = sum(p.numel() for p in model.parameters())
    assert n <= 50_000, f"{n:,} params exceeds 50K hardware limit"


def test_output_shape():
    model = TinyMNIST()
    x = torch.randn(4, 1, 28, 28)
    out = model(x)
    assert out.shape == (4, 10)


def test_no_batchnorm_no_fancy_activations():
    model = TinyMNIST()
    for module in model.modules():
        assert not isinstance(module, nn.BatchNorm2d), "BatchNorm not allowed"
        assert not isinstance(module, (nn.Sigmoid, nn.Tanh, nn.GELU, nn.SiLU)), \
            f"{type(module).__name__} not allowed — ReLU only"


def test_only_relu_activations():
    model = TinyMNIST()
    activations = [m for m in model.modules() if isinstance(m, (nn.ReLU, nn.LeakyReLU, nn.ELU))]
    assert all(isinstance(a, nn.ReLU) for a in activations)


def test_forward_no_crash():
    model = TinyMNIST()
    model.eval()
    with torch.no_grad():
        out = model(torch.zeros(1, 1, 28, 28))
    assert out.shape == (1, 10)


def test_logits_not_softmaxed():
    """CrossEntropyLoss expects raw logits; make sure we're not applying softmax."""
    model = TinyMNIST()
    with torch.no_grad():
        out = model(torch.randn(8, 1, 28, 28))
    # raw logits can be negative and won't sum to 1
    assert not torch.allclose(out.softmax(-1).sum(-1), out.sum(-1))


def test_evaluate_returns_float_in_range():
    model = TinyMNIST()
    acc = evaluate(model, _dummy_loader())
    assert 0.0 <= acc <= 1.0


def test_backward_pass():
    model = TinyMNIST()
    x = torch.randn(4, 1, 28, 28)
    y = torch.randint(0, 10, (4,))
    loss = nn.CrossEntropyLoss()(model(x), y)
    loss.backward()
    grads = [p.grad for p in model.parameters() if p.grad is not None]
    assert len(grads) > 0, "no gradients flowed"
