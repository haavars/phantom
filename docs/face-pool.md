# Face pool: processing open face datasets

Status: FairFace processed, 2026-09-25. The code is `python_inference/face_pool/`; every other dataset goes
through the same steps, as a new adapter in `face_pool/datasets.py`, so the pool is uniform. Why the pool
exists: [`face-source-conditioning-plan.md`](face-source-conditioning-plan.md).

```bash
cd python_inference/face_pool && ./setup.sh     # once: CPU-only venv with InsightFace, CLIP
cd ..                                           # then, from python_inference/:
face_pool/.venv/bin/python -m face_pool download fairface
face_pool/.venv/bin/python -m face_pool all fairface      # stages 2-5, about 70 minutes on 24 cores
face_pool/.venv/bin/python -m face_pool report fairface   # what's usable, by group and age
face_pool/.venv/bin/python -m pytest -q face_pool/tests
```

## 1. Overview

Each dataset goes through the same five stages. Cheap stages run first, so the expensive ones only see faces
that can still pass.

| Stage | What | Tool | Output | Code |
|---|---|---|---|---|
| 1. Ingest | Read the dataset, give every image a pool id and labels in pool terms | per-dataset adapter | `index_all.parquet` | `datasets.py` |
| 2. Detect and embed | Find the face, measure it, ArcFace template; keep adults with one face | InsightFace `buffalo_l` | `images/`, `index.parquet`, `embeddings.npy` | `embed.py` |
| 3. Landmarks | Head pose, mouth and eye openness, greyscale | InsightFace `1k3d68` | `quality.parquet` | `landmarks.py` |
| 4. Screen | Glasses, headwear, occlusion, expression, photo type | CLIP zero-shot | `screen.parquet` | `screen.py` |
| 5. Filter | Thresholds from stages 2-4 decide what's usable | pandas | the `usable` set | `filters.py` |

On disk, per dataset (all under `data/`, which is outside git):

```
data/face_pool/
  raw/<dataset>/            the download, untouched
  <dataset>/
    images/<id>.jpg         the face image as the dataset has it (not re-encoded)
    index_all.parquet       every image, including the ones that failed a stage
    index.parquet           embedded faces, in embeddings order (column row)
    embeddings.npy          float16, N x 512, L2-normalised ArcFace templates
    quality.parquet         stage 3, for faces that passed stage 2's filters
    screen.parquet          stage 4, for faces that passed stage 3's filters
```

## 2. Stage 1: ingest

An adapter per dataset yields `(id, image bytes, labels)`.

- **Ids** are `<prefix>_<n>`, numbered across the whole dataset. Not per file: FairFace's two parquet files both
  number their rows from 0, and ids built from those collided and overwrote each other's images. Prefixes:
  `ff` FairFace, `fq` FFHQ, `ca` CelebA, `ut` UTKFace, `cf` Chicago Face DB, `sd` NIST SD 18, `lf` LFW.
- **Labels** in pool terms, `null` where the dataset has none (stage 2 estimates them later, §8):

  | Column | Values |
  |---|---|
  | `sex` | `male`, `female` |
  | `age_band` | `20-29`, `30-39`, `40-49`, `50-59`, `60-69`, `70+` (and under-20 bands, dropped); `age` in years where known |
  | `race` | FairFace's 7 groups: `White`, `Black`, `Indian`, `East Asian`, `Southeast Asian`, `Middle Eastern`, `Latino_Hispanic` |
  | `identity` | the dataset's person id where it has several images per person (CelebA, LFW, SD 18) |
  | `label_source` | `dataset` or `estimate` |

- Images are kept as the dataset has them, with no re-encoding, so what the pool holds is the source.

## 3. Stage 2: detect and embed

InsightFace `buffalo_l` (SCRFD detector with 5 landmarks, ArcFace `w600k_r50`, gender and age), on the CPU.

- **Detector size** 256×256 for datasets of face crops (FairFace, UTKFace), 640×640 for full photos (FFHQ at
  1024², CFD, SD 18, CelebA in the wild).
- **Largest face** when there are several; the number found is recorded (`faces`), and 0 faces means no row.
- **Adults only:** faces labelled under 20 are skipped before detection. Phantom's subjects are 18 to 90.
- **Recorded per face:**

  | Field | Meaning |
  |---|---|
  | `det` | detector confidence |
  | `eye_dist` | pixels between the eye landmarks |
  | `yaw`, `roll` | rough head turn and tilt from the 5 landmarks (stage 3 replaces them) |
  | `sharp` | variance of the Laplacian over the face box |
  | `est_age`, `est_sex` | InsightFace's estimates, to check labels and to label unlabelled datasets |
  | `w`, `h` | image size |

- **Embedding:** the L2-normalised 512-d ArcFace template, stored as float16 in `embeddings.npy`; `index.parquet`
  row `row` is its position.

**First filters** (before stage 3):

| Rule | Why |
|---|---|
| `det >= 0.75` | a clear face |
| `eye_dist >= 60` px | enough detail for structure (FairFace crops are 224 px; about 80 px is typical) |
| `abs(yaw) <= 0.2`, `abs(roll) <= 10°` | roughly frontal |
| `sharp` above the dataset's 20th percentile | not blurred |
| `est_sex == sex` | drops mislabelled faces |

## 4. Stage 3: landmarks

InsightFace's 68-point 3D landmark model (`1k3d68`) on the faces that passed stage 2's filters.

| Field | How |
|---|---|
| `pitch`, `yaw3d`, `roll3d` | head pose in degrees, from the 3D landmarks |
| `mouth_open` | inner lips (iBUG points 62–66) over mouth width (48–54) |
| `eye_open` | eye height over width, mean of both eyes (37–41, 38–40, 43–47, 44–46 over 36–39, 42–45) |
| `grey` | mean absolute difference between colour channels; about 0 for black and white |

Filters:

| Rule | Why | FairFace kept (alone) |
|---|---|---|
| `grey >= 10` | colour photos (Phantom renders colour) | 97.5 % |
| `-14 <= pitch <= 6` | the pose model reads frontal faces at about -4°; ±10° around that | 80.5 % |
| `abs(yaw3d) <= 12` | frontal | 65.5 % |
| `abs(roll3d) <= 8` | head level | 99.4 % |
| `eye_open >= 0.22` | eyes open | 92.6 % |
| `mouth_open <= 0.12` | mouth closed or nearly: 0.06 rejected many closed-lip faces (median is 0.115) | about 55 % |

The 5-landmark `yaw` from stage 2 misses head tilt up or down; the first pilot picked a face with the head thrown
back and the mouth open, which is why this stage exists.

## 5. Stage 4: CLIP screen

Accessories and occlusion aren't visible to landmark models (they place eyes behind sunglasses). A CLIP
zero-shot screen scores each face against groups of text labels; each group is a softmax over its own labels.

- Model: open_clip `ViT-B-16`, `laion2b_s34b_b88k`, on the CPU (about 11 faces/s with 24 threads).
- Label groups (every label is "a close-up photo of a face …" unless noted):

  | Group | Labels |
  |---|---|
  | `eyewear` | no glasses · eyeglasses · sunglasses |
  | `head` | bare head and visible hair · hat or cap · headscarf or hijab · helmet, hood or headband |
  | `occlusion` | nothing in front · partly covered by a hand, drink, microphone or object |
  | `expression` | neutral, closed mouth · smiling broadly, showing teeth · open mouth, talking or shouting |
  | `photo` | colour photograph of a real person · black and white photograph · painting, drawing, cartoon or statue · heavily filtered or edited selfie |

- Filters, set by looking at contact sheets of faces in each score range on FairFace:

  | Rule | Why | FairFace kept (alone) |
  |---|---|---|
  | `eyewear_glasses + eyewear_sunglasses < 0.25` | no glasses of any kind; at 0.35 some glasses still got through | 59 % |
  | `head_hat < 0.8` | only clear hats: on tight crops CLIP reads "hat" when the top of the head is cut off, so 0.3–0.7 is mostly bare heads | 85 % |
  | `head_scarf + head_other < 0.5` | no headscarf, hood or helmet | 90 % |
  | `occlusion_covered < 0.6` | nothing in front of the face; 0.3–0.5 is mostly clear faces | 87 % |
  | `expression_smile + expression_open < 0.5` | no broad smile or open mouth; 0.5–0.8 is mostly smiles showing teeth | 58 % |
  | `photo_bw + photo_art < 0.3` | a photograph, not a drawing; `photo_filtered` isn't used (it scores ordinary photos) | 98 % |

Glasses are excluded, not only sunglasses: a reference with glasses tends to carry them into the anchor, and
Phantom adds glasses itself in the glasses probe.

## 6. Selecting faces for a subject

From the usable set, for a subject with sampled sex, age and ancestry:

- **Candidates:** the same sex, an age band overlapping age ± 7 years, and a pool group that maps to the
  ancestry (the table in the plan, §4). With fewer than 10 × k candidates, the window widens by 5 years at a time
  (up to ± 25), so old subjects still get faces, if younger ones.
- **Order:** a permutation seeded from the subject seed and `"face_sources"`, so a subject always gets the same
  faces.
- **Picked:** the first k candidates, in that order, whose pairwise similarity is below 0.3, so no two look alike
  and one doesn't dominate the blend. With identities (§8), at most one image per identity.
- **Not reused** by another subject of the run.

## 7. FairFace

The first dataset through the process: [FairFace][fairface] (CC BY 4.0), the 0.25-margin crops at 224×224 from
the Hugging Face mirror `HuggingFaceM4/FairFace` (538 MB of parquet). Labels: 9 age bands, sex, 7 race groups;
every image is a different person, so no identity grouping.

| After | Faces |
|---|---|
| Ingest | 97,698 |
| Stage 2 (adults, one face, embedded) | 73,463 |
| Stage 2 filters | 30,775 |
| Stage 3 filters | 7,632 |
| Stage 4 filters: **usable** | **2,207** |

Usable faces by group:

| | Women | Men |
|---|---|---|
| White | 197 | 237 |
| Black | 57 | 110 |
| East Asian | 196 | 114 |
| Southeast Asian | 78 | 107 |
| Indian | 118 | 250 |
| Middle Eastern | 56 | 290 |
| Latino/Hispanic | 169 | 228 |

FairFace is mostly young (Flickr), and strict filtering leaves few older faces: only 2 White and 1 Black face over
70. Older subjects need the other datasets; until then, selection widens the age window until it has enough
candidates (§6).

Times on 24 cores: stage 2 about 45 minutes (8 worker processes × 3 threads, 35 faces/s), stage 3 about 12
minutes for 30,775 faces, stage 4 about 11 minutes for 7,632 faces (11 faces/s).

## 8. Other datasets

What each needs beyond the common stages:

| Dataset | Adapter notes | Labels | Special handling |
|---|---|---|---|
| FFHQ | 1024² aligned PNGs; detector at 640 | none | estimate sex and age (InsightFace), race group (FairFace's classifier); keep estimates with confidence ≥ 0.8 |
| CelebA | in-the-wild images; detector at 640 | sex (attribute `Male`), identity | race and age estimated; many images per identity |
| UTKFace | 200×200 aligned crops; file names hold age, sex, race | age in years, sex, 5 race groups | map UTK's `White, Black, Asian, Indian, Others` (`Asian` needs the estimator to split East and Southeast) |
| Chicago Face DB | studio photos, grey background | self-reported sex, age, race | mostly frontal, neutral; expect most to pass |
| NIST SD 18 | mugshot scans, often greyscale | sex | the `grey >= 10` rule rejects greyscale; either colourise nothing and keep them out, or relax the rule and send only degraded (greyscale) references from this set |
| LFW | 250×250 crops; detector at 256 | identity | race, sex and age estimated; overlaps CelebA identities |

**Across datasets**
- **Identity grouping:** faces with ArcFace similarity above 0.5 are joined into one pool identity, across
  datasets too (a celebrity can be in CelebA and LFW). Selection takes at most one image per identity, and the
  leakage gate compares against all images of an input's identity.
- **Estimated labels** are marked `label_source = estimate`, so selection can prefer dataset labels.

## 9. Known gaps

In the faces selected for the 16 test subjects after all filters, about 1 in 10 still has a problem:

- a pulled face (pouting, crossed eyes)
- glasses that got past the 0.25 cutoff
- harsh side lighting or deep shadow over half the face
- an object or another person at the edge of the crop

Candidates for more CLIP labels: "pulling a face", "harsh shadow over half the face". The degraded references
(greyscale, blurred) are less sensitive to lighting.

## 10. Running it

- **Adding a dataset:** a class in `datasets.py` with `name`, `prefix`, `det_size`, `download()` and `items()`
  (yielding image bytes and labels in pool terms), added to `DATASETS`. The stages and filters stay the same;
  thresholds change only after looking at contact sheets, and then for every dataset (and this doc).
- **Checked:** the package reproduces the first FairFace build (made with the experiment scripts): the same ids,
  labels, detector and landmark values, and embeddings to float16 precision.
- **Models:** InsightFace downloads `buffalo_l` to `~/.insightface` on first use. The parent process fetches it
  before starting workers (`insight.ensure_models`); workers downloading it at once collide.
- **Threads:** InsightFace builds its onnxruntime sessions without options, so each process uses a thread per
  core; 8 workers then run about 300 threads on 24 cores and go 4× slower. Patch
  `insightface.model_zoo.model_zoo.PickableInferenceSession.__init__` to pass `SessionOptions` with
  `intra_op_num_threads = 3` (replacing `onnxruntime.InferenceSession` after the import isn't enough: insightface
  subclasses it at import), and call `cv2.setNumThreads(1)`.
- **Licences:** InsightFace's models and most of these datasets are for non-commercial research, which is what
  Phantom is.

[fairface]: https://github.com/joojs/fairface
