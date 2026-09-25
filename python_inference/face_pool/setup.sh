#!/usr/bin/env bash
# One-time setup for building the face pool (docs/face-pool.md): a CPU-only venv at
# python_inference/face_pool/.venv. Safe to re-run.
#
# Usage: ./setup.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PYTHON=${PYTHON:-python3}

if [ ! -d .venv ]; then
  echo "==> Creating venv with $($PYTHON --version) at python_inference/face_pool/.venv"
  "$PYTHON" -m venv .venv
else
  echo "==> Reusing existing python_inference/face_pool/.venv"
fi

.venv/bin/python -m pip install --upgrade pip --quiet
echo "==> Installing CPU torch (for CLIP)"
.venv/bin/python -m pip install --quiet torch torchvision --index-url https://download.pytorch.org/whl/cpu
echo "==> Installing the rest of requirements.txt"
.venv/bin/python -m pip install --quiet -r requirements.txt

echo "==> Verifying"
.venv/bin/python -c "import insightface, open_clip, onnxruntime; print('insightface', insightface.__version__, '/ open_clip', open_clip.__version__)"
echo "Done. From python_inference/: face_pool/.venv/bin/python -m face_pool --help"
echo "InsightFace downloads its buffalo_l models to ~/.insightface on first use."
