# Bilder

A Phoenix LiveView app for generating images locally with
[Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1): type a prompt (optionally with reference
images to generate from/with), watch it generate, view the result. No external API keys — inference runs on
your own GPU via a small local Python service that this app starts and manages for you.

## Setup

1. **One-time**: set up the Python inference environment —

   ```bash
   cd python_inference && ./setup.sh
   ```

   Installs `torch`/`torchvision`/`diffusers`/etc. into an isolated venv and checks Hugging Face auth. See
   [`python_inference/README.md`](python_inference/README.md) for details and troubleshooting.

2. **Every time**: just run the Phoenix app —

   ```bash
   mix setup   # installs deps and assets; skips fine if you don't have Postgres running, it isn't used yet
   mix phx.server
   ```

   `mix phx.server` also starts `python_inference/server.py` for you (see `Bilder.QwenService`) and stops it
   on shutdown. Visit [`localhost:4000`](http://localhost:4000) — the page shows "starting up" while the
   model loads (first run downloads it, which takes a while), then enter a prompt and hit Generate.

If the inference service runs on another machine instead, set `QWEN_AUTOSTART=false` so this app doesn't
also try to start its own copy, and point it at the other one:

```bash
QWEN_AUTOSTART=false QWEN_SERVICE_URL=http://your-host:8000 mix phx.server
```

## Synthetic face images

A harness generates synthetic mugshots, ICAO passport portraits and mated probe images of
fictional people for ABIS testing. Each person gets a frontal mugshot generated from a seeded text
description, and every other shot is generated from that frontal image to keep the identity consistent.

Start and browse runs at [`localhost:4000/faces`](http://localhost:4000/faces), or from the command line:

```bash
mix biometrics.faces --subjects 5 --seed 42   # needs `mix phx.server` running for the Qwen service
```

Images, metadata and an `index.html` contact sheet are written to `data/synthetic/faces/<run>/`. The same seed
reproduces the same people, and reusing `--run` resumes a run. The output is synthetic test data only; don't use
it as evidence of matching accuracy or send it to live systems.

More detail: [docs/synthetic-faces.md](docs/synthetic-faces.md). The wider plan, which also covers
fingerprints, palms, a LiveView and S3 storage, is in
[docs/synthetic-biometrics-plan.md](docs/synthetic-biometrics-plan.md).

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
