"""ArcFace templates for face images, with InsightFace's buffalo_l models on the CPU.

The Phoenix app compares the anchor (frontal mugshot) of each synthetic person with the anchors of the other
people in its run, and re-renders one that looks too much like someone else (`Phantom.Biometrics.FaceGate`).
These are the templates it compares: the same detector and recognition model as the face pool
(`python_inference/face_pool/`, docs/face-pool.md), so scores are comparable with it.

InsightFace downloads buffalo_l (about 280 MB) to ~/.insightface on first use.
"""
import threading

import numpy as np

MODEL = "buffalo_l/w600k_r50"
DET_SIZE = 640

_app = None
_lock = threading.Lock()


def available():
    try:
        import insightface  # noqa: F401
        import onnxruntime  # noqa: F401
    except ImportError:
        return False
    return True


def _analysis():
    global _app
    if _app is None:
        import cv2
        from insightface.app import FaceAnalysis

        cv2.setNumThreads(1)
        app = FaceAnalysis(
            name="buffalo_l", allowed_modules=["detection", "recognition"], providers=["CPUExecutionProvider"]
        )
        app.prepare(ctx_id=-1, det_size=(DET_SIZE, DET_SIZE))
        _app = app
    return _app


def embed(image):
    """The template of the largest face in `image` (an RGB PIL image).

    Returns a dict: `faces` (how many were found), and for the largest one `template` (L2-normalised float32,
    512-d), `det` (detector confidence), `bbox` ([x1, y1, x2, y2]) and `eye_dist` (pixels). With no face,
    only `faces`.
    """
    bgr = np.asarray(image.convert("RGB"))[:, :, ::-1].copy()
    with _lock:
        faces = _analysis().get(bgr)
    if not faces:
        return {"faces": 0}
    face = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
    return {
        "faces": len(faces),
        "template": face.normed_embedding.astype(np.float32),
        "det": float(face.det_score),
        "bbox": [round(float(v), 1) for v in face.bbox],
        "eye_dist": round(float(np.linalg.norm(face.kps[1] - face.kps[0])), 1),
    }
