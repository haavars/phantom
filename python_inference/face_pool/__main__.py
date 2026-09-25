"""Build the face pool for a dataset, one stage at a time (docs/face-pool.md).

    python -m face_pool download <dataset>
    python -m face_pool embed <dataset> [--workers 8] [--limit N]    stages 1-2
    python -m face_pool landmarks <dataset> [--workers 8]            stage 3
    python -m face_pool screen <dataset>                             stage 4
    python -m face_pool report <dataset>                             stage 5: what's usable
    python -m face_pool all <dataset>                                embed, landmarks, screen, report

Run from python_inference/ with face_pool/.venv/bin/python. Output goes to data/face_pool/<dataset>/
(or $FACE_POOL_DIR).
"""
import argparse

from . import datasets, embed, filters, landmarks, screen


def report(dataset):
    df = filters.load(dataset.name)
    s2, s3, s4 = filters.stage2(df), filters.stage3(df), filters.stage4(df)
    print(f"embedded {len(df)}, stage 2 {s2.sum()}, + stage 3 {(s2 & s3).sum()}, + stage 4 (usable) {(s2 & s3 & s4).sum()}")
    usable = df[s2 & s3 & s4]
    print(usable.groupby(["race", "sex"]).size().unstack(fill_value=0).to_string())
    print(usable.groupby(["race", "age_band"]).size().unstack(fill_value=0).to_string())


def main():
    parser = argparse.ArgumentParser(prog="face_pool")
    parser.add_argument("stage", choices=["download", "embed", "landmarks", "screen", "report", "all"])
    parser.add_argument("dataset", choices=sorted(datasets.DATASETS))
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--limit", type=int, help="embed only the first N images (for trying things out)")
    args = parser.parse_args()
    dataset = datasets.DATASETS[args.dataset]

    if args.stage == "download":
        dataset.download()
    if args.stage in ("embed", "all"):
        embed.run(dataset, workers=args.workers, limit=args.limit)
    if args.stage in ("landmarks", "all"):
        landmarks.run(dataset, workers=args.workers)
    if args.stage in ("screen", "all"):
        screen.run(dataset)
    if args.stage in ("report", "all"):
        report(dataset)


if __name__ == "__main__":
    main()
