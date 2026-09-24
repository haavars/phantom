# Phantom

A Phoenix LiveView app that generates synthetic biometric test data: fictional people with consistent faces,
fingerprints, palmprints and tenprint cards, for testing ABIS and other biometric systems. No external API
keys. Faces come from [Qwen-Image-2.1](https://huggingface.co/Qwen/Qwen-Image-2.1) and friction ridges from
a local ridge generator, both running as small local Python services that this app starts and manages for you.

## Setup

1. **One-time**: set up the Python inference environment —

   ```bash
   cd python_inference && ./setup.sh
   ```

   Installs `torch`/`torchvision`/`diffusers`/etc. into an isolated venv and checks Hugging Face auth. See
   [`python_inference/README.md`](python_inference/README.md) for details and troubleshooting.

2. **Every time**: just run the Phoenix app —

   ```bash
   mix setup   # installs deps and assets, creates and migrates the Postgres database
   mix phx.server
   ```

   `mix phx.server` also starts `python_inference/server.py` for you (see `Phantom.Services.PythonProcess`) and stops it
   on shutdown. Visit [`localhost:4000`](http://localhost:4000), which opens the biometrics page. The first
   run downloads the face model, which takes a while.

If the inference service runs on another machine instead, set `QWEN_AUTOSTART=false` so this app doesn't
also try to start its own copy, and point it at the other one:

```bash
QWEN_AUTOSTART=false QWEN_SERVICE_URL=http://your-host:8000 mix phx.server
```

## Synthetic biometrics

Each run generates synthetic subjects, fictional people:

- **Faces:** mugshots, ICAO portraits and mated probe images, from Qwen-Image-2.1.
- **Friction ridges:** rolled fingerprints, slaps, full and writer's palms, and an FD-249 style tenprint card,
  from a procedural CPU generator in [`python_biometrics/`](python_biometrics/README.md). Run its one-time
  setup first: `cd python_biometrics && ./setup.sh`.

All images of one subject show the same person, fingers and palms, and extra captures give mated pairs.

Start and browse runs at [`localhost:4000/biometrics`](http://localhost:4000/biometrics), or from IEx attached to
the running app (`iex -S mix phx.server`):

```elixir
Phantom.Biometrics.create_run(%{subjects: 5, shots: ["faces", "rolled", "slaps", "palms", "card"], captures: 2})
```

Runs are queued and rendered one subject at a time by [Oban](https://oban.hexdocs.pm) jobs.
Runs, subjects, images and their ground truth are stored in Postgres; the image files are written to
`data/synthetic/biometrics/<run>/<subject>/`. The same seed reproduces the same subjects, and reusing `--run`
resumes a run. The output is synthetic test data
only; don't use it as evidence of matching accuracy or send it to live systems.

More detail: [docs/synthetic-biometrics.md](docs/synthetic-biometrics.md). The wider plan is in
[docs/synthetic-biometrics-plan.md](docs/synthetic-biometrics-plan.md).

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
