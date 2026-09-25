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
   on shutdown. Visit [`localhost:4000`](http://localhost:4000) for the overview and gallery, and **Runs** to start
   one. The first run downloads the face model, which takes a while.

If the inference service runs on another machine instead, set `QWEN_AUTOSTART=false` so this app doesn't
also try to start its own copy, and point it at the other one:

```bash
QWEN_AUTOSTART=false QWEN_SERVICE_URL=http://your-host:8000 mix phx.server
```

## Synthetic biometrics

Each run generates synthetic subjects, fictional people:

- **Faces:** mugshots, ICAO portraits and mated probe images (re-booked, aged, with glasses, changed
  appearance, low resolution, each with its own slight pose and expression), from Qwen-Image-2.1.
- **Friction ridges:** rolled fingerprints, slaps, full and writer's palms, and an FD-249 style tenprint card,
  from the ridge generator in [`python_biometrics/`](python_biometrics/README.md): patterns on the CPU, rendered
  as realistic ink prints by a diffusion model (or procedurally, as a fast CPU draft) and verified against their
  ground truth with NIST tools. Run its one-time setup first: `cd python_biometrics && ./setup.sh --diffusion`
  (leave out `--diffusion` without an NVIDIA GPU).

All images of one subject show the same person, fingers and palms, and extra captures give mated pairs. A run
can fix any appearance trait for all of its people (sex, age range, ancestry, hair, clothing, …) and leave the
rest random per person.

Start and browse runs at [`localhost:4000/biometrics`](http://localhost:4000/biometrics), or from IEx attached to
the running app (`iex -S mix phx.server`):

```elixir
Phantom.Biometrics.create_run(%{subjects: 5, shots: ["faces", "rolled", "slaps", "palms", "card"], captures: 2})
Phantom.Biometrics.create_run(%{subjects: 10, traits: %{sex: "female", ancestry: "Northern European"}})
```

Runs are queued and rendered one subject at a time by [Oban](https://oban.hexdocs.pm) jobs. Runs, subjects,
images and their ground truth are stored in Postgres; the image files are written to
`data/synthetic/biometrics/<run>/<subject>/`. The same seed reproduces the same subjects, **Resume** re-renders
anything missing (including deleted files) from the stored seeds and prompts, and **Add shots** adds shots to an
existing run.

Each person downloads as a ZIP from their page: PNG images named by pose code or FGP/PLP, ground truth per
print, and a `subject.json` manifest with seeds, prompts and SHA-256 hashes
(`GET /biometrics/<run>/<subject>/download`).

For loading into an ABIS, **Download → NIST (.an2)** on a person's page opens the NIST export
(`/biometrics/<run>/<subject>/nist`): ANSI/NIST-ITL 1-2011 Update:2015 transactions in Traditional encoding.
The enrolment holds prints and face, prints only or face only; face probes (aged, changed appearance, …) can be
added as search transactions; prints are PNG or WSQ (WSQ needs `python_biometrics/setup.sh`, which builds NIST's
`cwsq`). See [docs/nist-export-plan.md](docs/nist-export-plan.md).

The output is synthetic test data only; don't use it as evidence of matching accuracy or send it to live
systems.

More detail: [docs/synthetic-biometrics.md](docs/synthetic-biometrics.md). The wider plan is in
[docs/synthetic-biometrics-plan.md](docs/synthetic-biometrics-plan.md), the fingerprint realism work in
[docs/realistic-fingerprints-plan.md](docs/realistic-fingerprints-plan.md), conditioning faces on open datasets in
[docs/face-source-conditioning-plan.md](docs/face-source-conditioning-plan.md), and what resolution faces and prints
should have in [docs/image-resolution.md](docs/image-resolution.md). How colleagues reach the app over Tailscale
is in [docs/remote-access.md](docs/remote-access.md).
