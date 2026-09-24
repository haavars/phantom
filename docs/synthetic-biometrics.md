# Synthetic biometrics

Phantom generates **synthetic subjects**, fictional people, for ABIS testing. Each subject can have:

- **Face images:** mugshots (frontal, profiles, ¾ views), an ICAO passport portrait and mated probe images,
  generated with the local Qwen-Image-2.1 service.
- **Friction-ridge images:**
  - 10 rolled fingerprints
  - right-four, left-four and two-thumb slaps
  - full and writer's palmprints of both hands
  - an FD-249 style tenprint card

  The service in [`python_biometrics/`](../python_biometrics/README.md) synthesises the ridge patterns, renders
  them as realistic inked prints with a diffusion model (or procedurally, as a fast CPU draft), and verifies
  every finger and slap against its ground truth. Extra captures can be added for mated pairs.

All images of one subject show the same person, the same fingers and the same palms. This implements the face
and friction-ridge parts of [`synthetic-biometrics-plan.md`](synthetic-biometrics-plan.md). You can run it from
the command line or from the web UI at `/biometrics`.

**Status (2026-09-23):**

- Faces and friction ridges both work, from the command line and the web UI.
- Friction ridges are rendered by diffusion and verified with NIST tools (NFIQ 2, `mindtct`, `bozorth3`). See
  [`realistic-fingerprints-plan.md`](realistic-fingerprints-plan.md) for what's done and what's next.
- There is no S3 storage or database yet; images go to a local folder.
- Two face changes haven't been checked on real images yet: prompt version `faces-v3` and the VAE seam fix
  (see [Qwen service changes](#qwen-service-changes)).

> Everything this produces is synthetic test data. Use it for functional, integration and load testing of an
> ABIS, not as evidence of matching accuracy, and never send it to a production or live-exchange system. See
> [Caveats](#caveats).

## Quick start

Run `mix phx.server`, which starts both services:

- Qwen-Image-2.1 on port 8000, for faces (GPU)
- the friction-ridge service on port 8001 (patterns and verification on the CPU, diffusion rendering on the GPU)

The friction-ridge service needs its one-time setup first: `cd python_biometrics && ./setup.sh --diffusion`.
This builds the NIST verification tools and installs the diffusion renderer; leave out `--diffusion` on a
machine without an NVIDIA GPU and use `--renderer procedural`. Then, in another terminal:

```bash
mix biometrics.generate --subjects 5 --seed 42                                  # default face shots
mix biometrics.generate --shots faces,rolled,slaps,palms,card --captures 2      # everything, 2 captures
mix biometrics.generate --shots rolled,slaps --renderer procedural              # fingerprints only, no GPU
```

When it finishes it prints the friction-ridge quality report (see [Verification](#verification)) and where to
open the run in the app. The run is recorded in the database like runs started from the app.

| Option | Default | Meaning |
|---|---|---|
| `--subjects N` | 3 | Number of fictional people |
| `--seed S` | random | Run seed; every person, prompt and image seed is derived from it |
| `--shots a,b,c` | `faces` | Shot ids and groups: `faces`, `rolled`, `slaps`, `palms`, `card` (see [Shots](#shots)) |
| `--captures N` | 1 | Captures per finger and palm shot (max 3); captures after the first are mated pairs |
| `--renderer R` | `diffusion` | Friction-ridge renderer: `diffusion` (realistic, GPU) or `procedural` (fast CPU draft) |
| `--steps N` | 40 | Denoising steps for face shots |
| `--out DIR` | `data/synthetic/biometrics` | Output root (gitignored) |
| `--run NAME` | `<timestamp>-seed<S>` | Run folder name; reusing it resumes that run |
| `--force` | off | Regenerate images that already exist |

From IEx: `Phantom.Biometrics.Harness.run(subjects: 2, seed: 42, shots: ["rolled", "probe_glasses"])`.

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
    - friction-ridge groups, renderer and captures
    - an estimate of images and minutes
  - The status of both services. **Start run** is disabled until the services the selection needs are ready.
  - The active run, with a progress bar, the shot being rendered, and **Cancel**.
  - All runs, newest first, including runs started with `mix biometrics.generate`.
- **`/biometrics/<run>`**
  - A **Friction-ridge quality** panel once the run has finished: verified, accepted, retried and rejected
    counts, NFIQ 2 and minutiae recall per impression type, and `bozorth3` mated against non-mated scores.
  - One card per subject, with the description and sections for Face, Rolled fingers, Slaps, Palms and
    Tenprint card, plus one section per extra capture.
  - Each tile shows its thumbnail, *Rendering…*, *Queued* or *Failed*, and a code: the pose code for faces,
    FGP for fingers, PLP for palms. Rolled fingers also show their pattern class (W, RL, LL, A, TA). Verified
    fingers and slaps show their NFIQ 2 score, marked when the image needed a retry or was rejected. Cards fill
    in live while the run is active.
  - Click a tile for the detail view: full image, size, seed and render time. Faces show the person and the
    exact prompt. Friction-ridge shots show the ground truth (pattern, singular points, minutiae count,
    triradii), the verification results and a link to the ground-truth JSON. ←/→ moves between the subject's
    shots, and Esc closes it.
  - **Resume** appears for runs with missing subjects or failed shots. It continues with the same seeds.

Runs execute in `Phantom.Biometrics.Runner`, a single background worker, not in the page's process:

- Only one run is active at a time. The GPU renders one image at a time, and the ridge service uses every CPU
  core.
- A run continues if you close the page.
- Progress reaches every open page through PubSub.

Runs are stored in Postgres (`Phantom.Biometrics.Runs`, see [Storage](#storage)). The run's status is kept
there too: a run interrupted by a restart is marked `cancelled` when the app starts, and can be resumed. Images
are served by id from `/images/:id`, and a friction-ridge image's ground truth from `/images/:id/ground-truth`.

## How it works

```
mix biometrics.generate  /  /biometrics (via Phantom.Biometrics.Runner)
  └─ Phantom.Biometrics.Harness.run/1
       ├─ Shots.expand/2              which shots, in which order
       ├─ FaceAttributes.sample/2     who the person is
       ├─ FacePrompts.prompt/2        what to ask the model for (face shots)
       ├─ ImageGeneration.render/2    HTTP → python_inference/server.py   (Qwen-Image-2.1, GPU, :8000)
       ├─ FrictionRidge.render/5      HTTP → python_biometrics/server.py  (ridgegen + diffusion + verify, :8001)
       └─ Report.write/2              run quality report; FrictionRidge.match/2 → bozorth3
```

`Phantom.Biometrics.Shots` lists every shot across both modalities and expands group names. For example,
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

`Phantom.Biometrics.FaceAttributes.sample(seed, opts)` returns a struct with these fields:

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

`Phantom.Biometrics.FacePrompts` has two prompt styles.

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

The service in [`python_biometrics/`](../python_biometrics/README.md) generates them in two stages. Its README
covers the algorithm, the API and the limitations.

1. **Identity:** SFinGe-style master patterns and per-capture geometry (placement, skin distortion, contact
   area). This fixes the ridges and the ground truth. It runs on the CPU.
2. **Appearance:** the `diffusion` renderer (the default) draws the capture procedurally, then runs it part-way
   through IMPOSE's latent diffusion model for rolled prints, which was trained on real prints. That swaps
   the drawn look for real ink texture and keeps the ridges. The `procedural` renderer skips the model: it's
   faster, CPU only, and looks computer-generated. Palms are always procedural.

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
- **Ground truth.** Each friction-ridge image stores its ground truth (`images.ground_truth`). For fingers and
  slaps it holds the pattern class, cores and deltas, and minutiae (x, y, angle, ending or bifurcation) in that
  image's pixel coordinates. For palms it holds the triradii in view. `images.meta` keeps a summary without the
  minutiae lists, for pages and reports.
- **Marking.** Every PNG is 8-bit grey with 500 ppi DPI metadata and `Synthetic=true` text chunks. The card's
  header says "SYNTHETIC TEST DATA - NOT A REAL PERSON".

### Verification

A diffusion model can move, drop or invent minutiae, and a matcher tolerates exactly that, so it can't catch it.
The service therefore checks every finger and slap it renders (`python_biometrics/verify.py`):

- NIST `mindtct` extracts minutiae from the rendered image and from the clean ridge map it was rendered from.
  The two sets are paired within 12 px and 30°, inside the contact area.
- **Recall** (share of the clean map's minutiae found) must be at least 0.85 and the **spurious rate** at most
  0.15. **NFIQ 2** must be at least 35, per finger for slaps.
- An image that fails is re-rendered with new appearance randomness (same ridges), up to 3 attempts. If none
  passes, the best attempt is kept and marked rejected.
- The results go into the ground truth (`verification`: metrics, attempts, the missed and spurious points, the
  detected minutiae) and a summary into `meta`.

At the end of a run the harness stores its report on the run (`runs.report`, see `Phantom.Biometrics.Report`):

- how many images were verified, accepted, accepted after a retry, or rejected
- NFIQ 2, recall and spurious-rate distributions per impression type
- `bozorth3` scores of mated pairs (captures of the same finger) against non-mated pairs (the same finger of
  different subjects), with the pairs on the wrong side of the threshold of 40 listed

Baseline, 3–4 subjects with 2 captures each:

| Renderer | Rolled NFIQ 2 | Plain NFIQ 2 | Minutiae recall | Accepted | Mated min / non-mated max |
|---|---|---|---|---|---|
| Procedural | 47 (39–56) | 54 (48–63) | 0.98 | 100% | 112 / 27 |
| Diffusion | 46 (40–55) | 53 (45–63) | 0.92 | 99% first time, 100% after retries | 114 / 30 |

## Determinism and resuming

Every value is derived from the run seed:

| Value | Derived from |
|---|---|
| Subject seed | `phash2({run_seed, subject_index})` |
| Attributes and prompts | Subject seed |
| Per-shot face image seed | `phash2({subject_seed, shot})` |
| Finger and palm masters, captures | Subject seed, finger or palm code, capture number |
| Rendering (procedural noise, diffusion seed) | Subject seed, shot code, capture number, attempt number |

Rerunning with the same `--run` and `--seed` keeps images that are already stored (their row says `ok` and the
file exists). It renders missing ones with the same seeds, reading the anchor back from storage as the
reference. If a shot fails, the error is recorded and
the run continues. If the anchor fails, that subject's other face shots are marked `skipped`.

## Storage

Runs live in three Postgres tables, written as a run renders so pages can follow it:

| Table | One row per | Holds |
|---|---|---|
| `runs` | run | name, seed, status (`running`, `finished`, `cancelled`, `failed`), shots, captures, renderer, steps, prompt version, subject count, quality report, error, start and finish times |
| `subjects` | synthetic person | run, position, name (`subject_001`), seed, description, sampled attributes, when every shot was attempted |
| `images` | shot of a subject | shot and capture, status (`ok`, `error`, `skipped`), size, seed, prompt, the anchor it was conditioned on, storage key, byte size, SHA-256, ground-truth summary (`meta`) and full ground truth, duration, error |

Image files are kept by `Phantom.Biometrics.Storage`. The default backend, `Storage.Local`, writes them to
`config :phantom, :biometrics_output_dir` (default `data/synthetic/biometrics`):

```
data/synthetic/biometrics/<run>/
  subject_001/
    mugshot_frontal.png
    rolled_01.png
    rolled_01_c2.png       (second capture)
    slap_13.png
    palm_21.png
    tenprint_card.png
    ...
```

The database only stores each file's key (`<run>/subject_001/rolled_01.png`), so another backend (S3, say) can
implement the `Storage` behaviour and be set with `config :phantom, :biometrics_storage`.

## Qwen service changes

- **`render/2`:** `Phantom.ImageGeneration` was split. `render/2` returns the PNG and seed without saving
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
  | All 18 friction-ridge shots with 2 captures (36 images), procedural | about 1.5 minutes per subject |

  Verification adds about 1 s per finger and 2 s per slap. The diffusion renderer on the RTX 4090 adds about
  0.3 s per rolled print (1.9 GB VRAM) and 1 s per slap (6.5 GB VRAM); the card re-renders its 13 prints, about
  20 s. 10 rolled, 3 slaps and the card with 2 captures took about 1.8 minutes per subject.

That's fine for prompt work and galleries of a few thousand subjects. Large ABIS gallery fills (100k+) would need
a faster face generator; see the plan document.

## Tests

The Elixir tests stub both services with `Req.Test` and write to a temporary folder:

- `test/phantom/biometrics/`
  - **Attributes and prompts:** seeded people; every face shot has a valid spec and prompt.
  - **Shots:** group expansion, ordering, captures, anchor only with face shots, unknown names.
  - **Harness:**
    - face anchor conditioning
    - friction-ridge shots all come from the subject seed, and ground-truth JSON is written
    - the renderer is passed through, and verified shots produce a report on the run
    - resume, and failure handling
  - **Runner, runs reader, request validation, the ridge client and the quality report.**
- `test/phantom_web/`
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
- verification: minutiae pairing, and procedural prints that pass while a different finger fails (needs the
  NIST tools)
- the diffusion renderer: deterministic, keeps the ridges (needs `setup.sh --diffusion` and a GPU)

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
  - Next steps of [`realistic-fingerprints-plan.md`](realistic-fingerprints-plan.md): acquisition styles
    (livescan, dry, low quality) need a conditioned model; the diffusion model only knows inked rolled prints.
  - Slaps: adjacent fingers can touch with hard seams, and the middle phalanx is a straight-edged patch. The
    diffusion renderer makes this more visible. Render plain fingers separately and fix the layout (plan phase 3).
  - Ground-truth minutiae angles point the opposite way from ANSI/INCITS 378 (`mindtct` differs by about 180°).
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
  relying on the output. IMPOSE's code and weights are Apache 2.0; its training data isn't documented, so a
  check that rendered prints don't reproduce real ridge detail is still open (plan section 9).

## Code map

| File | What it does |
|---|---|
| `lib/mix/tasks/biometrics.generate.ex` | CLI entry point |
| `lib/phantom_web/live/biometrics_live.ex` | `/biometrics`: new-run form, active run, run list |
| `lib/phantom_web/live/biometrics_run_live.ex` | `/biometrics/:run`: subject grid, live progress, detail view, resume/cancel |
| `lib/phantom_web/components/biometrics_components.ex` | Shared UI pieces: shot tiles, labels, progress bar |
| `lib/phantom_web/controllers/image_controller.ex` | Serves image files and ground truth by image id |
| `lib/phantom/biometrics/runner.ex` | Background runner: one run at a time, PubSub progress, cancel |
| `lib/phantom/biometrics/runs.ex` | Runs, subjects and images in the database: reading and recording them |
| `lib/phantom/biometrics/{run,subject,image}.ex` | Ecto schemas for the `runs`, `subjects` and `images` tables |
| `lib/phantom/biometrics/storage.ex`, `storage/local.ex` | Where image files live: the storage behaviour and its local-disk backend |
| `lib/phantom/biometrics/run_request.ex` | Validates the web form |
| `lib/phantom/biometrics/harness.ex` | Runs batches: seeds, face anchor and conditioned shots, ridge shots, resume, storing results |
| `lib/phantom/biometrics/shots.ex` | Registry of all shots across modalities; group and capture expansion |
| `lib/phantom/biometrics/friction_ridge.ex` | HTTP client for the friction-ridge service (`render`, `match`) |
| `lib/phantom/biometrics/report.ex` | Run quality report: verification outcomes, bozorth3 mated vs non-mated |
| `lib/phantom/python_service.ex` | Supervises both Python services (`Phantom.QwenService`, `Phantom.BiometricsService`) |
| `lib/phantom/biometrics/face_attributes.ex` | Seeded person sampling and `describe/1` |
| `lib/phantom/biometrics/face_prompts.ex` | Shot specs, prompt templates, prompt version |
| `lib/phantom/image_generation.ex` | Qwen HTTP client (`render/2`, `generate/2`, `health/0`) |
| `python_inference/server.py` | Qwen-Image-2.1 FastAPI service (size-dependent VAE tiling) |
| `python_biometrics/server.py`, `ridgegen/` | Friction-ridge FastAPI service and generator (see its README) |
| `python_biometrics/verify.py`, `diffusion.py` | Verification with NIST tools; the diffusion renderer |
