# Plan: realistic synthetic fingerprints (hybrid identity + diffusion rendering)

Status: phases 0 and 1 done, and a no-training version of phase 2a is in use, 2026-09-23. It builds on the
friction-ridge service described in [`synthetic-biometrics.md`](synthetic-biometrics.md) and
[`python_biometrics/`](../python_biometrics/README.md).

## Progress

**Phase 0, verification and baseline: done.**

- `setup.sh` builds NBIS 5.0 from NIST's source and unpacks NFIQ 2.3 from NIST's Ubuntu package into
  `python_biometrics/tools/`.
- `verify.py` implements section 4. Two changes from the design:
  - contact erosion is 24 px, since the clean map's hard edge produces false endings
  - `mindtct` minutiae below quality 20 are ignored on both sides
- The service verifies every finger and slap (slaps per finger) and retries up to 3 times. Results go into
  the ground-truth JSON and `subject.json`, the detail view and the tiles.
- Each run writes a `report.json`: outcomes, NFIQ 2 per impression type, and `bozorth3` mated against
  non-mated scores. The run page shows it.
- Procedural baseline:
  - rolled NFIQ 2 47 (39–56), plain 54 (48–63)
  - recall 0.98, spurious rate 0.01
  - mated `bozorth3` min 112, non-mated max 27
  - As expected, every procedural print passes: it's drawn straight from the ridge map. The thresholds
    stay at their starting values.

**Phase 1, IMPOSE spike: its ControlNet is a no-go, but its rolled LDM works as a refiner.**

- IMPOSE's ControlNet with our ridge maps renders *contactless* photos (grey, no ink), as feared in section 9.
- The **unconditional rolled-print LDM** can instead refine our procedural print by SDEdit: noise it part-way,
  then denoise. Results on 6–20 rolled prints per strength:

  | Strength | Recall | Spurious | Passes per attempt |
  |---|---|---|---|
  | 0.30 | 0.94 | 0.03 | 100% |
  | 0.35 | 0.92 | 0.04 | 97% (100% within 2) |
  | 0.40 | 0.87 | 0.07 | 70% |
  | 0.45 | 0.83 | 0.10 | 35% |
  | 0.60 | 0.55 | 0.42 | 0% |

  At 0.35 the prints get real ink texture (ragged edges, pores, uneven ink, broken contact edges) and keep
  their minutiae.

**Phase 2a, in use without training:** the `diffusion` renderer (`python_biometrics/diffusion.py`, SDEdit at
0.35) is the default in the form and in `mix biometrics.generate --renderer`. The procedural renderer is the
draft mode.

- It renders rolled prints, slaps (as one image) and the card. Palms stay procedural.
- A test run (3 subjects, 2 captures, 78 verified images): 77 accepted first time, 1 after a retry, none
  rejected.
  - rolled NFIQ 2 46 (40–55), recall 0.92
  - mated `bozorth3` min 114, non-mated max 30: the gap isn't narrower than the procedural baseline
- Gaps against this plan:
  - **No style input.** The model is unconditional, so everything is inked rolled.
  - **Slaps are rendered whole**, not per finger, and the procedural slap layout has visible seams.
  - The acceptance criteria in section 8 that need real prints, the blind visual check and the NFIQ 2
    comparison, haven't been run.

**Next:** a conditioned renderer (phase 2b, our own ControlNet) is still what's needed for acquisition styles
and livescan. It depends on open decisions 1–3 in section 10 (training data and licences). Phase 3's
per-finger slap rendering and layout fixes can go ahead without them.

## 1. Problem

The current friction-ridge images look computer-generated. The generator is a textbook SFinGe-style pipeline,
and its tells are:

- **Ridges are too regular:** constant width, smooth edges, near-constant spacing. There are none of the dots,
  islands, fragments or ragged edges real ridges have.
- **Texture from Gabor growth:** wavy, even-looking flow with minutiae spread too uniformly. The zero-pole
  orientation model makes loop cores angular.
- **Naive rendering:** Gaussian noise, blur and blotchy contact. There's no skin texture, ink spread, realistic
  ridge grey-level profile or scanner signature.

For Prüm/ABIS test data, **known ground truth matters more than photorealism**: we must know which impressions
should match and why. But test images that look obviously synthetic are less useful for integration tests,
quality gates (NFIQ 2) and vendor demos, and they may behave unlike real data in feature extraction.

## 2. Target design

The current state of the art is a two-stage hybrid. GenPrint (Grosz & Jain, MSU) is the reference for it and
IMPOSE uses the same idea. The key idea is **lock the ridges, let diffusion do the texture**:

```
 Identity (have)              Appearance (new)                    Verification (new)
 ─────────────────            ─────────────────────               ──────────────────────────
 master ridge pattern   ──►   capture warp of the master   ──►   re-extract minutiae from the
 (seed, finger):              → binarised ridge map         │    rendered image, compare with
  pattern class,              → ridge-conditioned           │    ground truth; NFIQ 2 score
  singular points,              diffusion renderer          │    accept ─► store image + metrics
  ground-truth minutiae         (+ style prompt: sensor,    │    reject ─► re-render with a new
                                 pressure, quality)         │              seed (max N), then
                                                            │              mark "failed"
```

1. **Identity: we already have this.** `ridgegen` masters give every finger a pattern class, singular points
   and, per capture, the warped clean ridge map with ground-truth minutiae in that impression's pixel
   coordinates. The masters don't need to look real; they are the skeleton.
2. **Appearance.** A diffusion model conditioned on the capture's binarised ridge map, ControlNet style,
   renders the realistic print: sensor texture, pressure, ink, noise. Its output is pixel-aligned with the
   conditioning map, so the ground-truth coordinates still apply. A text or style input chooses the
   acquisition type, for example "livescan optical", "inked rolled card", or "dry, low quality".
3. **Verification.** Diffusion hallucinates. It can add, remove or move ridges and minutiae, especially when
   the requested style doesn't suit the pattern. **Automated matchers don't catch this**, because they are
   built to tolerate exactly these variations. So every rendered impression is checked against its known
   minutiae, and impressions that drifted are rejected, not trusted.

The procedural renderer stays available as a fast, CPU-only **draft** mode.

## 3. Renderer options

| Option | What it is | Weights and licence | Fit |
|---|---|---|---|
| **IMPOSE** ([GitHub](https://github.com/Yu-Yy/IMPOSE)) | Latent diffusion for rolled prints, plus a ControlNet that generates more poses from a binarised ridge "anchor". 512×512 at 500 ppi. | Released, **Apache 2.0** | Best licence. Unknown: its conditioned stage outputs *contactless* prints, so we need to test whether it can render *contact* prints from our ridge maps. |
| **Own ridge-conditioned ControlNet** (the GenPrint approach) | Fine-tune a ControlNet on Stable Diffusion 1.5: input a binarised ridge map (plus a style prompt), output a realistic print. Trained on real prints paired with ridge maps extracted from them. | We train it. Base model SD 1.5 (CreativeML OpenRAIL-M). Data NIST SD302 (licence to check). | Full control over conditioning, sizes and styles, and it covers plain and slap impressions. Costs 1–2 days of training on the 4090 plus data preparation. |
| **GenPrint** ([arXiv](https://arxiv.org/abs/2404.13791)) | The reference for this design. | As far as we found, only the dataset is released (1.5M images, under a signed agreement), not the model. | We copy the method, not the model. The dataset could add training data if the agreement allows it. |
| **FPGAN-Control** ([GitHub](https://github.com/amazon-science/fpgan-control)) | A GAN with explicit identity and appearance control (device, pressure), trained on NIST SD302. 384 px. | Released, but **CC BY-NC 4.0** (non-commercial) | Probably ruled out for police or consultancy use. GANs do tend to give more distinct identities, which is useful as a comparison. |
| Keep procedural, tune rendering | Better ridge profiles, noise models, ink spread | Ours | Some gain, but still recognisably synthetic, as even mature SFinGe is. Kept as draft mode. |

**Decision gate:** IMPOSE if its ControlNet renders contact prints from our ridge maps and passes verification.
Otherwise train our own ControlNet.

## 4. Verification design

Verification is needed whichever renderer we choose, and it gives a baseline for today's procedural prints.

**Tools** (all public domain or open source, built by `python_biometrics/setup.sh`):

- **NBIS** from NIST:
  - `mindtct`: minutiae extraction, output as `.xyt`
  - `bozorth3`: minutiae matcher, used for score distributions
  - `cwsq`: WSQ encoder, and the conversion into formats `mindtct` reads
- **NFIQ 2** ([usnistgov/NFIQ2](https://github.com/usnistgov/NFIQ2)): quality 0–100 for 500 ppi images.

**Minutiae comparison** for each rendered impression:

1. Run `mindtct` on the rendered image, giving the detected set **D**.
2. Run `mindtct` on the clean binarised ridge map of the same capture, giving the reference set **R**. Using
   the same extractor on both cancels out `mindtct`'s own quirks. Our skeleton-based ground truth **G**
   stays as a sanity check.
3. Pair D with R using a one-to-one assignment (Hungarian), allowing a distance of 12 px (about 0.6 mm at
   500 ppi) and an angle difference of 30°. Only compare inside the eroded contact area.
4. Compute:
   - **recall**: paired / |R|
   - **spurious rate**: unpaired D / |D|
   - **mean displacement** of paired minutiae
   - a **drift map**: where the errors are, to spot the local hallucination described in the literature
5. Accept if recall ≥ 0.85, spurious rate ≤ 0.15, and NFIQ 2 is at least the class target (for example ≥ 35
   for rolled). These starting values get tuned on the phase 0 baseline.

**Batch-level checks** (reported for a run, not a gate for each image):

- **Mated vs non-mated `bozorth3` scores:** captures of the same finger should score high, different fingers
  and subjects low. This measures how distinct identities are, and flags colliding masters.
- **NFIQ 2 distribution** per impression type, compared with published figures for real data.

**Storage.** Results go into each image's ground-truth JSON and the `subject.json` summary:

- `nfiq2`
- `minutiae_recall`
- `minutiae_spurious`
- `mean_displacement_px`
- `renderer`
- `attempts`
- `accepted`

The detail view shows them, and the run page flags rejected or retried images.

## 5. Training our own ControlNet (if needed)

- **Data:** NIST SD302 (Nail-to-Nail), with rolled, plain and slap impressions from many capture devices.
  - Check its licence terms, and whether palm images are included.
  - The MSU GenPrint dataset could be added if its agreement is signed.
- **Pairs:**
  - Real print → orientation and frequency estimation → Gabor enhancement → binarised ridge map, which is
    the same kind of map our masters produce.
  - Keep only pairs whose enhancement is reliable, filtering on NFIQ 2 and the local orientation-coherence
    map.
- **Style labels** for the text prompt, taken from SD302 metadata: capture device or type (optical livescan,
  ink card, …), impression type (rolled or plain), and a quality band from NFIQ 2.
- **Training:**
  - ControlNet on SD 1.5, at 512×512 crops and 500 ppi native (no rescaling, so ridge spacing stays true).
  - fp16 on the RTX 4090, about 1–2 days.
  - Augmentation: rotation, small elastic warps, contrast.
  - A later improvement the literature suggests: a ridge-consistency term in the loss, penalising
    disagreement between the input map and the output's binarisation.
- **Inference sizes:**
  - Rolled: generate 800×752, crop to 800×750. Or tile 512 crops with overlap (MultiDiffusion) if full-size
    quality drops.
  - Slaps: render each plain finger separately, then composite as today.
  - Palms: tiled generation. Palms are the last phase, and depend on training data.

## 6. Integration into Bilder

| Area | Change |
|---|---|
| `python_biometrics` | A `renderer` option (`procedural` / `diffusion`) on `/render`. The diffusion renderer runs on the GPU with optional torch dependencies (a separate `requirements-gpu.txt`). New `verify.py` wraps NBIS and NFIQ 2 plus the minutiae comparison. The response includes the verification metrics. |
| Retry | The service renders, verifies, and re-renders with a new appearance seed up to N times (default 3). The identity is unchanged; only the diffusion seed changes. It returns the best attempt with `accepted: false` if none pass. |
| GPU sharing | Qwen (about 16 GB with offload) and SD 1.5 + ControlNet (about 4–6 GB in fp16) share the 24 GB card. The runner already renders one image at a time. If VRAM gets tight, load the renderer lazily and free it after a batch. |
| `Bilder.Biometrics.Shots` / `RunRequest` | A renderer choice and a style (sensor or acquisition type) on the form and in `mix biometrics.generate` (`--renderer`, `--style`). |
| UI | NFIQ 2 and minutiae recall in the detail view. A badge on rejected or low-quality tiles. Batch mated/non-mated score summary on the run page. |
| Determinism | Unchanged for identity (subject seed). The appearance seed is derived from (subject seed, shot, capture, attempt), so accepted images can be reproduced. |

## 7. Phases

| Phase | Work | Output | Estimate |
|---|---|---|---|
| **0. Verification and baseline** | Build NBIS + NFIQ 2 in setup; `verify.py`; minutiae comparison; metrics in JSON and UI; batch score report | Baseline numbers for today's procedural prints | 1–2 days |
| **1. IMPOSE spike** | Install in its own venv; generate unconditioned rolled prints; try its ControlNet with our warped ridge maps; run phase 0 metrics | Go/no-go on IMPOSE as the renderer, with sample images | ≤ 1 day |
| **2a. Integrate IMPOSE** (if go) | Diffusion renderer backed by IMPOSE, retry loop, style options | Realistic rolled prints in runs | 2–3 days |
| **2b. Own ControlNet** (if no-go) | SD302 preparation and pairing, training, evaluation against phase 0 metrics | Trained renderer weights plus an evaluation report | 4–6 days, including about 2 days of training |
| **3. Plain and slaps** | Plain impressions through the renderer, slap composition, style per capture | Realistic slaps | 1–2 days |
| **4. Palms** | Tiled rendering, if training data allows | Realistic palms, or palms stay procedural | 2–4 days |
| **5. Identity distinctness** (optional) | Reject masters whose non-mated scores are too high against the batch | Fewer accidental cross-subject matches | 1 day |

## 8. Acceptance criteria

- Blind visual check: a reviewer can't reliably pick the synthetic prints from a mix with real SD302 prints of
  the same type.
- NFIQ 2 distribution of accepted images falls within the range of real prints of the same impression type.
- Accepted impressions reach minutiae recall ≥ 0.85 and a spurious rate ≤ 0.15 against their ground truth.
  The rejection rate is reported for each run.
- Mated `bozorth3` scores are clearly separated from non-mated ones, and rendering doesn't narrow the gap
  compared with the procedural baseline.
- Everything remains deterministic and labelled synthetic: PNG text chunks and ground-truth JSON.

## 9. Risks

- **Hallucinated minutiae.** The main known weakness of diffusion renderers. It's handled by the verification
  gate and retries, and by limiting the style range for low-quality masters.
- **IMPOSE may only do contactless** in its conditioned stage. In that case we go to phase 2b.
- **Licences.** NIST SD302 terms, SD 1.5 OpenRAIL-M use restrictions, the GenPrint dataset agreement, and
  FPGAN-Control's non-commercial terms.
- **Training-data leakage.** A renderer trained on real prints could reproduce real ridge detail. Identity
  comes from our masters, which lowers this risk, but it should be checked. Match a sample of synthetic
  images against the training set and require no hits above threshold.
- **GPU contention with Qwen** on one 24 GB card. Handled by lazy loading and one-image-at-a-time scheduling.
- **Extractor bias.** `mindtct` has its own error rate on real prints. Comparing it with itself on the clean
  map (section 4) isolates the renderer's drift.

## 10. Open decisions

1. Is **NIST SD302** (and SD 1.5 as the base model) acceptable for this use? If not, only the IMPOSE path
   remains.
2. Which **acquisition styles** matter most for your ABIS and Prüm flows? For example optical livescan versus
   inked cards, and which vendors.
3. Should we request the **MSU GenPrint dataset** under its agreement, as training or reference data?
4. Should the **latent-print** use case come into scope here? Latent synthesis needs surface and development
   styles, and has the same hallucination risk.

## References

- GenPrint: Grosz & Jain, MSU, TPAMI 2025, [arXiv 2404.13791](https://arxiv.org/abs/2404.13791)
- IMPOSE: [github.com/Yu-Yy/IMPOSE](https://github.com/Yu-Yy/IMPOSE) (Apache 2.0, weights released)
- FPGAN-Control: [github.com/amazon-science/fpgan-control](https://github.com/amazon-science/fpgan-control) (CC BY-NC 4.0)
- PrintsGAN: Engelsma, Grosz & Jain, TPAMI
- NFIQ 2: [github.com/usnistgov/NFIQ2](https://github.com/usnistgov/NFIQ2)
- NBIS (`mindtct`, `bozorth3`, `cwsq`): NIST Biometric Image Software
- SFinGe: Cappelli, Maio, Maltoni, the basis of the current `ridgegen` identity stage
- A 2026 MSU study of GenPrint's minutiae fidelity: identity is mostly preserved, but there are local minutiae
  errors on poor-quality references and global hallucination when the requested style doesn't suit the
  reference (from the input provided to this plan).
