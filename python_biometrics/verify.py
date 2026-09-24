"""Verification of rendered friction-ridge images against their ground truth.

A renderer (procedural or diffusion) may add, drop or move ridges. Matchers are
built to tolerate exactly that, so a matcher score can't tell us. Instead every
rendered impression is compared with the clean ridge map it was rendered from:

1. NIST `mindtct` extracts minutiae from the rendered image (the detected set D)
   and from the clean binarised ridge map of the same capture (the reference
   set R). Using one extractor on both cancels out its own quirks.
2. D and R are paired one-to-one (Hungarian assignment) within 12 px and 30
   degrees, inside the eroded contact area.
3. recall = paired / |R|, spurious rate = unpaired D / |D|, and the mean
   displacement of the pairs. The unpaired points form the drift map.
4. NFIQ 2 scores the image (per finger for slaps).

An impression is accepted when recall, spurious rate and NFIQ 2 all meet the
thresholds for its impression type.

The tools are NBIS (`mindtct`, `bozorth3`, `cjpegl`) and NFIQ 2, installed into
tools/ by setup.sh. Without them `available()` is false and nothing is verified.
Override their locations with NBIS_BIN (a directory) and NFIQ2_BIN / NFIQ2_MODEL.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from scipy.optimize import linear_sum_assignment

TOOLS = Path(__file__).resolve().parent / "tools"
PPI = 500

MAX_DISTANCE = 12  # px, about 0.6 mm at 500 ppi
MAX_ANGLE = 30  # degrees
BORDER = 24  # px eroded off the contact area: the clean map's edge makes false endings
MIN_QUALITY = 20  # mindtct reliability (0-100); below this, minutiae are mostly noise

# Acceptance thresholds per impression type. Starting values from the plan, to
# be tuned on the procedural baseline.
THRESHOLDS = {
    "rolled": {"recall": 0.85, "spurious": 0.15, "nfiq2": 35},
    "plain": {"recall": 0.85, "spurious": 0.15, "nfiq2": 35},
}


def nbis_tool(name):
    directory = os.environ.get("NBIS_BIN")
    path = Path(directory) / name if directory else TOOLS / "nbis" / "bin" / name
    return str(path) if path.exists() else shutil.which(name)


def nfiq2_tool():
    binary = os.environ.get("NFIQ2_BIN") or TOOLS / "nfiq2" / "bin" / "nfiq2"
    model = os.environ.get("NFIQ2_MODEL") or TOOLS / "nfiq2" / "share" / "nist_plain_tir-ink.txt"
    return (str(binary), str(model)) if Path(binary).exists() and Path(model).exists() else None


def available():
    """True when NBIS and NFIQ 2 are installed."""
    return all(nbis_tool(t) for t in ("mindtct", "bozorth3", "cjpegl")) and nfiq2_tool() is not None


def mindtct(image, workdir=None):
    """Minutiae of an 8-bit grey 500 ppi image, as an (n, 4) array of x, y, angle, quality.

    x and y are pixels from the top left, angle is in degrees counter-clockwise
    from the x axis (ANSI/INCITS 378 convention), quality is 0-100.
    """
    with tempfile.TemporaryDirectory(dir=workdir) as tmp:
        h, w = image.shape
        raw, jpl, root = f"{tmp}/i.raw", f"{tmp}/i.jpl", f"{tmp}/i"
        np.ascontiguousarray(image, dtype=np.uint8).tofile(raw)
        # Lossless JPEG: mindtct can't read PNG, and WSQ would add its own artefacts.
        run([nbis_tool("cjpegl"), "jpl", raw, "-raw_in", f"{w},{h},8,{PPI}"])
        run([nbis_tool("mindtct"), "-m1", jpl, root])
        points = np.loadtxt(f"{root}.xyt", ndmin=2).reshape(-1, 4)
    # -m1 writes angles in the standard's 2-degree units.
    points[:, 2] = (points[:, 2] * 2) % 360
    return points


def nfiq2(images):
    """NFIQ 2 scores (0-100) for a list of 8-bit grey 500 ppi images, None where it fails."""
    binary, model = nfiq2_tool()
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, image in enumerate(images):
            path = f"{tmp}/{i:03d}.png"
            Image.fromarray(image).save(path, dpi=(PPI, PPI))
            paths.append(path)
        # -a (actionable feedback) makes the output CSV even for a single file.
        output = run([binary, "-F", "-a", "-m", model, *paths])
    scores = {}
    for line in output.splitlines()[1:]:
        fields = line.split(",")
        if len(fields) >= 3:
            name = Path(fields[0].strip('"')).name
            scores[name] = int(fields[2]) if fields[2].isdigit() else None
    return [scores.get(Path(p).name) for p in paths]


def bozorth3(templates, pairs):
    """bozorth3 scores for `pairs` of indices into `templates` (minutiae arrays as from `mindtct`)."""
    if not pairs:
        return []
    with tempfile.TemporaryDirectory() as tmp:
        for i in {i for pair in pairs for i in pair}:
            write_xyt(f"{tmp}/{i}.xyt", templates[i])
        Path(f"{tmp}/pairs.lis").write_text("".join(f"{tmp}/{i}.xyt\n{tmp}/{j}.xyt\n" for i, j in pairs))
        output = run([nbis_tool("bozorth3"), "-m1", "-A", "outfmt=s", "-M", f"{tmp}/pairs.lis"])
    return [int(line.split()[0]) for line in output.splitlines() if line.strip()]


def write_xyt(path, points):
    points = np.asarray(points, dtype=float).reshape(-1, 4)
    with open(path, "w") as f:
        for x, y, angle, quality in points:
            f.write(f"{int(x)} {int(y)} {int(round(angle / 2)) % 180} {int(quality)}\n")


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{Path(command[0]).name} failed ({result.returncode}): {result.stderr.strip()[:300]}")
    return result.stdout


def inner_area(contact, border=BORDER):
    """The contact area eroded by `border` px, where minutiae can be compared fairly."""
    return cv2.erode((contact > 0.5).astype(np.uint8), np.ones((3, 3), np.uint8), iterations=border) > 0


def keep(points, area, min_quality=MIN_QUALITY):
    """The minutiae inside `area` with at least `min_quality`."""
    if len(points) == 0:
        return points
    x = np.clip(points[:, 0].astype(int), 0, area.shape[1] - 1)
    y = np.clip(points[:, 1].astype(int), 0, area.shape[0] - 1)
    return points[area[y, x] & (points[:, 3] >= min_quality)]


def pair(detected, reference, max_distance=MAX_DISTANCE, max_angle=MAX_ANGLE):
    """One-to-one pairs (i_detected, j_reference, distance) within the tolerances."""
    if len(detected) == 0 or len(reference) == 0:
        return []
    distance = np.hypot(detected[:, None, 0] - reference[None, :, 0], detected[:, None, 1] - reference[None, :, 1])
    turn = np.abs((detected[:, None, 2] - reference[None, :, 2] + 180) % 360 - 180)
    allowed = (distance <= max_distance) & (turn <= max_angle)
    cost = np.where(allowed, distance, 1e6)
    rows, cols = linear_sum_assignment(cost)
    return [(int(i), int(j), float(distance[i, j])) for i, j in zip(rows, cols) if allowed[i, j]]


def compare(detected, reference):
    """Recall, spurious rate, displacement and drift points of `detected` against `reference`."""
    pairs = pair(detected, reference)
    paired_d = {i for i, _, _ in pairs}
    paired_r = {j for _, j, _ in pairs}
    missed = [point(reference[j]) for j in range(len(reference)) if j not in paired_r]
    spurious = [point(detected[i]) for i in range(len(detected)) if i not in paired_d]
    return {
        "reference_count": len(reference),
        "detected_count": len(detected),
        "paired_count": len(pairs),
        "minutiae_recall": ratio(len(pairs), len(reference)),
        "minutiae_spurious": ratio(len(spurious), len(detected)),
        "mean_displacement_px": round(float(np.mean([d for *_, d in pairs])), 2) if pairs else None,
        "missed": missed,
        "spurious": spurious,
    }


def ground_truth_agreement(reference, ground_truth):
    """Share of the skeleton ground truth that mindtct also finds on the clean map (positions only)."""
    if not ground_truth:
        return None
    truth = np.array([[m["x"], m["y"], 0, 100] for m in ground_truth], dtype=float)
    ref = reference.copy()
    ref[:, 2] = 0
    return ratio(len(pair(ref, truth)), len(truth))


def ratio(a, b):
    return round(float(a / b), 3) if b else None


def point(row):
    return [int(row[0]), int(row[1])]


def verify(image, capture):
    """Verification metrics for `image`, rendered from `capture` (an `impression.Capture`).

    Returns a dict with the metrics, the drift points (`missed`, `spurious`) and
    the detected minutiae (`detected`, for batch matching), or None when the
    tools aren't installed.
    """
    if not available():
        return None
    kind = capture.meta.get("impression", "rolled")
    reference_all = mindtct(capture.ridge_map())
    detected_all = mindtct(image)

    regions = capture.fingers or [(capture.meta.get("fgp"), capture.contact)]
    fingers, crops = [], []
    missed, spurious = [], []
    totals = np.zeros(3)
    displacement = []
    for fgp, contact in regions:
        area = inner_area(contact)
        reference = keep(reference_all, area)
        detected = keep(detected_all, area)
        result = compare(detected, reference)
        truth = [m for m in capture.meta.get("minutiae", []) if area[m["y"], m["x"]]]
        fingers.append({
            "fgp": fgp,
            "minutiae_recall": result["minutiae_recall"],
            "minutiae_spurious": result["minutiae_spurious"],
            "mean_displacement_px": result["mean_displacement_px"],
            "reference_count": result["reference_count"],
            "detected_count": result["detected_count"],
            "ground_truth_agreement": ground_truth_agreement(reference, truth),
        })
        totals += (result["paired_count"], result["reference_count"], result["detected_count"])
        if result["mean_displacement_px"] is not None:
            displacement += [result["mean_displacement_px"]] * result["paired_count"]
        missed += result["missed"]
        spurious += result["spurious"]
        crops.append(crop(image, contact))

    for finger, score in zip(fingers, nfiq2(crops)):
        finger["nfiq2"] = score

    paired, referenced, detected = totals
    scores = [f["nfiq2"] for f in fingers]
    metrics = {
        "nfiq2": None if None in scores else min(scores),
        "minutiae_recall": ratio(paired, referenced),
        "minutiae_spurious": ratio(detected - paired, detected),
        "mean_displacement_px": round(float(np.mean(displacement)), 2) if displacement else None,
    }
    metrics["accepted"] = accepted(metrics, THRESHOLDS.get(kind, THRESHOLDS["rolled"]))
    if capture.fingers:
        metrics["fingers"] = fingers
    else:
        metrics["ground_truth_agreement"] = fingers[0]["ground_truth_agreement"]
    metrics["missed"] = missed
    metrics["spurious"] = spurious
    metrics["detected"] = [[int(x), int(y), round(float(a), 1), int(q)] for x, y, a, q in detected_all]
    return metrics


def accepted(metrics, thresholds):
    recall, spurious, quality = metrics["minutiae_recall"], metrics["minutiae_spurious"], metrics["nfiq2"]
    return bool(
        recall is not None and recall >= thresholds["recall"]
        and spurious is not None and spurious <= thresholds["spurious"]
        and quality is not None and quality >= thresholds["nfiq2"]
    )


def score(metrics):
    """How good an attempt is, for picking the best of several rejected ones."""
    return (
        metrics["accepted"],
        (metrics["minutiae_recall"] or 0) - (metrics["minutiae_spurious"] or 1),
        metrics["nfiq2"] or 0,
    )


def crop(image, contact, margin=32):
    """The image cut down to one finger's contact area, with paper around the rest."""
    ys, xs = np.nonzero(contact > 0.5)
    if len(ys) == 0:
        return image
    y0 = max(0, ys.min() - margin)
    # NFIQ 2 takes at most 1000 px of height; keep the fingertip end.
    y1 = min(image.shape[0], ys.max() + margin, y0 + 960)
    x0, x1 = max(0, xs.min() - margin), min(image.shape[1], xs.max() + margin)
    region = image[y0:y1, x0:x1].copy()
    # Neighbouring fingers of a slap would confuse NFIQ 2's foreground detection.
    mask = cv2.dilate((contact[y0:y1, x0:x1] > 0.05).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
    region[~mask] = 250
    return region
