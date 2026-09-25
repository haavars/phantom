"""InsightFace on the CPU, with a thread cap per process.

InsightFace builds its onnxruntime sessions without options, so every process takes a thread per core, and
parallel workers then fight over the CPU (8 workers ran about 300 threads on 24 cores, 4x slower). It subclasses
`onnxruntime.InferenceSession` at import, so the cap has to go on its subclass.
"""
import os

import cv2

THREADS = int(os.environ.get("FACE_POOL_THREADS", "3"))
_apps = {}


def app(modules, det_size):
    key = (tuple(modules), det_size)
    if key not in _apps:
        import onnxruntime as ort
        from insightface.app import FaceAnalysis
        from insightface.model_zoo import model_zoo

        init = model_zoo.PickableInferenceSession.__init__
        if not getattr(init, "capped", False):
            def capped(self, model_path, **kwargs):
                options = ort.SessionOptions()
                options.intra_op_num_threads = THREADS
                options.inter_op_num_threads = 1
                init(self, model_path, sess_options=options, **kwargs)

            capped.capped = True
            model_zoo.PickableInferenceSession.__init__ = capped
        cv2.setNumThreads(1)
        a = FaceAnalysis(name="buffalo_l", allowed_modules=list(modules), providers=["CPUExecutionProvider"])
        a.prepare(ctx_id=-1, det_size=(det_size, det_size))
        _apps[key] = a
    return _apps[key]


def ensure_models():
    """Fetch buffalo_l once in the parent process; parallel workers downloading it at once collide."""
    from insightface.utils.storage import ensure_available

    ensure_available("models", "buffalo_l", root="~/.insightface")


def largest(faces):
    return max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1])) if faces else None
