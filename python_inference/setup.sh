#!/usr/bin/env bash
# One-time setup for the Qwen-Image-2.1 inference service: creates an isolated
# venv, installs torch matching this machine's CUDA driver, then the rest of
# requirements.txt. Safe to re-run (skips venv creation if it already exists).
#
# Usage: ./setup.sh
#
# After this succeeds, `mix phx.server` (from the project root) will find and
# use this venv automatically (see Bilder.PythonService) — no separate step to
# start the inference service.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PYTHON=${PYTHON:-python3}
TORCH_INDEX_URL=${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}

if [ ! -d .venv ]; then
  echo "==> Creating venv with $($PYTHON --version) at python_inference/.venv"
  if ! "$PYTHON" -m venv .venv; then
    rm -rf .venv
    echo ""
    echo "Couldn't create a venv with '$PYTHON' (often means its ensurepip/venv module isn't"
    echo "installed, e.g. Debian/Ubuntu need: sudo apt install python3-venv)."
    echo "Retry with a different interpreter, e.g.: PYTHON=/path/to/python3 ./setup.sh"
    exit 1
  fi
else
  echo "==> Reusing existing python_inference/.venv"
fi

VENV_PYTHON=.venv/bin/python

echo "==> Upgrading pip"
"$VENV_PYTHON" -m pip install --upgrade pip --quiet

echo "==> Installing torch + torchvision (CUDA build: ${TORCH_INDEX_URL##*/})"
"$VENV_PYTHON" -m pip install --quiet "torch>=2.4.0" torchvision --index-url "$TORCH_INDEX_URL"

echo "==> Installing the rest of requirements.txt (diffusers, fastapi, ...)"
"$VENV_PYTHON" -m pip install --quiet -r requirements.txt

echo "==> Verifying the install"
"$VENV_PYTHON" - <<'PYEOF'
import torch
print(f"torch {torch.__version__}, CUDA available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"GPU: {torch.cuda.get_device_name(0)}")

import torchvision
print(f"torchvision {torchvision.__version__}")

import diffusers
print(f"diffusers {diffusers.__version__}")
assert hasattr(diffusers, "QwenImage21Pipeline"), "QwenImage21Pipeline not found in this diffusers build"

import fastapi
print(f"fastapi {fastapi.__version__}")
PYEOF

echo ""
echo "==> Checking Hugging Face auth"
"$VENV_PYTHON" -m pip install --quiet huggingface_hub[cli] 2>/dev/null || true
if "$VENV_PYTHON" -c "
from huggingface_hub import HfApi
info = HfApi().whoami()
print(f\"Logged in as: {info['name']}\")
" 2>/dev/null; then
  echo "    OK — Hugging Face token found and valid."
else
  echo "    No valid Hugging Face token found."
  echo "    Run: $VENV_PYTHON -m huggingface_hub.commands.huggingface_cli login"
  echo "    (or set HF_TOKEN when starting the app)"
fi

echo ""
echo "==> Setup complete. Start the app with 'mix phx.server' from the project root;"
echo "    it will launch this venv's python_inference/server.py automatically."
