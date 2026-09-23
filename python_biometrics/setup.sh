#!/usr/bin/env bash
# One-time setup for the synthetic friction-ridge service: creates an isolated
# venv and installs requirements.txt. CPU only. Safe to re-run.
#
# After this succeeds, `mix phx.server` (from the project root) finds and uses
# this venv automatically (see Bilder.PythonService).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PYTHON=${PYTHON:-python3}

if [ ! -d .venv ]; then
  echo "==> Creating venv with $($PYTHON --version) at python_biometrics/.venv"
  if ! "$PYTHON" -m venv .venv; then
    rm -rf .venv
    echo "Couldn't create a venv with '$PYTHON' (Debian/Ubuntu: sudo apt install python3-venv)."
    echo "Retry with a different interpreter, e.g.: PYTHON=/path/to/python3 ./setup.sh"
    exit 1
  fi
else
  echo "==> Reusing existing python_biometrics/.venv"
fi

echo "==> Installing requirements.txt"
.venv/bin/python -m pip install --upgrade pip --quiet
.venv/bin/python -m pip install --quiet -r requirements.txt

echo "==> Verifying the install"
.venv/bin/python -c "import numpy, scipy, cv2, skimage, fastapi; print('ok: numpy', numpy.__version__, '| opencv', cv2.__version__)"
echo ""
echo "Done. Run the tests with: .venv/bin/python -m pytest"
