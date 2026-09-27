"""Step 2: sample separated identities from the pool's distribution (Arc2Face's ArcFace space) and render each
with Arc2Face, several samples per identity.

    python arc2face_faces.py RUN [--samples 8] [--guidance 3.0] [--temperature 1.0]

Identities are drawn from a Gaussian with the pool's mean and covariance (scaled by the temperature), each kept
below 0.1 to the others and below 0.3 to every pool face. With the default seed they're the pilot's 12.
Writes RUN/ids.npy and RUN/a2f_<identity>_<sample>.png (512²).
"""
import argparse
import os
import sys

import numpy as np
import torch

from common import ARC2FACE, WORK, run_dir

sys.path.insert(0, ARC2FACE)
from arc2face import CLIPTextModelWrapper, project_face_embs  # noqa: E402
from diffusers import AutoencoderKL, DPMSolverMultistepScheduler, StableDiffusionPipeline, UNet2DConditionModel  # noqa: E402

p = argparse.ArgumentParser()
p.add_argument("run")
p.add_argument("--count", type=int, default=12)
p.add_argument("--samples", type=int, default=8)
p.add_argument("--guidance", type=float, default=3.0)
p.add_argument("--steps", type=int, default=25)
p.add_argument("--temperature", type=float, default=1.0)
p.add_argument("--seed", type=int, default=20260927)
args = p.parse_args()

pool = np.load(os.path.join(WORK, "pool_a2f.npy")).astype(np.float64)
mu, cov = pool.mean(0), np.cov(pool, rowvar=False) * args.temperature ** 2
rng = np.random.default_rng(args.seed)
ids = []
while len(ids) < args.count:
    x = rng.multivariate_normal(mu, cov)
    x /= np.linalg.norm(x)
    if all(x @ y < 0.1 for y in ids) and (pool @ x).max() < 0.3:
        ids.append(x)
ids = np.stack(ids).astype(np.float32)
np.save(run_dir(args.run, "ids.npy"), ids)

base = "stable-diffusion-v1-5/stable-diffusion-v1-5"
models = os.path.join(ARC2FACE, "models")
pipe = StableDiffusionPipeline.from_pretrained(
    base,
    text_encoder=CLIPTextModelWrapper.from_pretrained(models, subfolder="encoder", torch_dtype=torch.float16),
    unet=UNet2DConditionModel.from_pretrained(models, subfolder="arc2face", torch_dtype=torch.float16),
    vae=AutoencoderKL.from_pretrained(base, subfolder="vae", variant="fp16", torch_dtype=torch.float16),
    torch_dtype=torch.float16, safety_checker=None, requires_safety_checker=False,
)
pipe.scheduler = DPMSolverMultistepScheduler.from_config(pipe.scheduler.config)
pipe = pipe.to("cuda")
pipe.set_progress_bar_config(disable=True)
for i, x in enumerate(ids):
    emb = project_face_embs(pipe, torch.tensor(x, dtype=torch.float16)[None].cuda())
    for j in range(args.samples):
        g = torch.Generator("cuda").manual_seed(i * 100 + j)
        im = pipe(prompt_embeds=emb, num_inference_steps=args.steps, guidance_scale=args.guidance, generator=g).images[0]
        im.save(run_dir(args.run, f"a2f_{i + 1:02d}_{j}.png"))
    print("identity", i + 1, flush=True)
