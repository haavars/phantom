import os

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ROOT = os.environ.get("FACE_POOL_DIR", os.path.join(REPO, "data", "face_pool"))


def raw_dir(dataset):
    return os.path.join(ROOT, "raw", dataset)


def out_dir(dataset):
    return os.path.join(ROOT, dataset)


def path(dataset, name):
    return os.path.join(out_dir(dataset), name)
