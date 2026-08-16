# Exporting the face recognition model

`HermesGlasses/Models/faceid.mlpackage` is a committed artifact so builds are
reproducible without Python — the same rule `yolo11n.mlpackage` follows (see
`tools/export-yolo.md`).

Without it, `FaceEmbedder()` returns nil, the roster still imports, and
Lookup says "Face model not installed" rather than falling back to something
weaker. That is deliberate: see the header of `FaceEmbedder.swift`.

## Source model

An ArcFace-class recogniser. Either works:

- **InsightFace `buffalo_l` (w600k_r50)** — 112×112 input, 512-d output.
  Highest accuracy, ~170 MB as CoreML.
- **MobileFaceNet** — 112×112 input, 128- or 512-d output, a few MB. Preferred
  if the package is too large to commit comfortably; noticeably weaker on
  hard pairs.

**Licensing is a real constraint, not a footnote.** InsightFace's pretrained
weights are released for **non-commercial research use**. That fits this
project today. If Hermes Glasses ever ships commercially the model must be
replaced — record that decision here rather than rediscovering it later.

## Conversion

    python3 -m venv face-env
    face-env/bin/pip install "coremltools>=8.0" onnx numpy

Download `w600k_r50.onnx` from the InsightFace model zoo (it ships inside the
`buffalo_l` bundle), then:

    face-env/bin/python - <<'PY'
    import coremltools as ct
    model = ct.convert(
        "w600k_r50.onnx",
        source="onnx",
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )
    model.save("faceid.mlpackage")
    PY

Copy the result to `HermesGlasses/Models/faceid.mlpackage` and register it in
`project.pbxproj` exactly as `yolo11n.mlpackage` is — file reference in the
Models group, build file in the **Sources** phase (CoreML packages compile,
they are not resources).

> If `coremltools` has dropped the ONNX front end in the version you install,
> convert via PyTorch instead: load the model with `insightface`, trace it
> with `torch.jit.trace` on a `1×3×112×112` input, and pass the traced module
> to `ct.convert` with `inputs=[ct.TensorType(shape=(1, 3, 112, 112))]`.

## The contract the app depends on

`FaceEmbedder` reads the model's own input/output descriptions, but the
numeric conventions below are **assumed**, not discoverable. A mismatched
normalisation produces embeddings that look perfectly well-formed and match
nothing — no crash, no log, just a roster where nobody is ever recognised.

| Property | Value |
| --- | --- |
| Input shape | `1 × 3 × 112 × 112` (NCHW) |
| Channel order | RGB |
| Normalisation | `(pixel − 127.5) / 128.0` |
| Output | one 1-d `MLMultiArray`, 128 or 512 floats |
| Output post-processing | L2-normalised in `FaceEmbedder`, not in the model |

If the model you convert expects BGR, or `/255`, or a `1 × 112 × 112 × 3`
layout, change `FaceEmbedder.pixelArray` to match and update this table.

Alignment is the app's job, not the model's: `FaceAlignment` maps the eyes
onto the ArcFace 112×112 template — `(38.2946, 51.6963)` and
`(73.5318, 51.5014)` — before the crop is handed over. Feeding an
ArcFace-class model a raw bounding-box crop is the usual reason an
off-the-shelf recogniser badly underperforms its published numbers.

## Setting the thresholds

Do not guess `FaceMatcher.acceptThreshold` / `margin`. Measure them:

    xcrun swiftc HermesGlasses/Services/People/FaceAlignment.swift \
      HermesGlasses/Services/People/FaceMatcher.swift \
      HermesGlasses/Services/People/RosterPerson.swift \
      tools/face-probe.swift -o /tmp/face-probe

    /tmp/face-probe separation ~/Downloads/ice2026-people faceid.mlmodelc
    /tmp/face-probe live ~/Downloads/ice2026-people ~/Desktop/device-crops faceid.mlmodelc

`separation` reports how far apart *different* people sit. `live` is the one
that matters: roster portraits are crisp 512×512 headshots while the probe is
a face inside a person box inside a `.low` glasses frame at conversational
range, and thresholds that look excellent on roster-vs-roster pairs can be
unusable on device.

Compile the package before pointing a probe at it:

    xcrun coremlcompiler compile faceid.mlpackage /tmp/

## Changing the model later

`RosterPerson.modelID` stamps every embedding with the model that produced
it. Swap the package and stored embeddings become meaningless — vectors from
one model say nothing about another. The app compares the two and asks for a
re-import rather than silently matching across the gap.
