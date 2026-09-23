# Synthetic biometrics

Bilder generates **synthetic subjects**, fictional people, for ABIS testing. Each subject can have:

- **Face images:** mugshots (frontal, profiles, ¾ views), an ICAO passport portrait and mated probe images,
  generated with the local Qwen-Image-2.1 service.
- **Friction-ridge images:**
  - 10 rolled fingerprints
  - right-four, left-four and two-thumb slaps
  - full and writer's palmprints of both hands
  - an FD-249 style tenprint card

  These are generated procedurally by the CPU service in [`python_biometrics/`](../python_biometrics/README.md).
  Any number of extra captures can be added for mated pairs.

All images of one subject show the same person, the same fingers and the same palms. This implements the face
and friction-ridge parts of [`synthetic-biometrics-plan.md`](synthetic-biometrics-plan.md). You can run it from
the command line or from the web UI at `/biometrics`.

**Status (2026-09-23):**

- Faces and friction ridges both work, from the command line and the web UI.
- There is no S3 storage or database yet; images go to a local folder.
- Two face changes haven't been checked on real images yet: prompt version `faces-v3` and the VAE seam fix
  (see [Qwen service changes](#qwen-service-changes)).

> Everything this produces is synthetic test data. Use it for functional, integration and load testing of an
> ABIS, not as evidence of matching accuracy, and never send it to a production or live-exchange system. See
> [Caveats](#caveats).

## Quick start

Run `mix phx.server`, which starts both services:

- Qwen-Image-2.1 on port 8000, for faces (GPU)
- the friction-ridge service on port 8001 (CPU)

The friction-ridge service needs its one-time setup first: `cd python_biometrics && ./setup.sh`. Then, in
another terminal:

```bash
mix biometrics.generate --subjects 5 --seed 42                                  # default face shots
mix biometrics.generate --shots faces,rolled,slaps,palms,card --captures 2      # everything, 2 captures
mix biometrics.generate --shots rolled,slaps                                    # fingerprints only, no GPU
```

When it finishes it prints the path to a contact sheet (`index.html`).

| Option | Default | Meaning |
|---|---|---|
| `--subjects N` | 3 | Number of fictional people |
| `--seed S` | random | Run seed; every person, prompt and image seed is derived from it |
| `--shots a,b,c` | `faces` | Shot ids and groups: `faces`, `rolled`, `slaps`, `palms`, `card` (see [Shots](#shots)) |
| `--captures N` | 1 | Captures per finger and palm shot (max 3); captures after the first are mated pairs |
| `--steps N` | 40 | Denoising steps for face shots |
| `--out DIR` | `data/synthetic/biometrics` | Output root (gitignored) |
| `--run NAME` | `<timestamp>-seed<S>` | Run folder name; reusing it resumes that run |
| `--force` | off | Regenerate images that already exist |

From IEx: `Bilder.Biometrics.Harness.run(subjects: 2, seed: 42, shots: ["rolled", "probe_glasses"])`.

The task loads only config and `Req`, not the whole application. Starting the app would launch second copies of
the Python services, competing with the ones `phx.server` already runs. The task only checks the services the
chosen shots need, so a fingerprint-only run works without the GPU service.

## Web UI

With `mix phx.server` running, open [`localhost:4000/biometrics`](http://localhost:4000/biometrics), or use
**Biometrics** in the top navigation.

- **`/biometrics`**
  - **New run** form:
    - subjects, seed and run name
    - face shots and face steps
    - friction-ridge groups and captures
    - an estimate of images and minutes
  - The status of both services. **Start run** is disabled until the services the selection needs are ready.
  - The active run, with a progress bar, the shot being rendered, and **Cancel**.
  - All runs, newest first, including runs started with `mix biometrics.generate`.
- **`/biometrics/<run>`**
  - One card per subject, with the description and sections for Face, Rolled fingers, Slaps, Palms and
    Tenprint card, plus one section per extra capture.
  - Each tile shows its thumbnail, *Rendering…*, *Queued* or *Failed*, and a code: the pose code for faces,
    FGP for fingers, PLP for palms. Rolled fingers also show their pattern class (W, RL, LL, A, TA). Cards fill
    in live while the run is active.
  - Click a tile for the detail view: full image, size, seed and render time. Faces show the person and the
    exact prompt. Friction-ridge shots show the ground truth (pattern, singular points, minutiae count,
    triradii) and a link to the ground-truth JSON. ←/→ moves between the subject's shots, and Esc closes it.
  - **Resume** appears for runs with missing subjects or failed shots. It continues with the same seeds.

Runs execute in `Bilder.Biometrics.Runner`, a single background worker, not in the page's process:

- Only one run is active at a time. The GPU renders one image at a time, and the ridge service uses every CPU
  core.
- A run continues if you close the page.
- Progress reaches every open page through PubSub.

The output folder is the source of truth for listing runs (`Bilder.Biometrics.Runs`). Images and ground-truth
JSON are served from it by `/biometrics-files/<run>/<subject>/<file>`, which only serves `.png` and `.json` files
with safe names. The folder is set by `config :bilder, :biometrics_output_dir` (default
`data/synthetic/biometrics`).

## How it works

```
mix biometrics.generate  /  /biometrics (via Bilder.Biometrics.Runner)
  └─ Bilder.Biometrics.Harness.run/1
       ├─ Shots.expand/2              which shots, in which order
       ├─ FaceAttributes.sample/2     who the person is
       ├─ FacePrompts.prompt/2        what to ask the model for (face shots)
       ├─ ImageGeneration.render/2    HTTP → python_inference/server.py   (Qwen-Image-2.1, GPU, :8000)
       └─ FrictionRidge.render/5      HTTP → python_biometrics/server.py  (ridgegen, CPU, :8001)
```

`Bilder.Biometrics.Shots` lists every shot across both modalities and expands group names. For example,
`rolled` becomes `rolled_01` … `rolled_10`, and `--captures 2` adds `rolled_01_c2` … after the first capture.
The face anchor is only added when there are face shots.

## Faces

### One anchor per person

For each subject the harness:

1. Samples a fictional person's appearance from the subject seed.
2. Generates the **anchor**, a frontal mugshot, from the text description alone.
3. Generates every other shot with the anchor as its **only reference image**.

Conditioning on the anchor keeps the identity consistent across poses and probes without a separate identity
model. The only reference image is always one the harness generated itself, so the tool can't be used to make
"mugshots" of a real person from an uploaded photo.

### Shots

Friction-ridge shots are described under [Friction ridges](#friction-ridges).

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

## Friction ridges

The CPU service in [`python_biometrics/`](../python_biometrics/README.md) generates these procedurally, in the
style of SFinGe. It needs no model weights or GPU. Its README covers the algorithm, the API and the limitations.

| Group | Shots | Code | Size (500 ppi) |
|---|---|---|---|
| `rolled` | `rolled_01` … `rolled_10`: R thumb … R little, L thumb … L little | FGP 1–10 | 800 × 750 |
| `slaps` | `slap_13` right four, `slap_14` left four, `slap_15` two thumbs | FGP 13–15 | 1600 × 1500 |
| `palms` | `palm_21` R full, `palm_22` R writer's, `palm_23` L full, `palm_24` L writer's | PLP 21–24 | 2750 × 4000, 875 × 2500 |
| `card` | `tenprint_card`: rolled prints and slaps on an FD-249 style card | – | 4000 × 4000 |

How the images relate:

- **One subject, one set of hands.** Every friction-ridge image of a subject comes from the subject seed.
  - Each finger and palm has one master pattern.
  - A finger's rolled print, its place in a slap, the card and later captures all show the same ridges and
    pattern class.
  - Pattern classes follow population priors per finger: loops dominate, thumbs and ring fingers are often
    whorls, and ulnar loops point towards the little finger.
- **Captures.** `capture` 2 and 3 (`_c2`, `_c3`) are new impressions of the same masters, with a different
  placement, skin distortion, contact area, pressure and noise. They are mated pairs for ABIS tests.
- **Ground truth.** Each image has a JSON file next to it. For fingers and slaps it holds the pattern class,
  cores and deltas, and minutiae (x, y, angle, ending or bifurcation) in that image's pixel coordinates. For
  palms it holds the triradii in view. `subject.json` keeps a summary without the minutiae lists.
- **Marking.** Every PNG is 8-bit grey with 500 ppi DPI metadata and `Synthetic=true` text chunks. The card's
  header says "SYNTHETIC TEST DATA - NOT A REAL PERSON".

The ridge images are plausible, but they aren't calibrated against real ridge statistics or checked with
NFIQ 2. See the service README for the limitations.

## Determinism and resuming

Every value is derived from the run seed:

| Value | Derived from |
|---|---|
| Subject seed | `phash2({run_seed, subject_index})` |
| Attributes and prompts | Subject seed |
| Per-shot face image seed | `phash2({subject_seed, shot})` |
| Finger and palm masters, captures | Subject seed, finger or palm code, capture number |

Rerunning with the same `--run` and `--seed` skips images that already exist. It regenerates missing ones with
the same seeds, reading the anchor back from disk as the reference. If a shot fails, the error is recorded and
the run continues. If the anchor fails, that subject's other face shots are marked `skipped`.

## Output

```
data/synthetic/biometrics/<run>/
  run.json                 seed, shots, captures, steps, prompt version, subject count
  index.html               contact sheet: one row per subject
  subject_001/
    subject.json           attributes, description, and per shot: pos/code, size, seed, capture,
                           prompt or ground-truth summary, status, duration_ms, error
    mugshot_frontal.png
    rolled_01.png          rolled_01.json    (ground truth: pattern, singular points, minutiae)
    slap_13.png            slap_13.json
    palm_21.png            palm_21.json
    tenprint_card.png      tenprint_card.json
    rolled_01_c2.png       rolled_01_c2.json (second capture)
    ...
```

The contact sheet is rewritten after each subject, so you can watch a run fill in.

## Qwen service changes

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

- **Faces:** on an RTX 4090 with CPU offload, each image takes about 41–44 s at 40 steps, so the six default face
  shots take about 4.5 minutes per subject.
- **Friction ridges:** measured on 24 CPU cores.

  | Work | Time |
  |---|---|
  | Finger master | 2 s |
  | Palm master | 25 s |
  | Further impression | 0.1–3 s |
  | All 18 friction-ridge shots with 2 captures (36 images) | about 1.5 minutes per subject |

That's fine for prompt work and galleries of a few thousand subjects. Large ABIS gallery fills (100k+) would need
a faster face generator; see the plan document.

## Tests

The Elixir tests stub both services with `Req.Test` and write to a temporary folder:

- `test/bilder/biometrics/`
  - **Attributes and prompts:** seeded people; every face shot has a valid spec and prompt.
  - **Shots:** group expansion, ordering, captures, anchor only with face shots, unknown names.
  - **Harness:**
    - face anchor conditioning
    - friction-ridge shots all come from the subject seed, and ground-truth JSON is written
    - resume, and failure handling
  - **Runner, runs reader, request validation and the ridge client.**
- `test/bilder_web/`
  - **Both pages:** form, services, run list, sections, tiles, detail views with prompt or ground truth, resume
    and cancel.
  - **The file controller.**

`python_biometrics/tests/` (run with `.venv/bin/python -m pytest`) covers:

- determinism and image sizes
- captures that share a pattern but differ
- minutiae that stay inside the print
- slap finger order, and slap fingers whose patterns match the rolled prints
- palms and the card
- the HTTP API, including 500 ppi and synthetic PNG metadata

## Known issues and next steps

- **Faces**
  - Confirm the v3 prompts and the seam fix with a fresh run.
  - The ICAO crop should be tighter: chin to crown should fill about 75% of the image height.
  - Build ("heavy-set", "slim") is mostly ignored. This matters little for a head-and-shoulders image.
  - Identity consistency has only been checked by eye. Next, add a face-embedding check against the ABIS
    matcher if its API is available, otherwise ArcFace:
    - reject new subjects that are too similar to existing ones
    - reject probes that no longer match their anchor
- **Friction ridges**
  - Run NFIQ 2 over a sample batch, and check matcher scores between captures of the same finger (should
    match) and different fingers (shouldn't).
  - Add WSQ compression and ANSI/NIST-ITL Type-4/14/15 packaging.
  - Latent prints are not generated yet.
- **Later:** the storage abstraction (local folder or S3) and the database, as described in the plan.

## Caveats

- **What it's good for.** Synthetic images suit functional, integration, format and load testing. They are weak
  evidence of ABIS matching accuracy or demographic performance.
- **Accidental resemblance.** A generated face can resemble a real person by chance, and so can a synthetic
  fingerprint: a foreign AFIS can false-match it. Keep outputs marked as synthetic, and keep them out of
  production and live-exchange systems.
- **Licences.** Check the Qwen-Image-2.1 licence, and the licence of any future model, for your use before
  relying on the output.

## Code map

| File | What it does |
|---|---|
| `lib/mix/tasks/biometrics.generate.ex` | CLI entry point |
| `lib/bilder_web/live/biometrics_live.ex` | `/biometrics`: new-run form, active run, run list |
| `lib/bilder_web/live/biometrics_run_live.ex` | `/biometrics/:run`: subject grid, live progress, detail view, resume/cancel |
| `lib/bilder_web/components/biometrics_components.ex` | Shared UI pieces: shot tiles, labels, progress bar |
| `lib/bilder_web/controllers/biometrics_file_controller.ex` | Serves run images from the output folder |
| `lib/bilder/biometrics/runner.ex` | Background runner: one run at a time, PubSub progress, cancel |
| `lib/bilder/biometrics/runs.ex` | Reads runs and subjects back from the output folder |
| `lib/bilder/biometrics/run_request.ex` | Validates the web form |
| `lib/bilder/biometrics/harness.ex` | Runs batches: seeds, face anchor and conditioned shots, ridge shots, resume, JSON, contact sheet |
| `lib/bilder/biometrics/shots.ex` | Registry of all shots across modalities; group and capture expansion |
| `lib/bilder/biometrics/friction_ridge.ex` | HTTP client for the friction-ridge service |
| `lib/bilder/python_service.ex` | Supervises both Python services (`Bilder.QwenService`, `Bilder.BiometricsService`) |
| `lib/bilder/biometrics/face_attributes.ex` | Seeded person sampling and `describe/1` |
| `lib/bilder/biometrics/face_prompts.ex` | Shot specs, prompt templates, prompt version |
| `lib/bilder/image_generation.ex` | Qwen HTTP client (`render/2`, `generate/2`, `health/0`) |
| `python_inference/server.py` | Qwen-Image-2.1 FastAPI service (size-dependent VAE tiling) |
| `python_biometrics/server.py`, `ridgegen/` | Friction-ridge FastAPI service and generator (see its README) |
