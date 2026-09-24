#!/usr/bin/env bash
# One-time setup for the synthetic friction-ridge service: creates an isolated
# venv, installs requirements.txt, and installs the verification tools into
# tools/ (NIST NBIS: mindtct, bozorth3, cjpegl; NIST NFIQ 2). CPU only. Safe to
# re-run: finished steps are skipped.
#
# Without the tools the service still renders, but it can't verify images
# (no NFIQ 2 or minutiae checks). SKIP_TOOLS=1 skips them.
#
# ./setup.sh --diffusion also installs the optional diffusion renderer
# (diffusion.py): CUDA torch from requirements-gpu.txt, IMPOSE and
# taming-transformers at pinned commits, and IMPOSE's rolled-print checkpoint
# (about 320 MB, from the authors' Google Drive). Needs an NVIDIA GPU.
#
# After this succeeds, `mix phx.server` (from the project root) finds and uses
# this venv automatically (see Phantom.PythonService).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PYTHON=${PYTHON:-python3}
NBIS_URL=${NBIS_URL:-https://nigos.nist.gov/nist/nbis/nbis_v5_0_0.zip}
NFIQ2_VERSION=${NFIQ2_VERSION:-2.3.0}
TORCH_INDEX_URL=${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}
IMPOSE_COMMIT=c46f36baa32b61eb2e4fadd3b3797d2a57365054
TAMING_COMMIT=3ba01b241669f5ade541ce990f7650a3b8f65318
IMPOSE_ROLLED_FOLDER=https://drive.google.com/drive/folders/1p6hCoPb1xrYsKLMbxDxQ6bPqnTmhKeVM

DIFFUSION=0
for arg in "$@"; do
  case "$arg" in
    --diffusion) DIFFUSION=1 ;;
    *) echo "Unknown option: $arg (see the top of setup.sh)"; exit 1 ;;
  esac
done

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

install_nbis() {
  if [ -x tools/nbis/bin/mindtct ] && [ -x tools/nbis/bin/bozorth3 ] && [ -x tools/nbis/bin/cjpegl ]; then
    echo "==> NBIS already in tools/nbis"
    return
  fi
  echo "==> Building NIST NBIS 5.0 (mindtct, bozorth3, cjpegl) - a few minutes"
  local build
  build="$(pwd)/tools/build"
  rm -rf "$build" && mkdir -p "$build"
  curl -fsSL -o "$build/nbis.zip" "$NBIS_URL"
  unzip -q "$build/nbis.zip" -d "$build"
  # NBIS bundles libraries built with CMake, and their CMakeLists predate CMake 4.
  .venv/bin/python -m pip install --quiet "cmake<4"
  (
    export PATH="$(pwd)/.venv/bin:$PATH"
    cd "$build/Rel_5.0.0"
    step() { local log="$build/$1.log"; shift; "$@" > "$log" 2>&1 || { echo "!! NBIS $* failed, see $log"; exit 1; }; }
    mkdir -p "$build/install"
    step setup ./setup.sh "$build/install" --without-X11 --64
    # GCC 10+ defaults to -fno-common, which NBIS's tentative definitions don't link with.
    sed -i 's/^\(ARCH_FLAG[[:space:]]*:=.*\)$/\1 -fcommon/' rules.mak
    step config make config
    step build make it
    step install make install LIBNBIS=no
  )
  mkdir -p tools/nbis/bin
  cp "$build/install/bin/"{mindtct,bozorth3,cjpegl} tools/nbis/bin/
  rm -rf "$build"
}

install_nfiq2() {
  if [ -x tools/nfiq2/bin/nfiq2 ]; then
    echo "==> NFIQ 2 already in tools/nfiq2"
    return
  fi
  # NIST publishes NFIQ 2 builds as Ubuntu packages; unpack one without installing it.
  local release
  release="$(. /etc/os-release 2>/dev/null && [ "${ID:-}" = ubuntu ] && echo "${VERSION_ID%%.*}" || true)"
  if [ -z "$release" ] || ! command -v dpkg-deb > /dev/null; then
    echo "!! NFIQ 2: no prebuilt package for this OS. Build https://github.com/usnistgov/NFIQ2 and set"
    echo "   NFIQ2_BIN and NFIQ2_MODEL (see verify.py). Verification stays off until then."
    return
  fi
  echo "==> Installing NIST NFIQ 2 $NFIQ2_VERSION (Ubuntu $release package)"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/nfiq2.deb" \
    "https://github.com/usnistgov/NFIQ2/releases/download/v$NFIQ2_VERSION/nfiq2_$NFIQ2_VERSION-1_ubuntu${release}_amd64.deb"
  dpkg-deb -x "$tmp/nfiq2.deb" "$tmp/root"
  mkdir -p tools
  rm -rf tools/nfiq2
  mv "$tmp/root/usr/local/nfiq2" tools/nfiq2
  rm -rf "$tmp"
}

checkout() {  # checkout <url> <dir> <commit>
  if [ ! -d "$2/.git" ]; then
    git clone --quiet "$1" "$2"
  fi
  git -C "$2" fetch --quiet --depth 1 origin "$3" 2> /dev/null || true
  git -C "$2" checkout --quiet "$3"
}

install_diffusion() {
  echo "==> Installing requirements-gpu.txt (CUDA torch: ${TORCH_INDEX_URL##*/})"
  .venv/bin/python -m pip install --quiet "torch>=2.4" torchvision --index-url "$TORCH_INDEX_URL"
  .venv/bin/python -m pip install --quiet -r requirements-gpu.txt
  echo "==> IMPOSE and taming-transformers at pinned commits"
  mkdir -p tools
  checkout https://github.com/Yu-Yy/IMPOSE.git tools/impose "$IMPOSE_COMMIT"
  checkout https://github.com/CompVis/taming-transformers.git tools/taming-src "$TAMING_COMMIT"
  local ckpt=tools/impose/models/fingerprint_ldm_rolled_512/model_ldm_rolled.ckpt
  if [ ! -f "$ckpt" ]; then
    echo "==> Downloading IMPOSE's rolled-print checkpoint"
    .venv/bin/gdown --quiet --folder "$IMPOSE_ROLLED_FOLDER" -O "$(dirname "$ckpt")"
  fi
  .venv/bin/python -c "import diffusion; print('diffusion renderer:', 'ok' if diffusion.available() else diffusion.unavailable_reason())"
}

if [ "${SKIP_TOOLS:-0}" != 1 ]; then
  install_nbis
  install_nfiq2
  .venv/bin/python -c "import verify; print('verification tools:', 'ok' if verify.available() else 'MISSING')"
fi

if [ "$DIFFUSION" = 1 ]; then
  install_diffusion
fi

echo ""
echo "Done. Run the tests with: .venv/bin/python -m pytest"
