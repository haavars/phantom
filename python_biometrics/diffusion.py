"""Diffusion renderer: realistic ink texture over a capture's ridges.

The procedural renderer's prints are geometrically right but look drawn:
even ridges, smooth edges, uniform ink. This renderer takes the procedural
image of a capture and runs it part-way through IMPOSE's rolled-fingerprint
latent diffusion model (Pan et al., Tsinghua; Apache 2.0), which was trained on
real rolled prints. This is SDEdit: noise the image to `STRENGTH` of the way,
then denoise it with the model. The ridge flow and minutiae survive, while the
model replaces the texture with its own: ragged ridge edges, pores, uneven
inking, broken contact at the edges.

Diffusion can still move or invent minutiae, so every image is verified
(verify.py) and re-rendered with a new seed when it drifts. At strength 0.35
about 97% of attempts pass; higher strengths look more worn but drift more.

The model is unconditional, so there is one acquisition style: inked rolled.
It needs a CUDA GPU and the optional install (`./setup.sh --diffusion`), which
puts IMPOSE, taming-transformers and the checkpoint in tools/.
"""

import os
import sys
import threading
from pathlib import Path

import numpy as np

TOOLS = Path(__file__).resolve().parent / "tools"
IMPOSE = TOOLS / "impose"
CONFIG = IMPOSE / "configs" / "fingerprint-ldm-vq-128-512-rolled.yaml"
CHECKPOINT = Path(os.environ.get("IMPOSE_CHECKPOINT", IMPOSE / "models" / "fingerprint_ldm_rolled_512" / "model_ldm_rolled.ckpt"))
NAME = "diffusion/impose-rolled-sdedit"

STRENGTH = 0.35  # share of the diffusion trajectory re-run: texture changes, ridges stay
STEPS = 50  # DDIM steps for the full trajectory; STRENGTH * STEPS actually run

_model = None
_sampler = None
_load_lock = threading.Lock()


def available():
    """True when the code, checkpoint, torch and a CUDA GPU are all there."""
    if not (CONFIG.exists() and CHECKPOINT.exists() and (TOOLS / "taming-src").exists()):
        return False
    try:
        import torch
    except ImportError:
        return False
    return torch.cuda.is_available()


def unavailable_reason():
    if not (CONFIG.exists() and CHECKPOINT.exists()):
        return "the diffusion renderer isn't installed (run python_biometrics/setup.sh --diffusion)"
    try:
        import torch
    except ImportError:
        return "torch isn't installed in the service's venv (run python_biometrics/setup.sh --diffusion)"
    if not torch.cuda.is_available():
        return "the diffusion renderer needs a CUDA GPU"
    return None


def render(procedural, seed, strength=STRENGTH):
    """Re-texture a procedural 8-bit grey image. Deterministic for a given `seed`."""
    import torch

    model, sampler = load()
    h, w = procedural.shape
    padded = np.pad(procedural, ((0, -h % 16), (0, -w % 16)), constant_values=255)
    x = torch.from_numpy((padded / 127.5 - 1).astype(np.float32))[None, None].cuda()
    t_enc = max(1, int(strength * STEPS))
    with torch.no_grad(), torch.autocast("cuda"), model.ema_scope():
        z = model.get_first_stage_encoding(model.encode_first_stage(x))
        sampler.make_schedule(ddim_num_steps=STEPS, ddim_eta=0.0, verbose=False)
        # DDIM with eta 0 is deterministic after the initial noise, which comes from this seed.
        torch.manual_seed(seed)
        noisy = sampler.stochastic_encode(z, torch.tensor([t_enc], device="cuda"))
        z = sampler.decode(noisy, None, t_enc)
        out = model.decode_first_stage(z)
    image = ((torch.clamp((out + 1) / 2, 0, 1)[0, 0].float().cpu().numpy()) * 255).round().astype(np.uint8)
    del x, z, noisy, out
    torch.cuda.empty_cache()  # the GPU is shared with the Qwen face service
    return image[:h, :w]


def load():
    global _model, _sampler
    with _load_lock:
        if _model is None:
            _model, _sampler = _load()
    return _model, _sampler


def _load():
    import torch
    from omegaconf import OmegaConf

    for path in (IMPOSE, TOOLS / "taming-src"):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))

    from ldm.models.diffusion.ddim import DDIMSampler
    from ldm.modules.diffusionmodules import model as blocks
    from ldm.modules.diffusionmodules import openaimodel
    from ldm.util import instantiate_from_config

    blocks.AttnBlock.forward = _attention
    openaimodel.QKVAttentionLegacy.forward = _qkv_attention
    model = instantiate_from_config(OmegaConf.load(CONFIG).model)
    state = torch.load(CHECKPOINT, map_location="cpu", weights_only=False)["state_dict"]
    model.load_state_dict(state, strict=False)
    model = model.cuda().eval()
    return model, _Quiet(DDIMSampler(model))


def _attention(self, x):
    """The autoencoder's spatial self-attention, via memory-efficient SDPA.

    The original materialises the full (h*w)^2 attention matrix, about 18 GB for
    a rolled print; SDPA computes the same thing in a few hundred MB.
    """
    import torch.nn.functional as F

    h = self.norm(x)
    q, k, v = self.q(h), self.k(h), self.v(h)
    b, c, height, width = q.shape
    # The fused kernels need contiguous (batch, heads, tokens, channels) inputs;
    # anything else silently falls back to the materialising one.
    q, k, v = (t.reshape(b, 1, c, height * width).transpose(2, 3).contiguous() for t in (q, k, v))
    out = F.scaled_dot_product_attention(q, k, v)
    out = out.transpose(2, 3).reshape(b, c, height, width)
    return x + self.proj_out(out)


def _qkv_attention(self, qkv):
    """The UNet's multi-head attention, via SDPA for the same reason: 6 GB less on a slap."""
    import torch.nn.functional as F

    bs, width, length = qkv.shape
    ch = width // (3 * self.n_heads)
    q, k, v = qkv.reshape(bs, self.n_heads, 3 * ch, length).split(ch, dim=2)
    q, k, v = (t.transpose(2, 3).contiguous() for t in (q, k, v))
    out = F.scaled_dot_product_attention(q, k, v)
    return out.transpose(2, 3).reshape(bs, -1, length)


class _Quiet:
    """DDIMSampler without its per-call progress bars on stdout."""

    def __init__(self, sampler):
        self._sampler = sampler

    def __getattr__(self, name):
        return getattr(self._sampler, name)

    def decode(self, *args, **kwargs):
        import contextlib
        import io

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return self._sampler.decode(*args, **kwargs)
