"""Local inference server for Qwen-Image-2.1.

Loads the model once at startup and serves POST /generate (multipart/form-data:
`prompt`, `width`, `height`, `steps`, `seed`, and up to 10 `images` files for
image-conditioned generation, optionally `reference_resolution`), returning a PNG. The Phoenix app
(Phantom.ImageGeneration) calls this over HTTP on localhost.

Run with:

    python server.py

or:

    uvicorn server:app --host 127.0.0.1 --port 8000

See README.md in this directory for one-time setup.
"""

import io
import os
import sys
import threading
from typing import List, Optional

import torch
from fastapi import FastAPI, File, Form, HTTPException, Response, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from PIL import Image

MODEL_ID = os.environ.get("QWEN_IMAGE_MODEL", "Qwen/Qwen-Image-2.1")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
MAX_REFERENCE_IMAGES = 10
# Tiled VAE decoding keeps peak VRAM down for large images, but leaves faint
# vertical seams where its 256px tiles blend (every 192px), visible on flat
# backgrounds - bad for biometric test images. Only tile above this size; an
# untiled decode that still runs out of memory is retried with tiling.
VAE_TILING_MIN_PIXELS = int(os.environ.get("QWEN_VAE_TILING_MIN_PIXELS", "2000000"))

app = FastAPI(title="Qwen-Image-2.1 inference service")

_pipe = None
_pipe_lock = threading.Lock()
_load_error: Optional[str] = None


def _load_pipeline() -> None:
    global _pipe, _load_error
    try:
        from diffusers import QwenImage21Pipeline

        pipe = QwenImage21Pipeline.from_pretrained(MODEL_ID, torch_dtype=torch.bfloat16)
        if DEVICE == "cuda":
            # Keeps the ~7B DiT + text encoder + VAE resident within a single
            # 24GB consumer GPU by offloading idle submodules to CPU RAM.
            pipe.enable_model_cpu_offload()
            # VAE tiling is switched per request, see VAE_TILING_MIN_PIXELS:
            # decoding a full-resolution (e.g. 2752x1536) image untiled can
            # exceed 24GB of VRAM (confirmed via CUDA OOM at the decode step).
        else:
            pipe.to(DEVICE)
        _pipe = pipe
    except Exception as exc:  # noqa: BLE001 - surfaced to clients via /health
        _load_error = str(exc)


threading.Thread(target=_load_pipeline, daemon=True).start()


@app.get("/health")
def health():
    if _pipe is not None:
        return {"status": "ready", "model": MODEL_ID, "device": DEVICE}
    if _load_error is not None:
        return JSONResponse(status_code=500, content={"status": "error", "error": _load_error})
    return JSONResponse(status_code=503, content={"status": "loading", "model": MODEL_ID})


@app.post("/generate")
async def generate(
    prompt: str = Form(...),
    width: int = Form(1024),
    height: int = Form(1024),
    steps: int = Form(40),
    seed: Optional[int] = Form(None),
    images: List[UploadFile] = File(default=[]),
    reference_resolution: Optional[int] = Form(None),
):
    if _pipe is None:
        detail = _load_error or "model is still loading, try again shortly"
        raise HTTPException(status_code=503, detail=detail)

    prompt = prompt.strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt must not be blank")

    if not 1 <= steps <= 100:
        raise HTTPException(status_code=400, detail="steps must be between 1 and 100")

    if reference_resolution is not None and not 256 <= reference_resolution <= 1024:
        raise HTTPException(status_code=400, detail="reference_resolution must be between 256 and 1024")

    if len(images) > MAX_REFERENCE_IMAGES:
        raise HTTPException(
            status_code=400,
            detail=f"at most {MAX_REFERENCE_IMAGES} reference images are supported, got {len(images)}",
        )

    reference_images = []
    for upload in images:
        data = await upload.read()
        try:
            reference_images.append(Image.open(io.BytesIO(data)).convert("RGB"))
        except Exception as exc:
            raise HTTPException(
                status_code=400, detail=f"couldn't read image {upload.filename!r}: {exc}"
            ) from exc

    def run():
        generator = torch.Generator(device=DEVICE)
        if seed is not None:
            used_seed = seed
            generator.manual_seed(used_seed)
        else:
            used_seed = generator.seed()

        kwargs = dict(
            prompt=prompt,
            width=width,
            height=height,
            num_inference_steps=steps,
            true_cfg_scale=1.0,
            generator=generator,
        )
        if reference_images:
            # QwenImage21Pipeline accepts a single image or a list of up to
            # 10 reference/condition images for image-conditioned generation.
            kwargs["image"] = reference_images
            # Each reference is resized to about output_resolution² (1024² by
            # default, about 4096 tokens), whatever its own size. Small
            # references, several at once, fit in VRAM only at a lower one;
            # the output size is always passed, so this affects only them.
            if reference_resolution is not None:
                kwargs["output_resolution"] = reference_resolution

        def call(tiled):
            if tiled:
                _pipe.vae.enable_tiling()
            else:
                _pipe.vae.disable_tiling()
            generator.manual_seed(used_seed)
            return _pipe(**kwargs).images[0]

        tiled = width * height > VAE_TILING_MIN_PIXELS
        with _pipe_lock:
            try:
                result_image = call(tiled)
            except torch.cuda.OutOfMemoryError:
                if tiled:
                    raise
                torch.cuda.empty_cache()
                result_image = call(True)

        return result_image, used_seed

    # Run the blocking GPU call in a thread so the event loop (and /health)
    # stays responsive while an image is generating.
    result_image, used_seed = await run_in_threadpool(run)

    buffer = io.BytesIO()
    result_image.save(buffer, format="PNG")

    return Response(
        content=buffer.getvalue(),
        media_type="image/png",
        headers={"X-Seed": str(used_seed)},
    )


def exit_with_parent():
    """Exit when the Phoenix app that started us goes away.

    Phantom.PythonService starts this server with PHANTOM_EXIT_WITH_PARENT=1 and a
    pipe on stdin; the pipe closes when the BEAM exits, however abruptly (e.g.
    Ctrl+C twice skips the app's shutdown code). Without this, the server would
    keep running and hold the port, and the next `mix phx.server` couldn't
    start its own copy.
    """
    if os.environ.get("PHANTOM_EXIT_WITH_PARENT") != "1":
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

    uvicorn.run(
        app,
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "8000")),
    )
