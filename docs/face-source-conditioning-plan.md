# Plan: condition the anchor on faces from open datasets

Status: Phase 1 done 2026-09-25, go criterion not met (§7). The run diversity gate from §8 is built for
text-only anchors (2026-09-27, [Face gate](synthetic-biometrics.md#face-gate)); the pool (`face-pool.md`) stays
for a later attempt. An identity-first pilot (Arc2Face identities as Qwen's reference, §8) gave anchors about as
far apart as real strangers; cleaning the reference with a Qwen edit and matching the identity to the
subject's age keep the identity in the anchor (§8, 2026-09-28).

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
   This is the diversity guarantee. Built for text-only anchors: `Phantom.Biometrics.FaceGate`.
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

*Full set, 2026-09-25* (16 subjects: Northern European and West African, 4 women and 4 men each; "same group" is
the 24 pairs of the same ancestry and sex, where look-alikes matter):

| References | Mean similarity, same group | Max | Similarity to closest input, median / max | Inputs above 0.40 |
|---|---|---|---|---|
| none (text-only `faces-v13`) | 0.266 | 0.46 | – | – |
| degraded, k = 3 | 0.322 | 0.47 | 0.16 / 0.32 | 0 / 16 |
| degraded, k = 5 | 0.346 | 0.55 | 0.15 / 0.27 | 0 / 16 |
| mid, k = 3 | 0.195 | 0.43 | 0.41 / 0.70 | 9 / 16 |
| mid, k = 5 | 0.206 | 0.36 | 0.33 / 0.67 | 6 / 16 |
| raw, k = 5 | 0.213 | 0.33 | 0.37 / 0.61 | 7 / 16 |

What that shows:

- **Diversity only improves by copying.** Mid and raw references lower similarity between subjects, but because
  the anchor takes most of one input's identity (up to 0.70, plainly the same person), not because it blends
  them. Qwen doesn't follow "a blend of these faces, not any one of them".
- **Degraded references are safe but make faces more alike.** Blurred greyscale faces pull the anchor towards
  an average face, and the strong features from the text prompt are lost (same-group similarity 0.32–0.35,
  against 0.27 text-only).
- The reference prompts left out the `faces-v13` feature list, so they're not a pure comparison: degraded
  references *plus* the feature list is untested.
- Estimated age is off by 9–12 years with references, 8 text-only.

So the go criterion isn't met: no setting both lowers similarity and passes the gate. Options from here are in
§8.

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
- `Phantom.Biometrics.FacePool`: loads the index and embeddings, selects candidates, runs the gate. The
  templates come from `/face/embed` in the CPU biometrics service (`python_biometrics/faces.py`, built for the
  run gate), with the same models as the pool; the pool check would load the pool's embeddings there too.
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
- **Run diversity gate for text-only anchors.** Done, 2026-09-27: step 4 of §6 without a pool. An anchor
  above 0.35 to another subject of the run is rendered again with the next seed and features, up to 5 times
  ([Face gate](synthetic-biometrics.md#face-gate)).
- **Identity-first generation.** Sample well-separated identity embeddings (like [HyperFace][hyperface] or
  [Vec2Face][vec2face]) and render them with an identity-conditioned model. The most principled route to
  separation, and the most work.

  *Pilot, 2026-09-27: [Arc2Face][arc2face] identities as Qwen's only reference.* Text alone can't do it: one
  prompt with 8 seeds gives the same man (median 0.53, see
  [Face diversity](synthetic-biometrics.md#face-diversity)). So the identity comes first:

  1. Embed FairFace's 3,246 frontal adult White men with Arc2Face's own ArcFace (WebFace42M, not `buffalo_l`),
     fit a Gaussian (mean and covariance) and sample 12 identities from it, each below 0.1 to the others and
     below 0.3 to every pool face (in that space).
  2. Render each with Arc2Face (Stable Diffusion 1.5, 25 steps, guidance 3; about 1 s on the 4090): a 512² face
     from the embedding alone.
  3. Render the anchor with Qwen and that face as the only reference, prompted as an edit: keep the face,
     change age, skin, eyes, hair, beard and clothing to the subject's (subjects 1–12 of the face-gate run),
     no glasses or hat, neutral, the booking setup. No feature list.

  Measured with `buffalo_l` against the same 12 subjects rendered text-only:

  | | Between people, median / p90 / max | Pairs ≥ 0.3 | Nearest FairFace face |
  |---|---|---|---|
  | Text-only `faces-v13` (before the gate) | 0.21 / 0.33 / 0.59 | 14 / 66 | – |
  | Arc2Face faces | 0.03 / 0.14 / 0.21 | 0 / 66 | 0.25–0.30 |
  | **Qwen anchors from them** | **0.08 / 0.20 / 0.28** | **0 / 66** | **0.24–0.29** |
  | Real White men (FairFace) | 0.01 / 0.09 / about 0.17 | about 0 | median 0.30 |

  - **The spread is close to real strangers**, from sampling the identities apart, not from what Qwen draws.
    The gate would have nothing to reject.
  - **The anchor keeps some of its identity, not all:** 0.31–0.78 to its Arc2Face face (median 0.54), and at
    most 0.17 to any other identity. That's what makes it a new person, not a copy of a synthetic one.
  - **No leakage:** each anchor's nearest real FairFace face is 0.24–0.29, where a real man's nearest stranger
    is (median 0.30).
  - **Realistic booking photos** with Qwen's setup, age, hair and clothing, though framed tighter than
    text-only anchors: Qwen copies the reference's close-up. Pad the reference to the mugshot's framing, or
    say how large the head is.
  - Arc2Face's own images are web snapshots (glasses, hats, grins, odd light); Qwen cleans that up. A few
    faces carry over a strained look (identity 6).
  - Arc2Face's code and weights are MIT; it was trained on WebFace42M, a research-only set of web-scraped
    faces. Fine for Phantom, which is research; the leakage check against the pool stays.

  Looked at closely, two problems: some identities are odd (the pilot's identity 6 stares wide-eyed with a red
  nose, and its anchor copied both), and Arc2Face's faces often look smooth and plastic.

  *Second round, 2026-09-27: 24 identities, cleaner references, mugshot framing.* Scripts, setup and outputs:
  [`python_inference/experiments/identity_first/`](../python_inference/experiments/identity_first/README.md).

  - **Picking a sample doesn't fix an identity.** Four Arc2Face samples per identity, screened with the face
    pool's rules (pose, eyes, mouth, glasses, headwear, expression, photo type): only 11 % of samples pass
    them all, and only 8 of 24 identities have a passing one. Glasses, caps, sunglasses, grins and colour casts
    belong to the identity (Arc2Face learned them from WebFace's web photos) and come back in every sample.
  - **Sampling closer to the mean doesn't either.** Identities at temperature 0.8 and 0.6 (the covariance
    scaled down) gave the same spread, pass rate and leakage as 1.0: the group mean is short (0.10), so after
    normalising, the direction is still mostly noise.
  - **No usable detector for "odd" or "plastic".** Identity 6's eye openness was normal (0.37; the white
    around the iris is what showed). A CLIP "wide-eyed stare" label put both its samples first of 24, but
    real FairFace faces score 0.98 at the 90th percentile, so it can only rank. A CLIP "plastic skin" label
    scored real FairFace photos 0.99 too.
  - **Qwen cleans up what it's given.** The 24 anchors from the best sample each, with the face feathered onto
    a 960×1280 mid-grey canvas where a text-only anchor has its eyes:

    | 24 Northern European men, ages 21–75 | |
    |---|---|
    | Between people, median / p90 / max | 0.08 / 0.19 / 0.29, no pair at 0.3 |
    | Pass the pool's rules (as text-only anchors, 10 of 12) | 23 of 24 |
    | Nearest FairFace face, median / max | 0.25 / 0.31 |
    | Identity kept, median (range) | 0.60 (0.04–0.81) |
    | Estimated age minus age, median | +9 (text-only +12; InsightFace reads these mugshots old) |

    Framed like text-only mugshots now, and by eye realistic and not plastic, including identity 6's (an
    ordinary older man).
  - **A bad reference loses the identity.** Every anchor that kept less than 0.4 of its identity came from a
    reference with a turned head, a grin or open mouth, sunglasses or a hat; clean references kept 0.61–0.81.
    Age matters a little (correlation −0.24). An anchor that loses its identity falls back towards Qwen's own
    face, so at scale those would look alike again.

  So the method works if the references are clean: frontal, neutral, no accessories.

  *Third round, 2026-09-28: clean the reference with a Qwen edit first.* The same 24 picks, each edited by Qwen
  into a frontal, neutral close-up on mid-grey (same man, age, hair and skin; no glasses or hat, mouth closed,
  colour-neutral light), then used for the anchor exactly as before (same prompt, framing and seeds).

  - **The edit keeps the identity and fixes the flaws.** Cleaned faces keep 0.84 of their Arc2Face face
    (median, range 0.56–0.97), and 23 of 24 pass the pool's rules, against 8 of 24 raw picks. The caps,
    glasses, grins, turned heads and colour casts are gone.
  - **Anchors from flawed references recover:**

    | 24 anchors | Raw reference | Cleaned reference |
    |---|---|---|
    | Between people, median / p90 / max | 0.08 / 0.19 / 0.29 | 0.07 / 0.17 / 0.29, no pair at 0.3 |
    | Identity kept, median (min) | 0.60 (0.04) | 0.59 (0.21) |
    | Identity kept, 16 flawed references / 8 clean ones (median) | 0.45 / 0.68 | 0.56 / 0.70 |
    | Anchors keeping less than 0.4 | 8 | 2 |
    | Pass the pool's rules | 23 | 23 |
    | Nearest FairFace face, median / max | 0.25 / 0.31 | 0.26 / 0.34 |
    | Estimated age minus age, median | +9 | +8 |

    From the cleaned face, the anchor keeps about 0.8 of it (median). The overall median doesn't move: the
    edit costs a little on references that were fine, and the gain is at the bottom (identity 2: 0.04 → 0.21,
    13: 0.26 → 0.54, 24: 0.34 → 0.64).
  - **Two stay weak:** identities 2 (0.21) and 5 (0.30), both young references made into men of 73 and 68.
    Probably the age change rather than the cleaning; not tested yet.
  - Costs one more Qwen render per subject (about 44 s on the 4090).

  So cleaning is the step to keep. Arc2Face's pose ControlNet and expression adapter are the alternative to the
  cleaning edit, not needed so far.

  *Fourth round, 2026-09-28: the age gap.* An anchor made much older or younger than its reference keeps less of
  it: across the 24, the gap between the subject's age and the cleaned face's apparent age (InsightFace)
  correlates −0.48 with how much of that face the anchor keeps. Two ways to close the gap, on the same cleaned
  faces, prompts and seeds:

  - **(a) Match ages:** give each subject the identity whose cleaned face looks closest to its age (Hungarian
    assignment over the 24; `match_ages.py`). The gap drops from a median of 17 years (max 45) to 10 (max 22).
  - **(b) Age in the cleaning edit:** the cleaning edit also makes the man the subject's age, so the anchor
    needn't.

  | 24 anchors | Cleaned | (a) age-matched | (b) aged when cleaned |
  |---|---|---|---|
  | Between people, median / p90 / max | 0.07 / 0.17 / 0.29 | 0.08 / 0.18 / 0.30 | 0.08 / 0.19 / 0.34 |
  | Identity kept, median (min) | 0.59 (0.21) | **0.64 (0.36)** | 0.60 (0.27) |
  | Anchors keeping less than 0.4 | 2 | **1** | 3 |
  | Kept from the reference sent, median (min) | 0.81 (0.38) | 0.80 (0.59) | 0.82 (0.66) |
  | Cleaned face kept from Arc2Face, median (min) | 0.84 (0.56) | 0.84 (0.56) | 0.77 (0.37) |
  | Pass the pool's rules: cleaned faces / anchors | 23 / 23 | 23 / 24 | 19 / 22 |
  | Nearest FairFace face, median / max | 0.26 / 0.34 | 0.27 / 0.34 | 0.26 / 0.33 |

  - **Matching ages works.** The anchor step no longer loses the identity (worst 0.59 of the face sent, against
    0.38), and the spread and leakage don't change. The one anchor below 0.4 (0.36) got identity 5, whose
    cleaning had already kept only 0.64. By eye the 24 are realistic and plainly different people.
  - **Ageing in the cleaning edit only moves the loss.** The anchor keeps its reference well, but the aged
    cleaning keeps less of the Arc2Face face, fails the rules more often, and the total is no better.
  - With 24 identities for 24 subjects the ages can't all match. In the app, sample more identities than
    subjects and pick by age, which should close most of the gap.

  So the recipe so far: sample identities, render with Arc2Face, clean with a Qwen edit, pick the identity by
  apparent age, then the anchor with the cleaned face as its only reference. Next: women and other groups, and
  the profiles and probes conditioned on these anchors.

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
[arc2face]: https://github.com/foivospar/Arc2Face
