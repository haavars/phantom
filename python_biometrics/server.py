"""Synthetic friction-ridge service: fingerprints, slaps, palmprints, tenprint cards.

CPU only, no model weights: patterns are generated procedurally (see ridgegen/).
The Phoenix app (Bilder.Biometrics.FrictionRidge) calls this over HTTP on
localhost:8001, and `mix phx.server` starts it (see Bilder.PythonService).

POST /render with JSON {"kind", "code", "seed", "capture"}:

  kind "finger"  code 1-10 (FGP)   rolled finger, 800 x 750
  kind "slap"    code 13, 14, 15   right four / left four / two thumbs, 1600 x 1500
  kind "palm"    code 21-24 (PLP)  21/23 right/left full palm 2750 x 4000,
                                   22/24 right/left writer's palm 875 x 2500
  kind "card"                      FD-249 style tenprint card, 4000 x 4000

`seed` identifies the synthetic person: every image for the same seed shows the
same fingers and palms. `capture` (0, 1, ...) selects a separate capture of
them, for mated pairs. Returns JSON with the 8-bit grey PNG (base64, 500 ppi,
tagged as synthetic) and metadata: pattern classes, singular points, and
ground-truth minutiae where applicable.

`renderer` picks how fingers, slaps and the card get their pixels:
"procedural" (the default, CPU) or "diffusion" (diffusion.py: realistic ink
texture from a model trained on real rolled prints, needs a GPU and
`setup.sh --diffusion`). The identity and ground truth are the same either way;
palms are always procedural.

Fingers and slaps are verified (see verify.py) when NBIS and NFIQ 2 are
installed: minutiae re-extracted from the rendered image are compared with the
clean ridge map, and NFIQ 2 scores it. An impression that fails is re-rendered
with new appearance randomness (the identity stays), up to `attempts` times, and
the best attempt comes back with `verification.accepted` false if none passed.

POST /match with {"templates": [minutiae, ...], "pairs": [[i, j], ...]}, where
each template is a list of [x, y, angle, quality] as in `verification.detected`
and pairs index into templates, returns {"scores": [...]}: NBIS bozorth3 scores,
for mated / non-mated reports.

Run with `python server.py` (PORT defaults to 8001).
"""

import base64
import io
import os
import sys
import threading
import time
from functools import lru_cache
from typing import Literal

from fastapi import FastAPI, HTTPException
from PIL import Image
from PIL.PngImagePlugin import PngInfo
from pydantic import BaseModel, Field

import diffusion
import verify
from ridgegen import card, fingerprints, palm
from ridgegen import impression as imp
from ridgegen.synthesis import rng_for

VERSION = "ridgegen/0.2"
PPI = 500

app = FastAPI(title="Synthetic friction-ridge service")

# Generation is CPU heavy and uses all cores itself (FFTs); running requests one
# at a time keeps memory bounded and results just as fast.
_lock = threading.Lock()


class RenderRequest(BaseModel):
    kind: Literal["finger", "slap", "palm", "card"]
    code: int | None = None
    seed: int = Field(ge=0, lt=2**32)
    capture: int = Field(default=0, ge=0, le=9)
    label: str = Field(default="", max_length=80)
    renderer: Literal["procedural", "diffusion"] = "procedural"
    strength: float = Field(default=diffusion.STRENGTH, ge=0.1, le=0.7)
    verify: bool = True
    attempts: int = Field(default=3, ge=1, le=5)


class MatchRequest(BaseModel):
    templates: list[list[list[float]]] = Field(max_length=5000)
    pairs: list[tuple[int, int]] = Field(max_length=20000)


@app.get("/health")
def health():
    renderers = ["procedural"] + (["diffusion"] if diffusion_available() else [])
    return {"status": "ready", "version": VERSION, "verification": verify.available(), "renderers": renderers}


@lru_cache(maxsize=1)
def diffusion_available():
    return diffusion.available()


@app.post("/render")
def render(request: RenderRequest):
    generate = dispatch(request)
    started = time.monotonic()
    with _lock:
        image, meta = generate()
    height, width = image.shape
    return {
        "image": base64.b64encode(encode_png(image, request)).decode("ascii"),
        "width": width,
        "height": height,
        "ppi": PPI,
        "generator": VERSION,
        "duration_ms": round((time.monotonic() - started) * 1000),
        "meta": meta,
    }


@app.post("/match")
def match(request: MatchRequest):
    if not verify.available():
        raise HTTPException(status_code=503, detail="NBIS isn't installed (run setup.sh)")
    count = len(request.templates)
    if any(not (0 <= i < count and 0 <= j < count) for i, j in request.pairs):
        raise HTTPException(status_code=400, detail="pair index out of range")
    with _lock:
        return {"scores": verify.bozorth3(request.templates, request.pairs)}


def dispatch(request):
    kind, code, seed, capture = request.kind, request.code, request.seed, request.capture
    if kind == "finger" and code in range(1, 11):
        return lambda: render_verified(fingerprints.rolled_capture(seed, code, capture), request)
    if kind == "slap" and code in (13, 14, 15):
        return lambda: render_verified(fingerprints.slap_capture(seed, code, capture), request)
    if kind == "palm" and code in (21, 22, 23, 24):
        hand = "right" if code in (21, 22) else "left"
        make = palm.full if code in (21, 23) else palm.writers
        return lambda: make(seed, hand, capture)
    if kind == "card":
        return lambda: card.card(seed, capture, request.label, render=lambda c: render_verified(c, request)[0])
    raise HTTPException(status_code=400, detail=f"unsupported kind/code: {kind}/{code}")


def render_verified(capture, request):
    """Render a finger or slap capture, verify it, and retry with new appearance if it fails.

    Returns the accepted attempt, or the best one when none passed.
    """
    if request.renderer == "diffusion" and not diffusion_available():
        raise HTTPException(status_code=503, detail=diffusion.unavailable_reason())
    meta = {**capture.meta, "renderer": renderer_name(request)}
    if not (request.verify and verify.available()):
        return render_capture(capture, request, 0), meta

    best = None
    for attempt in range(request.attempts):
        image = render_capture(capture, request, attempt)
        metrics = verify.verify(image, capture)
        if best is None or verify.score(metrics) > verify.score(best[2]):
            best = (attempt, image, metrics)
        if metrics["accepted"]:
            break
    kept, image, metrics = best
    # `attempt` (0-based) is the one returned; with the seed and capture it reproduces the image.
    verification = {"renderer": meta["renderer"], "attempts": attempt + 1, "attempt": kept, **metrics}
    return image, {**meta, "verification": verification}


def render_capture(capture, request, attempt):
    image = imp.render_capture(capture, attempt)
    if request.renderer == "diffusion":
        # The appearance seed follows (subject seed, shot, capture, attempt), like the rest.
        seed = int(rng_for(*capture.appearance_key, 202, attempt).integers(0, 2**31))
        image = diffusion.render(image, seed, request.strength)
    return image


def renderer_name(request):
    if request.renderer == "diffusion":
        return f"{diffusion.NAME}@{request.strength:g}"
    return "procedural"


def encode_png(image, request):
    info = PngInfo()
    info.add_text("Synthetic", "true")
    info.add_text("Comment", "Synthetic test data generated by Bilder. Not a real person.")
    info.add_text("Generator", VERSION)
    info.add_text("Seed", str(request.seed))
    info.add_text("Kind", request.kind)
    info.add_text("Code", str(request.code))
    info.add_text("Capture", str(request.capture))
    if request.kind != "palm":
        info.add_text("Renderer", renderer_name(request))
    buffer = io.BytesIO()
    Image.fromarray(image, mode="L").save(buffer, format="PNG", dpi=(PPI, PPI), pnginfo=info, optimize=False)
    return buffer.getvalue()


def exit_with_parent():
    """Exit when the Phoenix app that started us goes away.

    Bilder.PythonService starts this server with BILDER_EXIT_WITH_PARENT=1 and a
    pipe on stdin; the pipe closes when the BEAM exits, however abruptly (e.g.
    Ctrl+C twice skips the app's shutdown code). Without this, the server would
    keep running and hold the port, and the next `mix phx.server` couldn't
    start its own copy.
    """
    if os.environ.get("BILDER_EXIT_WITH_PARENT") != "1":
        return

    def watch():
        try:
            while sys.stdin.buffer.read(4096):
                pass
        finally:
            os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


if __name__ == "__main__":
    import uvicorn

    exit_with_parent()

    uvicorn.run(app, host=os.environ.get("HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8001")))
