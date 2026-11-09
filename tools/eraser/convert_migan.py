"""MI-GAN (Picsart AI Research, MIT) ONNX → Core ML, 512×512, float32.
The ONNX graph casts to uint8 internally, which Core ML mishandles, so those casts are made float
(values are already rounded and clipped to 0…255 there). float16 overflows, so keep float32.
Inputs: image [1,3,512,512] RGB 0…255, mask [1,1,512,512] 0…255 where 255 = keep. Output: result, same layout."""
import sys, onnx, torch, numpy as np, coremltools as ct
from onnx2torch import convert
src, dst = sys.argv[1], sys.argv[2]
g = onnx.load(src)
for node in g.graph.node:
    if node.op_type == 'Cast':
        for a in node.attribute:
            if a.name == 'to' and a.i == 2: a.i = 1
for v in list(g.graph.input) + list(g.graph.output): v.type.tensor_type.elem_type = 1
net = convert(g).eval()
img = torch.rand(1, 3, 512, 512) * 255; msk = torch.full((1, 1, 512, 512), 255.0); msk[:, :, 200:300, 200:300] = 0
with torch.no_grad():
    ref = net(img, msk); tr = torch.jit.trace(net, (img, msk))
ml = ct.convert(tr, inputs=[ct.TensorType(name='image', shape=(1, 3, 512, 512)), ct.TensorType(name='mask', shape=(1, 1, 512, 512))],
                outputs=[ct.TensorType(name='result')], minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT32)
diff = float(np.abs(ml.predict({'image': img.numpy(), 'mask': msk.numpy()})['result'] - ref.numpy()).max())
assert diff < 0.5, f'Core ML output differs from PyTorch by {diff}'
ml.short_description = 'MI-GAN 512 Places2 (Picsart AI Research, MIT). image/mask 0..255, mask 255 = keep.'
ml.save(dst)
print(f'✓ MI-GAN converted (max diff {diff:.4f})')
