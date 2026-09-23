# Synthetic friction-ridge service

A small FastAPI service that generates **synthetic fingerprints, slaps, palmprints and tenprint cards**
procedurally, for ABIS testing. It runs on the CPU and needs no model weights, GPU or network access. The
Phoenix app talks to it over HTTP on `localhost:8001` (`Bilder.Biometrics.FrictionRidge`).

Everything it produces is synthetic test data. Each PNG carries `Synthetic=true` text chunks, and the tenprint
card says so in its header.

## Setup and run

```bash
cd python_biometrics
./setup.sh                        # one time: creates .venv, installs requirements.txt
.venv/bin/python -m pytest        # optional: about a minute
```

`mix phx.server` starts `server.py` for you (see `Bilder.PythonService`) and stops it on shutdown. To run it
yourself, set `BIOMETRICS_AUTOSTART=false` for the Phoenix app and start `python server.py` (`PORT` defaults to
8001). Point the app at another host with `BIOMETRICS_SERVICE_URL`.

## API

`GET /health` returns `{"status": "ready"}`.

`POST /render` takes JSON `{"kind", "code", "seed", "capture", "label"}`:

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

The response is JSON:

| Field | Contents |
|---|---|
| `image` | 8-bit grey PNG, base64-encoded, 500 ppi |
| `width`, `height`, `ppi`, `generator` | Image facts and the generator version |
| `meta` | Ground truth for the image, described below |

`meta` depends on the kind:

| Kind | Ground truth |
|---|---|
| Finger | pattern class, cores and deltas, ridge period, minutiae (x, y, angle, ending or bifurcation) |
| Slap | each finger's pattern, cores and deltas, plus minutiae |
| Palm | the triradii a–d and t that are in view, plus optional loop patterns |

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
4. **Ground truth** (`minutiae.py`): minutiae are extracted from the clean warped ridge image before noise, by
   skeletonising it and using crossing numbers. Positions are in that impression's pixel coordinates.
5. **Card** (`card.py`): the rolled prints and slaps of one capture on an 8 × 8 inch FD-249 style layout.

Rough timings on 24 cores:

| Work | Time |
|---|---|
| Finger master | 2 s |
| Palm master | 25 s |
| Any further impression, including later captures | 0.1–3 s |

One subject with all 18 shots and 2 captures took about 1.5 minutes.

## Limitations

- **Realism:** this is plausible synthetic data for functional, integration and load testing. It isn't
  calibrated against real ridge statistics.
  - Minutiae density and ridge quality haven't been checked against NFIQ 2.
  - Palm ridge flow is a simplified model of real palm anatomy.
  - Loop cores come out a little angular.
- **Minutiae:** the ground truth is extracted per impression. Correspondences between two captures aren't
  given.
- **Formats:** the output is PNG only. WSQ and ANSI/NIST-ITL packaging are not done yet.
