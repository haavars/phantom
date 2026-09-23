# Synthetic face images

A harness that generates synthetic **mugshots, ICAO passport portraits and mated probe images** of fictional
people with the local Qwen-Image-2.1 service. It is the first step of the synthetic biometrics work described in
[`synthetic-biometrics-plan.md`](synthetic-biometrics-plan.md). You can run it from the command line or from
the web UI at `/faces`.

**Status (2026-09-23):** a command-line harness plus a web UI at `/faces`. There is no S3 storage or database
yet; images go to a local folder. Prompt version `faces-v3` and the VAE seam fix (below) haven't been checked on
real images yet.

> Everything this produces is synthetic test data. Use it for functional, integration and load testing of an
> ABIS, not as evidence of matching accuracy, and never send it to a production or live-exchange system. See
> [Caveats](#caveats).

## Quick start

`mix phx.server` must be running, because it runs the Qwen service. Then, in another terminal:

```bash
mix biometrics.faces --subjects 5 --seed 42
```

When it finishes it prints the path to a contact sheet (`index.html`). Open it in a browser to review the
results; hover over an image to see its prompt.

| Option | Default | Meaning |
|---|---|---|
| `--subjects N` | 3 | Number of fictional people |
| `--seed S` | random | Run seed; every person, prompt and image seed is derived from it |
| `--shots a,b,c` | see [Shots](#shots) | Shot types to generate; the anchor is always included |
| `--steps N` | 40 | Denoising steps |
| `--out DIR` | `data/synthetic/faces` | Output root (gitignored) |
| `--run NAME` | `<timestamp>-seed<S>` | Run folder name; reusing it resumes that run |
| `--force` | off | Regenerate images that already exist |

From IEx: `Bilder.Biometrics.FaceHarness.run(subjects: 2, seed: 42, shots: ["probe_glasses"])`.

The task loads only config and `Req`, not the whole application. Starting the app would launch a second Qwen
process that competes with the one `phx.server` already runs.

## Web UI

With `mix phx.server` running, open [`localhost:4000/faces`](http://localhost:4000/faces), or use **Faces**
in the top navigation.

- **`/faces`**
  - **New run** form: subjects, steps, seed, run name and shots, with an estimate of images and minutes.
  - The active run, with a progress bar, the shot being rendered, and **Cancel**.
  - All runs, newest first, including runs started with `mix biometrics.faces`.
- **`/faces/<run>`**
  - One row per subject. Each row shows the description and a tile per shot: thumbnail, *Rendering…*,
    *Queued* or *Failed*. Rows fill in live while the run is active.
  - Click a tile for the detail view: full image, pose code, size, seed, render time, the person and the exact
    prompt. ←/→ moves between the subject's shots, and Esc closes it.
  - **Resume** appears for runs with missing subjects or failed shots. It continues with the same seeds.

Runs execute in `Bilder.Biometrics.FaceRunner`, a single background worker, not in the page's process:

- Only one run is active at a time; the GPU renders one image at a time anyway.
- A run continues if you close the page.
- Progress reaches every open page through PubSub.

The output folder is the source of truth for listing runs (`Bilder.Biometrics.FaceRuns`). Images are served
from it by `/face-files/<run>/<subject>/<file>`, which only serves `.png` and `.json` files with safe names.
The folder is set by `config :bilder, :face_output_dir` (default `data/synthetic/faces`).

After pulling these changes, restart `mix phx.server`: the runner is new in the supervision tree, which code
reloading doesn't pick up.

## How it works

```
mix biometrics.faces
  └─ Bilder.Biometrics.FaceHarness.run/1
       ├─ FaceAttributes.sample/2     who the person is
       ├─ FacePrompts.prompt/2        what to ask the model for
       └─ ImageGeneration.render/2    HTTP → python_inference/server.py (Qwen-Image-2.1, GPU)
```

### One anchor per person

For each subject the harness:

1. Samples a fictional person's appearance from the subject seed.
2. Generates the **anchor**, a frontal mugshot, from the text description alone.
3. Generates every other shot with the anchor as its **only reference image**.

Conditioning on the anchor keeps the identity consistent across poses and probes without a separate identity
model. The only reference image is always one the harness generated itself, so the tool can't be used to make
"mugshots" of a real person from an uploaded photo.

### Shots

| Shot | ANSI/NIST pose | Size | Source |
|---|---|---|---|
| `mugshot_frontal` | F | 896×1120 (4:5) | text only (anchor) |
| `mugshot_left_profile` | L | 896×1120 | anchor |
| `mugshot_right_profile` | R | 896×1120 | anchor |
| `mugshot_three_quarter_left` / `_right` | A | 896×1120 | anchor |
| `icao_portrait` | F | 896×1152 (7:9, 35×45 mm) | anchor |
| `probe_rebooking` | F | 896×1120 | anchor |
| `probe_aged` | F | 896×1120 | anchor |
| `probe_glasses` | F | 896×1120 | anchor |
| `probe_appearance` | F | 896×1120 | anchor |

The default shots are the frontal, both profiles, `icao_portrait`, `probe_rebooking` and `probe_aged`.

- 4:5 is the ANSI/NIST-ITL Type-10 best-practice aspect ratio.
- 7:9 matches a 35×45 mm passport photo.
- A *left* profile shows the subject's left side, so they face the *left* edge of the image.

The **probes** are mated search images for ABIS testing: the same person with realistic variation.

| Probe | Variation |
|---|---|
| `probe_rebooking` | Head turned about 15°, harsh overhead light, different wall and clothing |
| `probe_aged` | 15 years older |
| `probe_glasses` | Glasses, window light, slight smile |
| `probe_appearance` | Beard grown or shaved (men), different hairstyle (women) |

### Person attributes

`Bilder.Biometrics.FaceAttributes.sample(seed, opts)` returns a struct with these fields:

- sex, age, ancestry
- skin tone, eye colour, hair colour and style, facial hair
- face shape, build, clothing
- optional distinguishing marks (mole, scar, freckles and similar)

How they're chosen:

- Ancestry is one of 11 broad regions, sampled evenly by default so a gallery covers a wide range of
  appearances.
- Skin, eye and hair colours come from ranges that fit the ancestry.
- Grey hair and receding hairlines become more likely with age.
- Options: `female_share`, `age_range` and `ancestry_weights`, to match a specific population.

`describe/1` renders the attributes as the sentence used in the anchor prompt, for example:

> a 69-year-old man of Latin American descent with light brown skin, hazel eyes, a round face, an average
> build, medium-length wavy white hair and a short full beard.

### Prompt design

`Bilder.Biometrics.FacePrompts` has two prompt styles.

- **Anchor and profiles** describe the photograph: a police booking photo, a plain mid-grey background, even
  flash lighting, a neutral expression, and "no text, no placard, no height chart".
  - Profiles spell out the direction redundantly ("faces the left edge of the image… nose pointing to the
    left"), because diffusion models often mix up left and right.
  - They also ask to keep the face, hair, clothing and background.
- **ICAO and probes** are written as edits: *"Edit the reference photo into… Changes: A; B; C. Keep the face
  shape, bone structure, eyes, nose, mouth, ears, skin tone and any scars, moles or freckles exactly the
  same."*

The main lesson from the test runs: **with a reference image, Qwen copies it unless every change is a concrete
target state.**

| Vague prompt (ignored) | Concrete prompt (followed) |
|---|---|
| "Different clothing" | "he now wears a burgundy sweatshirt" |
| "Head tilted slightly" | "head turned about 15 degrees towards the right of the image" |
| "Ten years older" | "15 years older… deeper forehead lines, crow's feet, looser skin under the eyes and jaw…" |

The probes therefore pick a replacement outfit from the clothing list, chosen deterministically. The list is
kept clearly distinct in colour and type: "grey sweatshirt" in place of "grey t-shirt" read as no change.

Every run records `FacePrompts.version/0` (currently `faces-v3`). Bump it whenever a template changes.

| Version | Change |
|---|---|
| v1 | First templates. Anchor and profiles were good; ICAO and probes were near-copies of the anchor. |
| v2 | "Changes / Keep" edit prompts with concrete changes. ICAO, re-booking, aged and glasses improved a lot. |
| v3 | Distinct clothing list. Concrete hairstyle changes for women. Beard removal no longer shaves the head. |

### Determinism and resuming

Every value is derived from the run seed:

| Value | Derived from |
|---|---|
| Subject seed | `phash2({run_seed, subject_index})` |
| Attributes and prompts | Subject seed |
| Per-shot image seed | `phash2({subject_seed, shot})` |

Rerunning with the same `--run` and `--seed` skips images that already exist. It regenerates missing ones with
the same seeds, reading the anchor back from disk as the reference. If a shot fails, the error is recorded and
the run continues. If the anchor fails, that subject's other shots are marked `skipped`.

### Output

```
data/synthetic/faces/<run>/
  run.json                 seed, shots, steps, prompt version, subject count
  index.html               contact sheet: one row per subject, prompt on hover
  subject_001/
    subject.json           attributes, description, and per shot: pos, size, seed, prompt,
                           reference, status, duration_ms, error
    mugshot_frontal.png
    mugshot_left_profile.png
    ...
```

The contact sheet is rewritten after each subject, so you can watch a run fill in.

### Qwen service changes

- **`render/2`:** `Bilder.ImageGeneration` was split. `render/2` returns the PNG and seed without saving
  anything, and accepts an explicit `:width`/`:height`. `generate/2`, used by the main page, still saves to
  `priv/static/uploads`.
- **VAE tiling in `python_inference/server.py`:**
  - Tiled VAE decoding used to be on for every image. It leaves faint vertical seams where its 256 px tiles blend
    (every 192 px), visible on the plain backgrounds.
  - It is now used only above `QWEN_VAE_TILING_MIN_PIXELS` (default 2,000,000 px), so the ~1 MP face images
    decode in one pass.
  - If an untiled decode runs out of GPU memory, it is retried once with tiling and the same seed.
  - The change takes effect after `mix phx.server` is restarted.

## Performance

On an RTX 4090 with CPU offload, each image takes about 41–44 s at 40 steps, so a subject with the six default
shots takes about 4.5 minutes. That's fine for prompt work and galleries of a few thousand subjects. Large ABIS
gallery fills (100k+) would need a faster generator; see the plan document.

## Tests

`test/bilder/biometrics/` stubs the Qwen service with `Req.Test` and writes to a temporary folder.

- **Attributes:** the same seed gives the same person, and the options are respected.
- **Prompts:** every shot has a valid spec and a fully filled-in prompt, only the anchor is text-only, and
  left/right are worded correctly.
- **Harness:**
  - The anchor is sent with no reference; other shots are sent with exactly the anchor PNG.
  - Files, JSON and the contact sheet are written.
  - Resume reuses the same seeds and skips existing files.
  - An anchor failure skips the rest of that subject.
  - Unknown shot names are rejected.

## Known issues and next steps

- Confirm the v3 prompts and the seam fix with a fresh run.
- The ICAO crop should be tighter: chin to crown should fill about 75% of the image height.
- Build ("heavy-set", "slim") is mostly ignored. This matters little for a head-and-shoulders image.
- Identity consistency has only been checked by eye. Next, add a face-embedding check against the ABIS matcher
  if its API is available, otherwise ArcFace:
  - reject new subjects that are too similar to existing ones
  - reject probes that no longer match their anchor
- Then add the storage abstraction (local folder or S3) and the database, as described in the plan.

## Caveats

- **What it's good for.** Synthetic images suit functional, integration, format and load testing. They are weak
  evidence of ABIS matching accuracy or demographic performance.
- **Accidental resemblance.** A generated face can resemble a real person by chance. Keep outputs marked as
  synthetic and keep them out of production and live-exchange systems.
- **Licences.** Check the Qwen-Image-2.1 licence, and the licence of any future model, for your use before
  relying on the output.

## Code map

| File | What it does |
|---|---|
| `lib/mix/tasks/biometrics.faces.ex` | CLI entry point |
| `lib/bilder_web/live/faces_live.ex` | `/faces`: new-run form, active run, run list |
| `lib/bilder_web/live/face_run_live.ex` | `/faces/:run`: subject grid, live progress, detail view, resume/cancel |
| `lib/bilder_web/components/face_components.ex` | Shared UI pieces: shot tiles, labels, progress bar |
| `lib/bilder_web/controllers/face_file_controller.ex` | Serves run images from the output folder |
| `lib/bilder/biometrics/face_runner.ex` | Background runner: one run at a time, PubSub progress, cancel |
| `lib/bilder/biometrics/face_runs.ex` | Reads runs and subjects back from the output folder |
| `lib/bilder/biometrics/face_run_request.ex` | Validates the web form |
| `lib/bilder/biometrics/face_harness.ex` | Runs batches: seeds, anchor and conditioned shots, resume, JSON, contact sheet |
| `lib/bilder/biometrics/face_attributes.ex` | Seeded person sampling and `describe/1` |
| `lib/bilder/biometrics/face_prompts.ex` | Shot specs, prompt templates, prompt version |
| `lib/bilder/image_generation.ex` | Qwen HTTP client (`render/2`, `generate/2`, `health/0`) |
| `python_inference/server.py` | Qwen-Image-2.1 FastAPI service (size-dependent VAE tiling) |
