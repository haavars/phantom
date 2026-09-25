"""Dataset adapters: each yields (image bytes, labels) in the pool's terms (docs/face-pool.md §2).

The pool id is `<prefix>_<n>`, numbered across the whole dataset in the adapter's order; never per file.
"""
import glob
import os

from . import paths

AGE_BANDS = ["0-2", "3-9", "10-19", "20-29", "30-39", "40-49", "50-59", "60-69", "70+"]
ADULT_BANDS = AGE_BANDS[3:]
RACES = ["East Asian", "Indian", "Black", "White", "Middle Eastern", "Latino_Hispanic", "Southeast Asian"]


class FairFace:
    """FairFace, 0.25-margin crops (224x224) from the Hugging Face mirror. CC BY 4.0."""

    name = "fairface"
    prefix = "ff"
    det_size = 256  # face crops; full photos use 640

    def download(self):
        from huggingface_hub import snapshot_download

        snapshot_download("HuggingFaceM4/FairFace", repo_type="dataset", allow_patterns=["0.25/*", "README.md"],
                          local_dir=paths.raw_dir(self.name))

    def items(self):
        import pyarrow.parquet as pq

        files = sorted(glob.glob(os.path.join(paths.raw_dir(self.name), "0.25", "*.parquet")))
        if not files:
            raise SystemExit(f"no FairFace parquet files in {paths.raw_dir(self.name)}; run the download first")
        for f in files:
            table = pq.read_table(f, columns=["image", "age", "gender", "race"]).to_pylist()
            for r in table:
                yield r["image"]["bytes"], {
                    "sex": ["male", "female"][r["gender"]],
                    "age_band": AGE_BANDS[r["age"]],
                    "age": None,
                    "race": RACES[r["race"]],
                    "identity": None,
                    "label_source": "dataset",
                }


DATASETS = {d.name: d for d in [FairFace()]}


def items(dataset):
    """(id, image bytes, labels) for every image of the dataset, ids numbered across all its files."""
    for n, (data, labels) in enumerate(dataset.items()):
        yield f"{dataset.prefix}_{n:06d}", data, labels
