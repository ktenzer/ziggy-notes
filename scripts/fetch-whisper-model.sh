#!/usr/bin/env bash
#
# Fetch a WhisperKit CoreML model into the app's bundled resources so the worker
# transcribes fully offline (no first-run download).
#
# Usage: ./scripts/fetch-whisper-model.sh [base]
#
# Requires git-lfs (brew install git-lfs). The model is pulled from the
# argmaxinc/whisperkit-coreml Hugging Face repo.

set -euo pipefail

MODEL="${1:-base}"
HF_NAME="openai_whisper-${MODEL}"
REPO="https://huggingface.co/argmaxinc/whisperkit-coreml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="${SCRIPT_DIR}/../worker/Resources/whisper-models"
DEST="${DEST_ROOT}/${HF_NAME}"

if [[ -d "${DEST}" ]]; then
  echo "Model already present at ${DEST}"
  exit 0
fi

command -v git-lfs >/dev/null 2>&1 || { echo "git-lfs is required: brew install git-lfs"; exit 1; }

mkdir -p "${DEST_ROOT}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Fetching ${HF_NAME} from ${REPO} (sparse checkout)…"
git clone --filter=blob:none --no-checkout "${REPO}" "${TMP}/repo"
cd "${TMP}/repo"
git sparse-checkout init --cone
git sparse-checkout set "${HF_NAME}"
git checkout
git lfs pull --include "${HF_NAME}/*"

mv "${TMP}/repo/${HF_NAME}" "${DEST}"
echo "Bundled model at ${DEST}"
echo "Now add worker/Resources/whisper-models to ui/project.yml as a folder reference (see Resources/README.md) and re-run xcodegen."
