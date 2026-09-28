"""Step 4: render anchors with Qwen, each with its identity's picked Arc2Face face as the only reference.

    python qwen_anchors.py RUN SUBJECTS_JSON [--frame mugshot|close] [--faces DIR] [--assign FILE] [--out NAME]

Identity i gets subject i's attributes (age, skin, eyes, hair, beard, clothing) in an edit prompt: keep the
face, change the rest, booking setup. No feature list.

--frame close sends the 512² Arc2Face image as it is (the pilot); Qwen copied its close-up framing.
--frame mugshot (default) puts the face, with a feathered oval mask, on a 960×1280 mid-grey canvas, scaled and
placed so its eyes sit where they do in text-only anchors.

--faces DIR takes the face from RUN/DIR/clean_XX.png (clean_references.py) instead of the picked Arc2Face one.
--assign FILE ({subject: identity}, match_ages.py) gives subject i another identity than i.

Needs the Qwen service on :8000 (mix phx.server). Writes RUN/<out>/anchor_XX.png and reference_XX.png.
"""
import argparse
import json
import os
import time

import cv2
import httpx
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from common import QWEN, png_bytes, run_dir, text_only_anchor

PHOTO = "Photorealistic, unretouched digital photograph with natural skin texture and sharp focus."
CLEAN = "The image shows only the person against the background: no text, no placard, no height chart, no border."
W, H = 960, 1280


def prompt(s):
    beard = "clean-shaven" if s["facial_hair"] in (None, "clean-shaven") else f"with {s['facial_hair']}"
    return (f"Police booking photograph (mugshot) of the man in the reference image, the same individual: keep his "
            f"face shape, bone structure, eyes, nose, mouth, jaw and ears exactly the same. Changes: he is now "
            f"{s['age']} years old and looks it; {s['skin']} skin and {s['eyes']} eyes; his hair is now {s['hair']}; "
            f"he is {beard}; he now wears {s['clothing']}; no glasses and no hat or head covering; a neutral "
            f"expression with the mouth closed. Frontal view: head and upper shoulders centred in the frame, facing "
            f"the camera squarely with the head level, both eyes open and looking straight into the lens. Plain, "
            f"uniform mid-grey background. Even, diffuse flash lighting from the front with no harsh shadows. Taken "
            f"at eye level. {PHOTO} {CLEAN}")


def detector():
    from insightface.app import FaceAnalysis

    app = FaceAnalysis(name="buffalo_l", allowed_modules=["detection"], providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1, det_size=(640, 640))

    def face(image):
        rgb = np.asarray(image.convert("RGB"))
        pad = rgb.shape[0] // 2
        bgr = cv2.copyMakeBorder(rgb[:, :, ::-1].copy(), pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=(128,) * 3)
        f = max(app.get(bgr), key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
        return f.kps - pad, f.bbox - pad

    return face


def mugshot_target(face):
    """Where text-only anchors have their eyes: mean eye centre and eye distance, as fractions of the image."""
    rows = []
    for i in range(1, 13):
        im = Image.open(text_only_anchor(i))
        kps, _ = face(im)
        centre = (kps[0] + kps[1]) / 2
        rows.append([centre[0] / im.width, centre[1] / im.height, np.linalg.norm(kps[1] - kps[0]) / im.width])
    return np.mean(rows, axis=0)


def mugshot_reference(image, face, target):
    """The face on a mid-grey 960×1280 canvas, eyes where a text-only anchor has them."""
    kps, bbox = face(image)
    cx, cy, eye = target
    scale = eye * W / np.linalg.norm(kps[1] - kps[0])
    small = image.convert("RGB").resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    centre = (kps[0] + kps[1]) / 2 * scale
    offset = (round(cx * W - centre[0]), round(cy * H - centre[1]))
    # An oval around the face and some hair, feathered, so no photo background comes along.
    x1, y1, x2, y2 = (float(v) for v in bbox * scale)
    bw, bh = x2 - x1, y2 - y1
    mask = Image.new("L", small.size, 0)
    ImageDraw.Draw(mask).ellipse([x1 - 0.25 * bw, y1 - 0.45 * bh, x2 + 0.25 * bw, y2 + 0.15 * bh], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(0.06 * bw))
    canvas = Image.new("RGB", (W, H), (128, 128, 128))
    canvas.paste(small, offset, mask)
    return canvas


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("run")
    p.add_argument("subjects")
    p.add_argument("--frame", choices=["mugshot", "close"], default="mugshot")
    p.add_argument("--faces", default=None)
    p.add_argument("--assign", default=None)
    p.add_argument("--out", default=None)
    args = p.parse_args()
    assign = json.load(open(args.assign)) if args.assign else {}
    out = args.out or f"anchors_{args.frame}" + (f"_{args.faces}" if args.faces else "")
    subjects = json.load(open(args.subjects))
    picks = json.load(open(run_dir(args.run, "picks.json")))
    face = detector()
    target = mugshot_target(face) if args.frame == "mugshot" else None
    client = httpx.Client(timeout=600)
    for i, s in enumerate(subjects, start=1):
        path = run_dir(args.run, out, f"anchor_{i:02d}.png")
        if os.path.exists(path):
            continue
        k = assign.get(str(i), i)
        a2f = Image.open(run_dir(args.run, args.faces, f"clean_{k:02d}.png") if args.faces else
                         run_dir(args.run, f"a2f_{k:02d}_{picks[str(k)]['sample']}.png"))
        ref = mugshot_reference(a2f, face, target) if args.frame == "mugshot" else a2f.convert("RGB")
        ref.save(run_dir(args.run, out, f"reference_{i:02d}.png"))
        t = time.time()
        r = client.post(f"{QWEN}/generate", data={"prompt": prompt(s), "width": W, "height": H, "steps": 40,
                                                  "seed": 1000 + i},
                        files=[("images", ("reference.png", png_bytes(ref), "image/png"))])
        r.raise_for_status()
        open(path, "wb").write(r.content)
        print("anchor", i, f"{time.time() - t:.0f}s", flush=True)
