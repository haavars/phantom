# Plan: Synthetic biometrics generator (faces, mugshots, fingerprints, tenprints, palmprints)

Status: draft, 2026-09-23; updated 2026-09-25. Faces, friction ridges, Postgres storage, per-run traits,
per-person downloads and ANSI/NIST-ITL export are implemented; see
[`synthetic-biometrics.md`](synthetic-biometrics.md) for what exists today.

## 1. Goal

Add a separate LiveView at `/biometrics` that generates **synthetic test subjects**. A subject is one fictional
person with any combination of:

| Modality | Images per subject | Reference format |
|---|---|---|
| ICAO portrait (passport style) | 1 frontal | ISO/IEC 39794-5 / ICAO 9303, 3:4 |
| Mugshot set | frontal + left profile + right profile (optionally ¾ views) | ANSI/NIST-ITL Type-10, POS codes `F`, `L`, `R`, `A`/`D` |
| Rolled tenprint | 10 rolled fingers | Type-14, FGP 1–10, 500 ppi |
| Plain/slap impressions | right four, left four, two thumbs | Type-14, FGP 13, 14, 15 |
| Palmprints | left/right full palm and writer's palm | Type-15, PLP 21–24 |
| Extra impressions | N more captures of the same finger/palm, for mated-pair tests | same codes, `impression` index |

Every image is saved to storage, either a **local folder** or **S3**, as set in config. Metadata goes to Postgres
and a `manifest.json` is written next to the images, so an exported folder describes itself.

Out of scope for the first version, but kept possible by the design: ANSI/NIST-ITL (`.an2`) packaging, WSQ
compression, latent prints, morphs, and quality gates beyond basic checks. (`.an2` packaging and WSQ have since
been built: [`nist-export-plan.md`](nist-export-plan.md).)

## 2. What exists today

- `PhantomWeb.GenerateLive` at `/`: a general text-to-image UI.
- `Phantom.ImageGeneration`: calls the local Qwen-Image-2.1 FastAPI service (`python_inference/server.py`) over
  HTTP with `Req`. It supports up to 10 reference images for image-conditioned generation. Output goes straight
  to `priv/static/uploads`.
- `Phantom.QwenService`: runs the Python process under supervision through a `Port`.
- Postgres/`Phantom.Repo` is configured, but there are no schemas or migrations yet.
- Tests stub HTTP with `Req.Test` (`config :phantom, :qwen_image_req_options, plug: {Req.Test, ...}`).

We reuse all of this. Faces go through the existing Qwen service. Fingerprints and palms need a different kind
of generator (section 5).

## 3. Architecture

```
BiometricsLive (/biometrics)
   │  form: what to generate, how many subjects, seed
   ▼
Phantom.Biometrics  (context: create_batch/1, list_subjects/1, get_subject!/1)
   │  writes a Batch + Subject rows, enqueues work
   ▼
Phantom.Biometrics.Runner  (Task.Supervisor + a small per-backend concurrency limit)
   │  for each subject → each requested artifact
   ├── FaceGenerator.Qwen ──────► python_inference (Qwen-Image-2.1, GPU)   :8000
   ├── FrictionRidgeGenerator.Procedural ─► python_biometrics (CPU)        :8001
   ▼
Phantom.Storage (behaviour)  ── Local | S3
   │
   ├── Postgres: synthetic_images row (key, sha256, dims, ppi, seed, generator…)
   └── PubSub "biometrics:batch:<id>" → LiveView streams progress
```

### New modules

| Module | Responsibility |
|---|---|
| `Phantom.Storage` | Behaviour: `put(key, binary, opts)`, `get(key)`, `url(key, opts)`, `delete(key)`. Selects the adapter from config. |
| `Phantom.Storage.Local` | Writes under a configurable root, `mkdir_p`, then an atomic `File.rename` from a temp file. |
| `Phantom.Storage.S3` | Plain `Req` with the built-in `aws_sigv4:` option (Req 0.7 has `put_aws_sigv4`). `Req.Utils.aws_sigv4_url/1` produces presigned GET URLs for display. No `ex_aws` dependency. Works with AWS, MinIO and other S3-compatible stores through `endpoint_url`. |
| `Phantom.Biometrics` | Context: batches, subjects, images, and the queries the LiveView needs. |
| `Phantom.Biometrics.Batch` / `Subject` / `Image` | Ecto schemas (section 6). |
| `Phantom.Biometrics.Positions` | Constants for the codes and nominal sizes in section 4: FGP 1–15, PLP 21–28 and face POS. The single source of truth. |
| `Phantom.Biometrics.FaceAttributes` | Samples demographics and appearance per subject from a seeded RNG (`:rand.seed(:exsss, seed)`). Builds the prompt. |
| `Phantom.Biometrics.FaceGenerator` | Behaviour, plus the `Qwen` implementation that reuses the HTTP client in `Phantom.ImageGeneration`. |
| `Phantom.Biometrics.FrictionRidgeGenerator` | Behaviour, plus the `Procedural` implementation that calls `python_biometrics`. |
| `Phantom.Biometrics.Runner` | Runs a batch: fans out per subject, calls generators, stores results, broadcasts progress. |
| `Phantom.Biometrics.Manifest` | Builds `manifest.json` per subject and per batch. |
| `Phantom.PythonService` | Generalises `Phantom.QwenService` (dir, script, port, name) so both Python services use one supervised-port implementation. `QwenService` becomes a thin config of it. |
| `PhantomWeb.BiometricsLive` | The new LiveView, route `live "/biometrics", BiometricsLive, :index`. Later: `live "/biometrics/subjects/:id", BiometricsLive.Show, :show`. |
| `PhantomWeb.StorageController` | Only for local storage outside `priv/static`: `GET /files/*key` streams from `Storage.Local` using `send_file`, with path-traversal checks. For S3 the LiveView uses presigned URLs instead. |

Small refactor of `Phantom.ImageGeneration`: split "call the model" (returns the PNG binary and seed) from "save to
`priv/static/uploads`", so the biometrics pipeline can call the model without writing into the public uploads
folder. `GenerateLive` keeps its current behaviour.

## 4. Image specifications

All friction-ridge images: **8-bit grayscale PNG, 500 ppi** (lossless; the NIST export can compress them as
WSQ). Sizes follow the ANSI/NIST-ITL / EBTS maximum capture areas. Check the exact limits against the EBTS
version your target system uses before you rely on them.

| Artifact | Code | Size (in) | Pixels @ 500 ppi |
|---|---|---|---|
| Rolled finger | FGP 1–10 | 1.6 × 1.5 | 800 × 750 |
| Plain right/left four fingers | FGP 13 / 14 | 3.2 × 3.0 | 1600 × 1500 |
| Plain two thumbs | FGP 15 | 1.6 × 1.5 (per thumb) | 1600 × 1500 composite |
| Full palm | PLP 21 / 23 | 5.5 × 8.0 | 2750 × 4000 |
| Writer's palm | PLP 22 / 24 | 1.75 × 5.0 | 875 × 2500 |

Finger numbering: 1 R thumb, 2 R index, 3 R middle, 4 R ring, 5 R little, 6 L thumb … 10 L little.

Faces: generate at **864 × 1152 (3:4)**, which is already in `ImageGeneration.aspect_ratios`, then centre-crop and
scale in Python so the head geometry roughly matches ICAO proportions. Rules:

- ICAO: plain light background, neutral expression, eyes open, no head covering, even lighting.
- Mugshot: 18% grey background, height chart off by default, and a placard is **never** rendered. A fake booking
  placard with a name is exactly the kind of artefact that should not exist.

A composite **tenprint card** (FD-249-style layout) is a derived image built from the 14 finger images. It is
optional, rendered in Python, and stored as `card.png`.

## 5. Generators

### 5.1 Faces: Qwen-Image-2.1 (already running)

1. `FaceAttributes.sample(seed)` picks sex, age band, skin tone, hair (colour, length, style), facial hair,
   glasses (off by default for ICAO), and build. Distributions are configurable in `config :phantom, :biometrics`.
2. **Frontal:** text-to-image with a fixed template, for example: *"Passport photograph, ICAO compliant, head and
   shoulders, <attributes>, neutral expression, mouth closed, looking straight at camera, even studio lighting,
   plain light grey background, sharp focus, photorealistic"*. Mugshot uses a variant template.
3. **Profiles and ¾ views:** image-conditioned generation with the **frontal as the only reference image**, for
   example *"The same person from the reference image, left profile, 90 degrees, same clothing and lighting,
   plain grey background"*. This keeps identity across poses without a separate identity model.
4. Save the seed of every call so any image can be regenerated exactly.

Rules:

- The biometrics LiveView **does not accept uploaded reference faces**. The only reference images are ones the
  pipeline generated itself. This keeps the tool from making "mugshots" of real people.
- Known weak spot: profile views from diffusion models tend to drift in identity and pose. Phase 5 adds an
  optional face-matcher check (frontal vs profile similarity score) that marks weak sets rather than silently
  keeping them.
- Later backends can plug into the same behaviour if Qwen isn't good enough, for example Arc2Face or a
  FLUXSynID-style pipeline for identity-consistent variants. Check their licences first: several are
  non-commercial only.

### 5.2 Fingerprints and palms: procedural service (`python_biometrics/`)

Diffusion text-to-image models draw ridge patterns that look plausible but don't hold up biometrically. Singular
points, ridge continuity and minutiae are wrong. Use a **model-based (SFinGe-style) generator** instead:

1. **Master fingerprint** per finger:
   - Draw a class from realistic priors: whorl, loop L/R, arch, tented arch. Use finger-dependent weights, for
     example more whorls on thumbs and more ulnar loops on the index finger.
   - Place core and delta singular points and build the orientation field (Sherlock–Monro zero-pole model).
   - Build a density map.
   - Iterative contextual Gabor filtering from random seeds produces the ridge pattern.
   - The minutiae come out as a by-product; store them as ground truth (ISO 19794-2-like JSON).
2. **Impression** (called once per capture):
   - Contact region shape: elliptical for rolled prints, flatter and truncated for plain prints.
   - Displacement and rotation.
   - Non-linear skin distortion.
   - Pressure (dry/wet ridge thickness).
   - Noise, scratches and background.
   - Rolled vs plain changes the contact area and the distortion model.
3. **Slaps:** compose the four plain finger impressions of one hand with realistic finger layout and tilt on a
   1600 × 1500 canvas. Thumbs go side by side.
4. **Palms:**
   - Principal flexion creases (heart, head and life lines) as Bézier curves (BézierPalm approach).
   - A palm-scale orientation field, with interdigital, thenar and hypothenar regions and the triradii.
   - The same Gabor ridge synthesis.
   - Palm outline mask plus secondary creases.
   - The writer's palm is the hypothenar strip of the same full palm, so the two stay consistent.

Implementation route: a new, **CPU-only** FastAPI service in `python_biometrics/` (numpy, scipy, opencv-python,
pillow). It sits next to the Qwen service because it needs no GPU and starts in about a second. Evaluate the
open-source **Anguli** (C++, SFinGe-like) first as a baseline. It can be wrapped as a subprocess inside the same
service if its output quality is enough, which would save writing the generator from scratch.

API (all `POST`, JSON in, PNG out, plus ground-truth headers or JSON sidecar):

| Endpoint | Input | Output |
|---|---|---|
| `/finger/master` | `seed`, `finger` (1–10), optional `class` | PNG of the master print + `minutiae.json` |
| `/finger/impression` | `seed`, `finger`, `kind` (`rolled`/`plain`), `impression_seed` | PNG 800×750 |
| `/slap` | `seed`, `hand` (`right`/`left`/`thumbs`), `impression_seed` | PNG 1600×1500 |
| `/palm` | `seed`, `hand`, `kind` (`full`/`writers`), `impression_seed` | PNG |
| `/tenprint-card` | the 14 stored image keys, or the images as multipart | PNG card |
| `/health` | | `{"status":"ready"}` |

Everything is **deterministic from `(subject_seed, position, impression_index)`**. The service is stateless, so
Elixir never has to pass a "master" around: re-deriving it from the seed is cheap.

Later option: learned generators (PrintsGAN/GenPrint-style) for more realistic sensor texture. They go behind the
same behaviour and must pass the licence check first.

## 6. Data model (Postgres)

Generate each migration with `mix ecto.gen.migration`.

```
synthetic_batches
  id (uuid) | seed (bigint) | request (jsonb: what was asked for) | status (queued|running|done|failed)
  storage_backend (local|s3) | subject_count | completed_count | error | timestamps

synthetic_subjects
  id (uuid) | batch_id → batches | seed (bigint) | attributes (jsonb: sampled face attributes, finger classes)
  status | timestamps

synthetic_images
  id (uuid) | subject_id → subjects
  modality   (face | finger | slap | palm | card)
  position   (string: "F","L","R" | "1".."10" | "13","14","15" | "21".."24")
  capture    (portrait_icao | mugshot | rolled | plain | full | writers)
  impression (int, 0 = first)
  storage_backend | storage_key | content_type | byte_size | sha256
  width | height | ppi (nullable for faces)
  generator (e.g. "qwen-image-2.1", "procedural-sfinge/0.1") | seed (bigint) | prompt (text, faces only)
  quality (jsonb: NFIQ2 / OFIQ scores, later) | ground_truth_key (minutiae JSON, nullable)
  timestamps
  unique(subject_id, modality, position, capture, impression)
```

`seed`, `batch_id`, `subject_id` and the storage fields are set by the code, **not cast from params**.

### Storage key layout (the same for Local and S3)

```
<prefix>/batches/<batch_id>/manifest.json
<prefix>/batches/<batch_id>/subjects/<subject_id>/manifest.json
                                              face/portrait_icao_F.png
                                              face/mugshot_F.png  mugshot_L.png  mugshot_R.png
                                              finger/rolled_01.png … rolled_10.png
                                              finger/plain_02_i1.png          (extra impressions)
                                              finger/minutiae_01.json
                                              slap/plain_13.png  plain_14.png  plain_15.png
                                              palm/full_21.png  writers_22.png  full_23.png  writers_24.png
                                              card/tenprint.png
```

Every PNG also gets tEXt chunks, written in Python when the image is encoded:

- `Synthetic=true`
- `Generator=...`
- `Seed=...`
- `Subject=<uuid>`

The files stay identifiable as synthetic even when copied out of the system.

## 7. Configuration

`config/config.exs` (defaults) and `config/runtime.exs` (env overrides), following the existing `QWEN_*` pattern:

```elixir
config :phantom, :storage,
  adapter: Phantom.Storage.Local,           # or Phantom.Storage.S3
  local_root: Path.expand("../data/synthetic", __DIR__),   # outside priv/static, gitignored
  prefix: "synthetic"

# runtime.exs, when STORAGE_BACKEND=s3
config :phantom, :storage,
  adapter: Phantom.Storage.S3,
  bucket: System.fetch_env!("S3_BUCKET"),
  region: System.get_env("AWS_REGION", "eu-north-1"),
  endpoint_url: System.get_env("S3_ENDPOINT_URL"),          # MinIO etc.; nil = AWS
  access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
  presign_ttl: 3600

config :phantom, :biometrics_service_url, "http://localhost:8001"
config :phantom, :start_biometrics_service, true                # BIOMETRICS_AUTOSTART=false
config :phantom, :biometrics_req_options, []                    # Req.Test plug in test.exs
config :phantom, :biometrics,
  face_concurrency: 1,          # a single GPU, serialize Qwen calls
  ridge_concurrency: System.schedulers_online(),
  max_subjects_per_batch: 100
```

The UI shows the active backend read-only ("Saving to: local `data/synthetic`" / "Saving to: s3://bucket/prefix").
It is deliberately **not** a user-selectable field, so nobody can point output at an arbitrary bucket.

## 8. Job execution

- `Phantom.Biometrics.create_batch(params)` validates the request with an embedded-schema changeset, inserts the
  batch and subjects (subject seeds derived from the batch seed), and starts the `Runner` under
  `Phantom.Biometrics.TaskSupervisor`.
- The Runner builds a work list of `{subject, artifact}` items and runs it with `Task.async_stream(...,
  max_concurrency: n, timeout: :infinity)`. Face work and ridge work run in separate streams with their own limits,
  so fingerprints aren't stuck behind the slow GPU queue.
- Profiles depend on the frontal image, so within a subject the face work runs in order: frontal, then the other
  poses.
- After each image: `Storage.put`, insert the `synthetic_images` row, then
  `Phoenix.PubSub.broadcast(Phantom.PubSub, "biometrics:batch:#{id}", {:image_ready, image})`.
- A failure on one artifact marks that subject `failed` with the error and doesn't abort the batch.
- On app restart, batches left in `running` are marked `interrupted` at boot, and the UI offers **Resume**. Resume
  is safe because generation is deterministic and the unique index skips finished images.
- `Oban` would give persistence and retries without extra code. It's worth adopting if batches grow large, but it's
  a new dependency, so it isn't in v1.

## 9. LiveView: `PhantomWeb.BiometricsLive` (`/biometrics`)

Add a small nav in `Layouts.app` with links for "Images" (`/`) and "Biometrics" (`/biometrics`).

Layout (same visual language as `GenerateLive`):

1. **Service status bar:** health of both Python services, polled like `GenerateLive` does. Face options are
   disabled while Qwen isn't ready, and ridge options while the biometrics service isn't ready.
2. **Request form** (`id="biometrics-form"`, `to_form` of an embedded `BatchRequest` changeset):
   - Number of subjects (1–`max_subjects_per_batch`)
   - Checkboxes: ICAO portrait · Mugshot set (F/L/R) · ¾ views · Rolled tenprint · Slaps · Palms · Tenprint card
   - Extra impressions per finger (0–5), and per palm (0–2)
   - Optional demographic constraints (sex, age band), otherwise random
   - Batch seed (optional, random if blank)
   - Estimated work: "12 face images (~6 min on GPU), 240 ridge images"
   - `Generate` button (`id="biometrics-generate"`)
3. **Active batch progress** (`id="batch-progress"`): progress bar from `completed/total`, updated through PubSub.
4. **Subjects grid** (`phx-update="stream"`, `id="subjects"`): one card per subject (`id="subjects-<uuid>"`) with
   the frontal face thumbnail, a 10-finger mini strip and palm thumbnails, filling in live as images arrive. Uses
   `stream_insert` on each update.
5. **Subject detail** (`/biometrics/subjects/:id`): all images at full size with position labels, seeds and
   quality scores. Buttons: download the subject as a zip (built with `:zip` from the Erlang stdlib and streamed by
   a controller), open `manifest.json`, regenerate one image.
6. **Recent batches** list (`id="batches"`), to reopen earlier results.

Image `src` comes from `Phantom.Storage.url(key)`: `/files/...` for local storage, a presigned URL for S3.

## 10. Tests

| File | Covers |
|---|---|
| `test/phantom/storage/local_test.exs` | put/get/url/delete in a `tmp_dir`, rejects `..` keys |
| `test/phantom/storage/s3_test.exs` | `Req.Test` plug asserts PUT path, `authorization` header present, and the presigned URL shape |
| `test/phantom/biometrics/positions_test.exs` | codes and pixel sizes |
| `test/phantom/biometrics/face_attributes_test.exs` | same seed gives the same attributes and prompt |
| `test/phantom/biometrics_test.exs` | `create_batch` validation, the runner end to end with both services stubbed through `Req.Test` and the Local adapter on `tmp_dir`: correct rows, keys, manifest |
| `test/phantom_web/live/biometrics_live_test.exs` | form renders (`#biometrics-form`), validation errors, submit creates a batch, the PubSub `{:image_ready, _}` message adds or updates the subject card, disabled state while services are down |
| `python_biometrics/tests/` (pytest) | determinism (same seed gives the same bytes), output sizes and 500 ppi DPI metadata, minutiae JSON schema |

Use `start_supervised!` for the runner and task supervisor in tests, and assert on `{:DOWN, ...}` or PubSub
messages rather than sleeping.

## 11. Phases

1. **Storage abstraction**
   - `Phantom.Storage` with the Local and S3 adapters, `StorageController`, and config.
   - Refactor `ImageGeneration` into generate and store.
   - `GenerateLive` doesn't change behaviour; it can move onto `Storage` later.
2. **Schema and skeleton UI**
   - Migrations, schemas, the `Biometrics` context, `Positions`.
   - `BiometricsLive` with the form, the batch list and the nav link.
   - The runner with a fake generator.
3. **Faces**
   - `FaceAttributes`, `FaceGenerator.Qwen`, the ICAO and mugshot templates, profiles conditioned on the frontal.
   - Tune the prompts on real output.
4. **Fingerprints**
   - `python_biometrics` service and `Phantom.PythonService` generalisation.
   - Rolled prints first (compare Anguli with our own implementation), then plain impressions, slaps, extra
     impressions and the tenprint card.
5. **Palms:** full and writer's palms.
6. **Quality and packaging (optional)**
   - NFIQ 2 on fingers and OFIQ on faces, stored in `quality` and used to filter or flag.
   - Face-matcher consistency check across poses.
   - Zip export; ANSI/NIST-ITL Type-2/10/14/15 packaging with Type-2 fields clearly marked as test data; WSQ via
     NBIS `cwsq`. Done, except the quality items: see [`nist-export-plan.md`](nist-export-plan.md).

Run `mix precommit` at the end of each phase.

## 12. Risks and open questions

- **What synthetic data can and can't prove.** Good for functional, integration, format and load testing. Weak
  evidence for matcher accuracy (FAR/FRR), and the docs and UI should say so.
- **Accidental resemblance to real people.** Generated faces and prints can match real people by chance, and
  model-generated faces can leak training identities. Mitigations:
  - Every file is tagged as synthetic, both in its PNG metadata and in `manifest.json`.
  - Batches must never be sent to production or live-exchange systems. A banner on the page says this.
- **Licences.** Qwen-Image-2.1's licence and any later face or fingerprint models need checking for this use (many
  are non-commercial only).
- **Profile-view quality** from Qwen is unproven. Phase 3 should start with a short spike on about 20 identities
  before building the full UI around it.
- **Procedural fingerprint realism.** A SFinGe-quality generator takes real work, so decide early (end of the
  phase 4 spike) between Anguli and writing our own.
- **Open questions for you:**
  1. Which EBTS/ANSI-NIST profile is the target (FBI EBTS, Interpol INT-I, national)? This fixes image sizes and
     whether `.an2` export matters. *Answered 2026-09-25:* INTERPOL. The export does the base standard in
     Traditional encoding first (as abis_next does); INT-I v6 is XML only and comes later.
  2. Is S3 AWS itself or an on-prem S3-compatible store (MinIO, Ceph)? This affects defaults and presigning.
  3. Are 1000 ppi images needed, or is 500 ppi enough? *Answered 2026-09-25:* 500 ppi, unless a target ABIS
     needs 1000 ppi; see [`image-resolution.md`](image-resolution.md).
  4. Is Oban acceptable as a dependency, or should jobs stay in-process?
