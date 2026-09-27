#!/usr/bin/env bash
# One-time setup for the identity-first experiment (README.md): Arc2Face at a pinned commit, its own venv
# (it needs transformers 4.36 and diffusers 0.29) and its models, all in data/experiments/identity_first/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
WORK=../../../data/experiments/identity_first
COMMIT=8f3acd701d17fda7fde4c9f1d170fc88fecbe9ad
mkdir -p "$WORK"
if [ ! -d "$WORK/Arc2Face" ]; then
  git clone -q https://github.com/foivospar/Arc2Face.git "$WORK/Arc2Face"
  git -C "$WORK/Arc2Face" checkout -q "$COMMIT"
fi
cd "$WORK/Arc2Face"
[ -d .venv ] || python3 -m venv .venv
PY=.venv/bin/python
$PY -m pip install -q --upgrade pip
$PY -m pip install -q "torch==2.5.1" "torchvision==0.20.1" --index-url https://download.pytorch.org/whl/cu121
$PY -m pip install -q "diffusers==0.29.2" "transformers==4.36.0" "huggingface_hub<0.26" "numpy<2" accelerate einops \
  insightface onnxruntime open_clip_torch pandas pyarrow opencv-python-headless scikit-image httpx
$PY - <<'PYEOF'
from huggingface_hub import hf_hub_download, snapshot_download
for f in ["arc2face/config.json", "arc2face/diffusion_pytorch_model.safetensors", "encoder/config.json",
          "encoder/pytorch_model.bin"]:
    hf_hub_download(repo_id="FoivosPar/Arc2Face", filename=f, local_dir="./models")
hf_hub_download(repo_id="FoivosPar/Arc2Face", filename="arcface.onnx", local_dir="./models/antelopev2")
snapshot_download("stable-diffusion-v1-5/stable-diffusion-v1-5", allow_patterns=[
    "model_index.json", "scheduler/*", "tokenizer/*", "vae/config.json", "vae/diffusion_pytorch_model.fp16.safetensors",
    "unet/config.json", "text_encoder/config.json", "feature_extractor/*"])
PYEOF
echo "Done. Run the steps with $WORK/Arc2Face/.venv/bin/python (see README.md)."
