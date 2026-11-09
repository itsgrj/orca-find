#!/bin/zsh
# The two "Erase an object" models, compiled into Resources/Models (bundled by build.sh):
#   LaMa (Samsung AI, Apache-2.0 code; Core ML conversion by john-rocky; mirrored at grj-models/lama-coreml) — "Best", 800×800, ~200 MB
#   MI-GAN (Picsart AI Research, MIT) — "Quick", 512×512, ~27 MB; converted here from the author's ONNX
# Note: both models' weights were trained on Places2, whose terms are non-commercial; the authors
# haven't said whether commercial use of the weights is allowed. Run once.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Resources/Models
mkdir -p "$OUT"
TMP=$(mktemp -d)
if [[ ! -d "$OUT/LaMa.mlmodelc" ]]; then
  HF=https://huggingface.co/grj-models/lama-coreml/resolve/843e74d03f23115141a84db365289ae8f9034c2f/LaMa.mlpackage
  mkdir -p "$TMP/LaMa.mlpackage/Data/com.apple.CoreML/weights"
  for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    echo "▸ LaMa $f"; curl -sfL -o "$TMP/LaMa.mlpackage/$f" "$HF/$f"
  done
  xcrun coremlcompiler compile "$TMP/LaMa.mlpackage" "$OUT" >/dev/null
  curl -sfL -o "$OUT/LICENSE_LAMA.txt" https://raw.githubusercontent.com/advimman/lama/main/LICENSE
fi
if [[ ! -d "$OUT/MIGAN.mlmodelc" ]]; then
  echo "▸ MI-GAN: downloading the author's ONNX and converting (needs Python 3; installs torch in a temporary venv)"
  curl -sfL -o "$TMP/migan.onnx" https://huggingface.co/andraniksargsyan/migan/resolve/main/migan.onnx
  curl -sfL -o "$OUT/LICENSE_MIGAN.txt" https://huggingface.co/andraniksargsyan/migan/resolve/main/LICENSE
  python3 -m venv "$TMP/venv"
  "$TMP/venv/bin/pip" install -q torch coremltools onnx onnx2torch numpy
  "$TMP/venv/bin/python" -I tools/eraser/convert_migan.py "$TMP/migan.onnx" "$TMP/MIGAN.mlpackage"
  xcrun coremlcompiler compile "$TMP/MIGAN.mlpackage" "$OUT" >/dev/null
fi
rm -rf "$TMP"
echo "✓ Eraser models ready in $OUT"
