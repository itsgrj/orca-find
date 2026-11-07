#!/bin/zsh
# Downloads Apple's MobileCLIP-S2 Core ML encoders + the CLIP tokenizer files and compiles them
# into Resources/Models (bundled into the app by build.sh). Run once; ~200 MB.
# Weights: Apple Machine Learning Research Model License (research / non-commercial only).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Resources/Models
[[ -d "$OUT/mobileclip_s2_image.mlmodelc" && -d "$OUT/mobileclip_s2_text.mlmodelc" ]] && { echo "✓ MobileCLIP already in $OUT"; exit 0; }
TMP=$(mktemp -d)
HF=https://huggingface.co/apple/coreml-mobileclip/resolve/main
for p in image text; do
  d=mobileclip_s2_${p}.mlpackage
  mkdir -p "$TMP/$d/Data/com.apple.CoreML/weights"
  for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    echo "▸ $d/$f"; curl -sfL -o "$TMP/$d/$f" "$HF/$d/$f"
  done
done
mkdir -p "$OUT"
for p in image text; do xcrun coremlcompiler compile "$TMP/mobileclip_s2_${p}.mlpackage" "$OUT" >/dev/null; done
curl -sfL -o "$OUT/clip-vocab.json" https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/vocab.json
curl -sfL -o "$OUT/clip-merges.txt" https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/merges.txt
curl -sfL -o "$OUT/LICENSE_MODELS.txt" https://raw.githubusercontent.com/apple/ml-mobileclip/main/LICENSE_MODELS
rm -rf "$TMP"
echo "✓ MobileCLIP-S2 ready in $OUT"
