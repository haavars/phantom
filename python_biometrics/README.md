# Synthetic friction-ridge service

A small FastAPI service that generates **synthetic fingerprints, slaps, palmprints and tenprint cards** for
ABIS testing. The Phoenix app talks to it over HTTP on `localhost:8001` (`Bilder.Biometrics.FrictionRidge`).

It works in two stages, following [`docs/realistic-fingerprints-plan.md`](../docs/realistic-fingerprints-plan.md):

1. **Identity** (`ridgegen/`, CPU): a master ridge pattern per finger and palm, and per capture its placement,
   distortion and contact area. This fixes the ridges and the ground truth.
2. **Appearance:** a renderer turns a capture into pixels.
   - `procedural`: noise, blur and pressure models on the CPU. Fast, but it looks computer-generated.
   - `diffusion` (`diffusion.py`, GPU, optional): the procedural image run part-way through a latent diffusion
     model trained on real rolled prints, for real ink texture over the same ridges.

Every finger and slap is then **verified** (`verify.py`) with NIST tools, and re-rendered if the rendering
drifted from the ground truth.

Everything it produces is synthetic test data. Each PNG carries `Synthetic=true` text chunks, and the tenprint
card says so in its header.

## Setup and run

```bash
cd python_biometrics
./setup.sh --diffusion            # one time: .venv, NIST tools, and the diffusion renderer
.venv/bin/python -m pytest        # optional: about a minute and a half
```

`setup.sh` alone installs `requirements.txt` and the verification tools into `tools/` (gitignored):

- **NIST NBIS 5.0** (`mindtct`, `bozorth3`, `cjpegl`), built from source. It needs `gcc`, `make` and `curl`,
  and takes a few minutes. The script works around NBIS's old CMake files and GCC 10+.
- **NIST NFIQ 2.3**, unpacked from NIST's Ubuntu package (20, 22 or 24). On other systems, build it yourself
  and set `NFIQ2_BIN` and `NFIQ2_MODEL`.

Without the tools the service still renders, unverified. `--diffusion` adds the GPU renderer: CUDA torch and
`requirements-gpu.txt`, IMPOSE and taming-transformers at pinned commits, and IMPOSE's rolled-print checkpoint
(about 320 MB, from the authors' Google Drive). `GET /health` lists the renderers that are available.

`mix phx.server` starts `server.py` for you (see `Bilder.PythonService`) and stops it on shutdown. To run it
yourself, set `BIOMETRICS_AUTOSTART=false` for the Phoenix app and start `python server.py` (`PORT` defaults to
8001). Point the app at another host with `BIOMETRICS_SERVICE_URL`.

## API

`GET /health` returns `{"status": "ready"}`.

`POST /render` takes JSON `{"kind", "code", "seed", "capture", "label", "renderer", "strength", "verify", "attempts"}`:

| kind | code | Output | Size at 500 ppi |
|---|---|---|---|
| `finger` | 1–10 (FGP) | rolled finger | 800 × 750 |
| `slap` | 13 / 14 / 15 | right four / left four / two thumbs, plain | 1600 × 1500 |
| `palm` | 21 / 23 | right / left full palm | 2750 × 4000 |
| `palm` | 22 / 24 | right / left writer's palm | 875 × 2500 |
| `card` | – | FD-249 style tenprint card | 4000 × 4000 |

- `seed` identifies the synthetic person. Every image for one seed shows the same ten fingers and two palms.
- `capture` (0, 1, …) is a separate capture of them, for mated pairs.
- `label` is printed on the card.
- `renderer` is `procedural` (the default) or `diffusion`. It applies to fingers, slaps and the card; palms are
  always procedural. `strength` (default 0.35) is how far the diffusion renderer re-runs the image: higher
  looks more worn but drifts more.
- `verify` (default true) checks fingers and slaps; `attempts` (default 3, max 5) caps the re-renders.

The response is JSON:

| Field | Contents |
|---|---|
| `image` | 8-bit grey PNG, base64-encoded, 500 ppi |
| `width`, `height`, `ppi`, `generator` | Image facts and the generator version |
| `meta` | Ground truth for the image, described below |

`meta` depends on the kind:

| Kind | Ground truth |
|---|---|
| Finger | pattern class, cores and deltas, ridge period, minutiae (x, y, angle, ending or bifurcation), `renderer`, `verification` |
| Slap | each finger's pattern, cores and deltas, plus minutiae, `renderer`, `verification` (with per-finger results) |
| Palm | the triradii a–d and t that are in view, plus optional loop patterns |

`verification` holds:

| Field | Meaning |
|---|---|
| `nfiq2` | NFIQ 2 score 0–100 (the lowest finger for slaps) |
| `minutiae_recall` | share of the clean ridge map's minutiae that `mindtct` finds in the image |
| `minutiae_spurious` | share of the image's minutiae that aren't in the clean map |
| `mean_displacement_px` | mean distance between paired minutiae |
| `accepted` | recall ≥ 0.85, spurious ≤ 0.15 and NFIQ 2 ≥ 35 |
| `renderer`, `attempts`, `attempt` | the renderer, how many attempts were made, and which one (0-based) was returned |
| `missed`, `spurious` | the unpaired points: where the image drifted from the ground truth |
| `detected` | the image's minutiae `[x, y, angle, quality]` from `mindtct`, for matching |
| `fingers` | slaps: the same metrics per finger |

`POST /match` takes `{"templates": [minutiae, ...], "pairs": [[i, j], ...]}`, each template a `detected`
list, and returns `{"scores": [...]}`: NBIS `bozorth3` scores, one per pair. The Phoenix app uses it for the
mated and non-mated scores in a run's report.

## How it works (`ridgegen/`)

The generator follows the SFinGe approach (Cappelli, Maio, Maltoni).

1. **Master pattern:** one per finger and one per palm, cached, derived from `(seed, finger)` or
   `(seed, hand)`.
   - **Fingers** (`finger.py`):
     - A pattern class (arch, tented arch, left/right loop, whorl) is drawn from per-finger population
       priors: loops dominate, thumbs and ring fingers are often whorls, and ulnar loops point towards the
       little finger.
     - The class places the singular points (cores and deltas).
     - A Sherlock–Monro zero-pole model gives the orientation field, straightened near the tip and the crease.
   - **Palms** (`palm.py`):
     - Zero-pole flow with a triradius under each finger (a–d) and the axial triradius t, balanced by a core
       at the base of each finger and the thumb.
     - Optional interdigital and hypothenar loops.
     - Three principal flexion creases plus secondary ones, as Bézier curves.
     - A palm outline with finger-base scallops. The anatomy is mirrored for the left hand.
2. **Ridge growth** (`synthesis.py`):
   - Ridges grow from noise by repeated Gabor filtering tuned to the local orientation and ridge spacing
     (about 9–10 px at 500 ppi).
   - The filtering runs as FFTs, with one forward transform per pass shared by all 24 orientation bins.
   - Palms are grown at 250 ppi and upsampled, which keeps memory and time reasonable.
3. **Impression** (`impression.py`, `fingerprints.py`):
   - Every capture gets its own placement, rotation and smooth skin distortion.
   - The contact shape depends on the capture: rolled nail-to-nail, a flat fingertip plus middle phalanx for
     slaps, or the palm outline with a light hollow.
   - Pressure varies from dry and broken to heavy.
   - Pores, creases or scars, blur and sensor noise are added.
   `fingerprints.rolled_capture` and `slap_capture` return this geometry as an `impression.Capture` (clean
   ridge field, contact mask, ground truth), which any renderer can draw. `impression.render_capture` is the
   procedural renderer.
4. **Ground truth** (`minutiae.py`): minutiae are extracted from the clean warped ridge image before noise, by
   skeletonising it and using crossing numbers. Positions are in that impression's pixel coordinates.
5. **Card** (`card.py`): the rolled prints and slaps of one capture on an 8 × 8 inch FD-249 style layout,
   drawn with the requested renderer and verified like the individual shots.

## Diffusion renderer (`diffusion.py`)

The procedural image of a capture is noised to 35% of the way along the diffusion trajectory, then denoised by
IMPOSE's rolled-print latent diffusion model (Pan, Guan, Feng, Zhou, Tsinghua; code and weights Apache 2.0).
This is SDEdit. The ridge flow and minutiae come through, while the texture becomes the model's own: ragged
ridge edges, pores, uneven ink, broken contact at the edges. The seed comes from the subject seed, shot,
capture and attempt, so accepted images reproduce on the same GPU and software.

- **Strength:** at 0.35 about 97% of rolled attempts pass verification (recall 0.92). At 0.45 only about a
  third pass, and at 0.6 the model invents ridges (recall 0.55).
- **Speed and memory:** about 0.3 s per rolled print and 1 s per slap on an RTX 4090, with a peak of 1.9 GB
  and 6.5 GB of VRAM. The autoencoder's and UNet's attention are swapped for PyTorch's memory-efficient SDPA:
  the original attention needed about 18 GB for one rolled print.
- **Style:** the model is unconditional, so there is one acquisition style, inked rolled. Slaps come out as
  inked plain impressions. IMPOSE's ControlNet, the stage conditioned on a ridge map, renders contactless
  photos, not contact prints, so it isn't used.

Rough timings on 24 cores:

| Work | Time |
|---|---|
| Finger master | 2 s |
| Palm master | 25 s |
| Any further impression, including later captures | 0.1–3 s |

One subject with all 18 shots and 2 captures took about 1.5 minutes.

## Limitations

- **Realism:** the diffusion renderer makes rolled prints and slaps look inked, and NFIQ 2 scores are in a
  plausible range (rolled mean about 46, plain about 53). The patterns underneath aren't calibrated against
  real ridge statistics.
  - Palms are procedural only, and their ridge flow is a simplified model of real palm anatomy.
  - Loop cores come out a little angular; the diffusion model softens this but doesn't remove it.
  - In slaps, adjacent fingers can touch with hard seams, and the middle phalanx is a straight-edged patch.
- **Verification** checks the image against its own clean ridge map. Both sides use `mindtct`, so its errors
  largely cancel, but it says nothing about whether the pattern itself is realistic.
- **Minutiae:** the ground truth is extracted per impression. Correspondences between two captures aren't
  given. Its angles point the opposite way from ANSI/INCITS 378 (about 180° from `mindtct`'s).
- **Formats:** the output is PNG only. WSQ and ANSI/NIST-ITL packaging are not done yet.
