# Qwen-Image-2.1 inference service

A small FastAPI wrapper around [`Qwen/Qwen-Image-2.1`](https://huggingface.co/Qwen/Qwen-Image-2.1) that the
Phoenix app talks to over HTTP on `localhost:8000`. Runs the model locally on your GPU — no external API keys.

## Requirements

- An NVIDIA GPU with CUDA. Tested against a 24GB card (RTX 4090); the model is loaded with
  `enable_model_cpu_offload()` so it fits in ~16GB of VRAM plus system RAM.
- Python 3.10+, with its `venv` module available (on Debian/Ubuntu, that's the `python3-venv` package —
  `apt install python3-venv` if `./setup.sh` reports it's missing).
- A Hugging Face account. `Qwen/Qwen-Image-2.1` isn't gated, so no license click-through is needed, but a
  token still raises your download rate limit — get one at https://huggingface.co/settings/tokens.

## Setup

```bash
cd python_inference
./setup.sh
```

This creates `.venv`, installs `torch`/`torchvision` matching your CUDA driver (defaults to the `cu121`
build — override with `TORCH_INDEX_URL=... ./setup.sh` if you need a different one, or `PYTHON=/path/to/python3
./setup.sh` to pick the interpreter it builds the venv from), then the rest of `requirements.txt`, and
verifies the install (including that `torchvision` is present — `Qwen3VLVideoProcessor`, part of this
model's pipeline, fails at load time without it even though nothing else in requirements.txt pulls it in).
Safe to re-run.

It also checks for a Hugging Face token, read from the standard `~/.cache/huggingface/token` location (or
`HF_TOKEN`). If none is found, log in once with:

```bash
.venv/bin/python -m huggingface_hub.commands.huggingface_cli login
```

## Run

Once the one-time setup above is done, you don't need to run this yourself: `mix phx.server` starts this
process automatically (see `Bilder.PythonService`) and stops it when the app shuts down. It looks for
`python_inference/.venv/bin/python`, falling back to `python3` on your `PATH` with a warning if the venv
isn't there yet.

To run it standalone (e.g. to watch its logs directly, or debug it independently of Phoenix), first set
`QWEN_AUTOSTART=false` when starting the Phoenix app so the two don't both try to bind port 8000, then:

```bash
python server.py
```

The first request triggers a ~15-20GB download of model weights from Hugging Face, then loads them onto the
GPU in the background. Check readiness with:

```bash
curl http://localhost:8000/health
```

`{"status": "ready", ...}` means the Phoenix app's "Generate" button will work. While loading you'll see
`{"status": "loading", ...}` and `/generate` requests return `503` until it's ready — the Phoenix UI polls
this and shows the same status.

## API

`POST /generate` as `multipart/form-data` with fields:

- `prompt` (required)
- `width`, `height` — default 1024×1024
- `steps` — default 40
- `seed` — optional, omit for a random seed
- `images` — optional, up to 10 image files, for image-conditioned generation/editing (put the subject(s) or
  scene you want the model to work from here, described in the prompt)

Returns the generated image as `image/png` bytes, with the seed that was actually used in the `X-Seed`
response header (useful for reproducing a result when you didn't pass one).

## Configuration

- `QWEN_IMAGE_MODEL` — override the model repo id (default `Qwen/Qwen-Image-2.1`).
- `QWEN_VAE_TILING_MIN_PIXELS` — images larger than this (default 2,000,000 px) are VAE-decoded in tiles to save VRAM; smaller ones decode in one pass, which avoids faint tile seams.
- `HOST` / `PORT` — bind address (default `127.0.0.1:8000`). If you change the port, also set
  `QWEN_SERVICE_URL` for the Phoenix app (see the main README).
