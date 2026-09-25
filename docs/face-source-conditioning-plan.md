# Plan: condition the anchor on faces from open datasets

Status: proposal, 2026-09-25. Nothing built.

## 1. Goal and idea

Frontal anchors of different people look too alike. With the `faces-v11` prompts, ArcFace (buffalo_l) gives a
mean cosine similarity of **0.24** between *different* subjects of a run, and some pairs reach **0.47–0.51**.
Facial features in the prompt (`faces-v13`) bring the mean down to about **0.17** (see
[Face diversity](synthetic-biometrics.md#face-diversity)), still well above real strangers. The
best synthetic face datasets have non-mated scores centred around 0 ([survey][survey]), and 0.4 is roughly where a
matcher starts to call two faces the same person. The prompt carries about 30 bits per person, but almost none of
it goes into facial structure, and the diffusion seed changes little.

The idea: build a large local **pool** of real face images from open datasets, labelled with sex, age and
ancestry. For each subject, pick **several faces at random** from the part of the pool that matches the
subject's sampled attributes, and send them to Qwen as reference images with the anchor prompt. Qwen blends
them into a new face, like a morph. The pool contributes what the prompt can't: real variation in bone
structure, proportions and feature shape. The prompt still sets age, hair, clothing, pose and the booking-photo
setup. A **leakage gate** then checks that the result isn't too similar to any of its inputs, or to anyone else
in the pool.

## 2. Scope and what this changes

Phantom is a personal research project, so non-commercial and research-only licences are fine (§3).

This replaces a rule the docs state today: *"the only reference image is always one the harness generated
itself, so the tool can't be used to make 'mugshots' of a real person"* (`synthetic-biometrics.md`,
`synthetic-biometrics-plan.md` §126, `FacePrompts` moduledoc). The protection that rule gave moves to the
leakage gate (§6):

- Qwen copies a single reference closely (*"with a reference image, Qwen copies it unless every change is a
  concrete target state"*), so one source face would most likely come back as that person. Several faces at
  once, plus the gate, is what keeps a subject fictional.
- If the gate is built right, "SYNTHETIC TEST DATA - NOT A REAL PERSON" in the exports stays true.

Keep in mind:
- **Sharing.** Exports shared with colleagues (Tailscale, R2 links) would then contain faces derived from
  datasets with non-commercial or no-redistribution terms. That's fine for research use; the source datasets
  and their embeddings themselves are never shared.
- **Uploads stay off.** The biometrics UI still doesn't accept uploaded faces. The pool is a fixed local set of
  public datasets, not a way to point Phantom at a chosen person.

## 3. The pool: as many faces as possible

All datasets go into one pool with one label scheme. Rough sizes:

| Dataset | Images (identities) | Labels | Licence | Notes |
|---|---|---|---|---|
| [FairFace][fairface] | 108k (108k) | sex, age band, 7 race groups | CC BY 4.0 | Balanced across groups; small crops (~224 px, padding 0.25 version is better) |
| [FFHQ][ffhq] | 70k (70k) | none: auto-label (§4) | BY-NC-SA 4.0 | 1024² aligned; about 90 GB; also has a 128² thumbnail set |
| [CelebA][celeba] | 202k (10k) | 40 attributes incl. sex, "young" | non-commercial research | Many images per identity; celebrities |
| [UTKFace][utkface] | 23k | age in years, sex, 5 race groups | non-commercial research | Exact ages, ages 18–90 useful |
| [Chicago Face DB][cfd] + MR + INDIA | 827 | self-reported sex, age, race | non-commercial, local use only, no redistribution | Grey background, neutral, frontal: closest to a mugshot |
| [NIST SD 18][sd18] | 3,248 (1,573) | sex | free download | Real mugshots; old scans, 95 % male |
| [LFW][lfw] | 13k (5.7k) | none: auto-label | research | Overlaps CelebA identities |
| [DigiFace-1M][digiface], [ONOT][onot] | 1.2M, n/a | ONOT: some | non-commercial / CC BY 4.0 | Synthetic; optional extra sources, no real people |

Left out: **FHIBE** and **Casual Conversations** (terms allow evaluation only, participants can withdraw
consent) and the retracted **VGGFace2 / MS-Celeb-1M / MegaFace** (no consent, and not needed at this size).

After filtering (§4), expect roughly **250–350k usable adult faces from about 200k identities**. That's enough
for thousands of subjects, even in the smaller groups.

## 4. Building the pool

As run on FairFace, with the thresholds and numbers: [`face-pool.md`](face-pool.md). The outline:

`python_inference/face_pool/`, run per dataset (`python -m face_pool all <dataset>`):

1. **Download** into `data/face_pool/raw/<dataset>/` (outside git, like `data/synthetic/`).
2. **Detect and align** with InsightFace (`buffalo_l`: SCRFD detector plus 5 landmarks). Keep images with
   exactly one face.
3. **Quality filter**, dropping:
   - faces under 112 px between the ears (inter-eye distance ≥ 40 px)
   - head turned more than about 20° (from landmark pose) or tilted more than 15°
   - blurry faces (Laplacian variance), sunglasses, heavy occlusion
   - under-18s by label or estimate, since Phantom's subjects are 18–90
4. **Embed** with ArcFace (`w600k_r50`) to get a 512-d template per image, stored as float16. 350k × 512 × 2
   bytes is about 360 MB, so the whole pool fits in memory, and nearest-neighbour search is one matrix product
   (no FAISS needed).
5. **Label** in Phantom's terms:
   - Use the dataset's labels when it has them (FairFace, UTKFace, CFD, CelebA sex).
   - Otherwise estimate: FairFace's released classifier (7 race groups, sex, 9 age bands) and InsightFace's
     age and sex model. Store the estimate and its confidence, and drop low-confidence faces.
   - Map to Phantom's 11 ancestries. FairFace's 7 groups are coarser, so each maps to a set:

     | Pool group | Phantom ancestries |
     |---|---|
     | White | Northern, Southern, Eastern European (and North African in part) |
     | Black | West African, East African |
     | Indian | South Asian |
     | East Asian | East Asian |
     | Southeast Asian | Southeast Asian |
     | Middle Eastern | Middle Eastern, North African |
     | Latino/Hispanic | Latin American |

     A finer split (e.g. Northern vs Southern European) could come later from skin, eye and hair colour
     estimates, but the prompt already sets those.
6. **Group identities.** Many datasets have several images of one person (CelebA, LFW, SD 18), and the same
   person can appear in several datasets. Faces with similarity above 0.5 are joined into one pool identity. The
   gate (§6) compares against every image of an identity, and selection never picks two images of one identity.
7. **Write the index**: `data/face_pool/index.parquet` (image id, dataset, file, identity, sex, age or age band,
   group, label source and confidence, quality scores, aligned crop path) and `embeddings.npy` in the same
   order.

## 5. Selecting the faces for a subject

- **Candidates** match the subject's sampled attributes:
  - same sex
  - age within ±7 years (or overlapping age band)
  - a pool group that maps to the subject's ancestry
- **k faces**, picked at random with `derive_seed(subject.seed, "face_sources")`, so a subject is reproducible:
  - from k different identities
  - not too alike each other (pairwise similarity < 0.3), so one doesn't dominate the blend
  - not used by another subject of the same run
- **k** is set by the Phase 1 experiment. Qwen takes up to 10 references; 3–5 is the likely range, since more
  faces means less of any one of them in the result, but also a more average face.
- **Stored** on the anchor image: the pool image ids, k, and the gate scores. Kept in the database only; never
  in the ZIP, NIST or share exports.

### Sending them to Qwen

The anchor stops being text-only: `Generator.Faces.references/2` returns the k aligned crops for the anchor.
The prompt says what to take from the references and what not, as concrete target states (the house rule):

> Police booking photograph (mugshot) of a new person whose face combines the facial proportions and feature
> shapes of the reference people, as a blend: not identical to any one of them. Take from the references only
> the bone structure, nose, eyes, eyebrows, mouth, jaw and ears. The age, skin, hair, clothing, expression,
> lighting and background come from this description instead: *(the usual `describe/1` sentence, clothing and
> setup)*.

Two preprocessing options to compare in Phase 1:

- **raw:** the aligned crops as they are
- **degraded:** greyscale, 64 px, blurred, then upscaled. Proportions survive, finer identity cues and the
  sources' skin, lighting and hair don't.

The prompt's feature list (`faces-v13`) can stay, compete with the references, or be dropped for pool anchors;
Phase 1 decides.

## 6. The leakage gate

Every anchor made from pool faces is checked before it's stored:

1. ArcFace embedding of the anchor.
2. **Against its inputs:** similarity to every image of each input identity must be below **τ_input**.
3. **Against the whole pool:** the nearest neighbour must be below **τ_pool**, so the anchor hasn't drifted onto
   another real person.
4. **Against the run:** similarity to every earlier subject of the run must be below **τ_run** (0.35 to start).
   This is the diversity guarantee.
5. On failure, re-roll with a new set of faces (`derive_seed(subject.seed, {"face_sources", attempt})`), at most
   5 attempts, then fall back to the text-only anchor. Attempts and scores are recorded on the image and in the
   run report.

Both thresholds come from the pool itself, per group, since matchers score some groups differently. They
differ because the pool check compares against every face at once, and the best of 73,000 comparisons is
naturally much higher than one comparison:

- **τ_input**: the 99.9th percentile of similarity between two *different* pool faces. On FairFace: 0.25 White,
  0.28 Black. The anchor looks no more like any of its inputs than two random strangers do.
- **τ_pool**: how close a *real* face's nearest stranger in the pool is, median (same-person duplicates above
  0.45 left out). On FairFace: 0.30 White, 0.33 Black. The anchor is no closer to any real person than a typical
  real person is to their nearest stranger.

The first version used τ_input for both. Then even text-only anchors, which never saw a pool face, "failed"
against the pool (nearest neighbour 0.29), which is how the difference showed up.

The other face shots (profiles, probes) are conditioned only on the anchor, as today, so they need no gate of
their own. The anchor is the only image that sees pool faces.

## 7. Phases

**Phase 1: Offline experiment.** No app changes; scripts in a scratch directory, as with the prompt experiments.
FairFace is enough to start, since it has labels.

*Pilot, 2026-09-25* (4 subjects, one per sex and ancestry, 9 settings, pool faces sent at
`reference_resolution` 512):

| References | Similarity to own inputs | Nearest pool face | Gate |
|---|---|---|---|
| none (text-only `faces-v13`) | – | 0.29 | passes |
| raw, k = 1–5 | 0.39–0.46 | 0.41–0.48 | **fails**: the anchor partly copies the inputs |
| degraded (greyscale, 48 px, blurred), k = 1–5 | 0.14–0.19 | 0.27–0.28 | passes |

Raw faces leak identity, and more of them dilutes it only a little (k = 5: 0.39). Degraded ones pass, but change
the face only subtly. The prompt keeps the booking setup, hair and clothing in every setting. Estimated age drifts
more with references (10–18 years off, against 6 text-only), to be checked on the full set. Next: all 16 subjects
with text-only, k = 3 and 5 degraded, a "mid" degradation (greyscale, 96 px, lighter blur) and k = 5 raw as the
leakage reference.

- 16 subjects (8 women, 8 men) from two ancestries, the same noise seeds throughout.
- Grid: k ∈ {1, 2, 3, 5} × {raw, degraded}, plus the text-only `faces-v13` anchor as the baseline.
- Measure for each cell:
  - diversity: mean, 90th percentile and max similarity between different subjects, and the share of pairs above
    0.3 and 0.4
  - leakage: max similarity to own inputs and nearest neighbour in the pool, against τ_leak
  - adherence: does the anchor still match the prompt's age, sex, hair and setup (visual check plus the
    classifiers from §4)
  - realism: visual check for blending artefacts, e.g. mismatched eyes or doubled features
- **Go:** some cell lowers mean non-mated similarity to ≤ 0.12 with nothing above 0.4, and passes the gate for
  ≥ 90 % of subjects on the first attempt.

**Phase 2: The pool.** The build script for all datasets in §3, the index, and a small report per group: how
many faces, by age band and sex, so thin groups are visible (older women in some groups will be scarce).

**Phase 3: In the app.**
- `Phantom.Biometrics.FacePool`: loads the index and embeddings, selects candidates, runs the gate. The gate
  runs in `python_inference` (a `/face/embed` endpoint next to `/generate`), since the embeddings and ONNX models
  live there.
- A run option **Face source: text only / pool**, recorded on the run like `prompt_version`. Default: pool once
  Phase 1 has passed.
- Storage fields, tests (deterministic selection, filtering, identity exclusion, the gate's re-roll and fallback)
  and docs, including the reworded "only generated references" statements.

**Phase 4: Check at scale.** A 100-subject run per ancestry. The run report shows the non-mated similarity
distribution, gate scores and re-roll rate, like the NIST checks for prints.

## 8. Complements

Worth doing whatever Phase 1 shows:

- **Prompt structure.** Done: `faces-v13` (face first, two features called out). The source-conditioned
  prompt in §5 should keep that structure.
- **Run diversity gate for text-only anchors.** Step 4 of §6 works without a pool: re-roll the anchor (next seed
  and features) if it's above 0.35 to an earlier subject.
- **Identity-first generation.** Sample well-separated identity embeddings (like [HyperFace][hyperface] or
  [Vec2Face][vec2face]) and render them with an identity-conditioned model. The most principled route to
  separation, and the most work.

## 9. Open questions

- Does blending k faces give a *new* face, or an average one? If k = 5 converges on a "mean face", diversity
  could drop again. Phase 1's diversity numbers answer this, and a mix (k = 2–3, faces not alike) is the hedge.
- Do the references drag in their own age, skin tone or hair despite the prompt? The degraded mode is the
  counter; adherence checks will show it.
- Is ±7 years right, or should the age filter be tighter for young subjects and looser for old ones, where the
  pool is thinner?

[survey]: https://arxiv.org/html/2510.17372v1
[fairface]: https://github.com/joojs/fairface
[ffhq]: https://github.com/NVlabs/ffhq-dataset
[celeba]: https://mmlab.ie.cuhk.edu.hk/projects/CelebA.html
[utkface]: https://susanqq.github.io/UTKFace/
[cfd]: https://www.chicagofaces.org/
[sd18]: https://www.nist.gov/srd/nist-special-database-18
[lfw]: https://vis-www.cs.umass.edu/lfw/
[digiface]: https://github.com/microsoft/DigiFace1M
[onot]: https://arxiv.org/abs/2404.11236
[hyperface]: https://arxiv.org/pdf/2411.08470
[vec2face]: https://github.com/HaiyuWu/Vec2Face
