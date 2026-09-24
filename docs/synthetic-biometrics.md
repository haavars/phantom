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
machine without an NVIDIA GPU and use the `procedural` renderer.

Start runs from the web UI (below), or from IEx attached to the running app (`iex -S mix phx.server`):

```elixir
Phantom.Biometrics.create_run(%{subjects: 5, seed: 42})                                    # default face shots
Phantom.Biometrics.create_run(%{shots: ["faces", "rolled", "slaps", "palms", "card"], captures: 2})
Phantom.Biometrics.create_run(%{shots: ["rolled", "slaps"], renderer: "procedural"})      # no GPU needed
```

`create_run/1` validates its parameters like the web form (`Phantom.Biometrics.RunRequest`) and queues the run,
so runs from IEx and from the UI share one queue and show up on the same pages. In a release, run the same call
with `bin/phantom rpc`.

| Parameter | Default | Meaning |
|---|---|---|
| `subjects` | 3 | Number of fictional people (max 100) |
| `seed` | random | Run seed; every person, prompt and image seed is derived from it |
| `shots` | every face shot and ridge group | Shot ids and groups: `faces`, `rolled`, `slaps`, `palms`, `card` (see [Shots](#shots)) |
| `captures` | 1 | Captures per finger and palm shot (max 3); captures after the first are mated pairs |
| `renderer` | `diffusion` | Friction-ridge renderer: `diffusion` (realistic, GPU) or `procedural` (fast CPU draft) |
| `steps` | 40 | Denoising steps for face shots (20, 30, 40 or 50) |
| `run` | `<timestamp>-seed<S>` | Run name |

## Web UI

With `mix phx.server` running, open [`localhost:4000/biometrics`](http://localhost:4000/biometrics), or use
**Runs** in the top navigation.

- **`/biometrics`**
  - **New run** form:
    - subjects, seed and run name
    - face shots and face steps
    - friction-ridge groups, renderer and captures
    - an estimate of images and minutes
  - The status of both services. **Start run** is disabled until the services the selection needs are ready.
    Runs started while another is rendering are queued behind it.
  - The run rendering now, with a progress bar, the shot being rendered, and **Cancel**.
  - All runs, newest first (including runs created from IEx), marked queued, running, cancelled or failed.
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
  - **Cancel** stops a queued or running run. **Resume** appears for cancelled or failed runs, and for runs with
    missing subjects or failed shots. It queues the subjects that aren't done; they keep the images already
    rendered and render the rest with the same seeds.

Runs render in [Oban](https://oban.hexdocs.pm) jobs, not in the page's process:

- Creating a run queues one `GenerateSubject` job per subject. The `generation` queue runs one job at a time,
  since the GPU renders one image at a time and the ridge service uses every CPU core. Runs queue behind each
  other.
- A run continues if you close the page, and survives a restart: a job interrupted by one is rescued after half an
  hour and picks up where it stopped. Jobs retry up to 3 times; a job that runs out of attempts marks its run
  failed. While a service a job needs isn't ready (the Qwen model takes a while to load), the job waits.
- Every image, subject and run update is broadcast over PubSub (`Phantom.Biometrics.subscribe/0`), so open pages
  fill in live.

Runs are stored in Postgres (see [Storage](#storage)). Images are served by id from `/images/:id`, and a
friction-ridge image's ground truth from `/images/:id/ground-truth`.

## How it works

```
Phantom.Biometrics.create_run/1        from the web form or IEx
  └─ one Oban job per subject: Workers.GenerateSubject     (queue :generation, one at a time)
       └─ Generator.generate_subject/2
            ├─ FaceAttributes.sample/1              who the person is
            ├─ Generator.Faces                      face shots: FacePrompts + Services.Qwen   (python_inference, GPU, :8000)
            ├─ Generator.FrictionRidges             ridge shots: Services.Ridgegen            (python_biometrics, :8001)
            ├─ Storage.put/2                        the image file
            └─ Biometrics.save_image/2, complete_subject/1   rows + PubSub; the last subject builds the
                                                             Report (bozorth3 via Services.Ridgegen.match/2)
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

The Elixir tests stub both services with `Req.Test`, run Oban in `:manual` testing mode (jobs are rendered by
draining the queue in the test process) and store images under `tmp/test/biometrics`:

- `test/phantom/biometrics_test.exs`: the context. Listing and reading runs, queueing one job per subject,
  resume, cancel, failure, progress and events.
- `test/phantom/biometrics/`
  - **Generator:** face anchor conditioning; friction-ridge shots from the subject seed with ground truth;
    the renderer; resuming keeps stored images; failed shots; the quality report.
  - **GenerateSubject worker:** renders, snoozes while a service is down, stops for cancelled runs, marks runs
    failed when discarded.
  - **Attributes and prompts, shots, request validation, storage, gallery and the quality report.**
- `test/phantom/services/`: the Qwen and ridgegen clients, and the supervised Python processes.
- `test/phantom_web/`
  - **The pages:** form, services, run list and statuses, queued runs, sections, tiles, detail views with prompt
    or ground truth, resume and cancel, the landing page and gallery.
  - **The image controller.**

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
| `lib/phantom/biometrics.ex` | The context: runs, subjects, images and identities; create, resume and cancel; events |
| `lib/phantom/biometrics/workers/generate_subject.ex` | Oban worker rendering one subject; marks runs failed when discarded |
| `lib/phantom/biometrics/generator.ex`, `generator/` | Renders a subject: seeds, anchor conditioning, face and friction-ridge shots |
| `lib/phantom/biometrics/{run,subject,image}.ex` | Ecto schemas for the `runs`, `subjects` and `images` tables |
| `lib/phantom/biometrics/run_request.ex` | Validates the parameters of a new run |
| `lib/phantom/biometrics/storage.ex`, `storage/local.ex` | Where image files live: the storage behaviour and its local-disk backend |
| `lib/phantom/biometrics/shots.ex` | Registry of all shots across modalities; group and capture expansion |
| `lib/phantom/biometrics/report.ex` | Run quality report: verification outcomes, bozorth3 mated vs non-mated |
| `lib/phantom/biometrics/gallery.ex` | Identities for the landing page gallery |
| `lib/phantom/biometrics/face_attributes.ex` | Seeded person sampling and `describe/1` |
| `lib/phantom/biometrics/face_prompts.ex` | Shot specs, prompt templates, prompt version |
| `lib/phantom/services/qwen.ex`, `ridgegen.ex` | HTTP clients for the two Python services |
| `lib/phantom/services/python_process.ex` | Supervises both Python services as OS processes (`QwenProcess`, `RidgegenProcess`) |
| `lib/phantom_web/live/landing_live.ex` | `/`: what Phantom is, and the gallery of identities |
| `lib/phantom_web/live/biometrics_live.ex` | `/biometrics`: new-run form, the run rendering now, run list |
| `lib/phantom_web/live/biometrics_run_live.ex` | `/biometrics/:run` and `/:run/:subject`: subjects, live progress, detail view, resume/cancel |
| `lib/phantom_web/components/biometrics_components.ex` | Shared UI pieces: shot tiles, labels, statuses, progress bar, report |
| `lib/phantom_web/controllers/image_controller.ex` | Serves image files and ground truth by image id |
| `python_inference/server.py` | Qwen-Image-2.1 FastAPI service (size-dependent VAE tiling) |
| `python_biometrics/server.py`, `ridgegen/` | Friction-ridge FastAPI service and generator (see its README) |
| `python_biometrics/verify.py`, `diffusion.py` | Verification with NIST tools; the diffusion renderer |
