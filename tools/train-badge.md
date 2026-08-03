# Training the badge detector

`HermesGlasses/Models/badge11n.mlpackage` would be a committed artifact so
builds stay reproducible without Python, exactly like `yolo11n.mlpackage`
(`tools/export-yolo.md`). It does not exist yet - the dataset it depends on
hasn't been collected. This doc is how to produce it when it has. Until
then `BadgeDetector` finds no model, logs that once, and `BadgeReader` falls
back to `BadgeRegion`'s guessed band - see the "badge is located, not
assumed" entry in `CLAUDE.md`.

## The constraint that decides whether this works, before anything else

**Capture training images through the glasses stream, at `.low`, at
conversational range.** Not phone photos, not held-up-to-the-camera shots.

A model trained on crisp phone photos will validate beautifully on its own
held-out set and then find nothing on device. This is the exact resolution
cliff `BadgeRegion.swift`'s header documents from the OCR side: at
conversational range a lanyard is a fraction of the frame - a name line
under 1% of a head-to-knees crop's height - and the detector only ever sees
the pixels the glasses camera actually produced. A dataset shot on a phone
a foot from the badge teaches the model a texture of "badge" that never
appears at the range it has to work at. Public ID-card datasets skew even
further towards scanned or held-up geometry and are supplementary at best,
never the base.

Collect crops the same way `EncounterStore` produces them: a person box
from the live glasses stream, saved as JPEG. `tools/badge-probe.swift`
(below) reads that same directory shape.

## Classes

Four, and the label strings must match `Badge.Kind(detectorLabel:)` in
`HermesGlasses/Services/Social/EncounterEvent.swift` exactly - verify
against that file, not against this doc, before you finalise `badges.yaml`:

    conference_lanyard
    corporate_id
    clinical_id
    handheld_id

An unrecognised label is not a training error - `Badge.Kind(detectorLabel:)`
returns nil and the sighting degrades to "a badge, kind unknown" - but a
typo in `badges.yaml` silently costs you the kind on every single sighting,
forever, with nothing in the logs to say why.

Weight the set across all four wearing geometries: neck cord (swings,
rotates, often partly turned away), hip or chest clip, a clinical stack of
two or three cards, and a card held up to the glasses. Include the hard
negatives that cost precision, not recall: phone screens, shirt pockets,
the blank back of a badge, a printed conference programme held at
chest height. A false positive is worse here than a miss - it sends OCR to
a region with no text at all instead of leaving the band, which at least
covers the torso (`BadgeCrop.minimumConfidence` is already set high for
this reason).

Rough starting scale: 500-1500 labelled instances per class, weighted up
for `conference_lanyard` since it is both the commonest badge type and the
most variable in how it hangs.

## Train and export

    python3 -m venv yolo-env
    yolo-env/bin/pip install ultralytics coremltools
    yolo-env/bin/yolo train model=yolo11n.pt data=badges.yaml \
        imgsz=640 epochs=100
    yolo-env/bin/yolo export model=runs/detect/train/weights/best.pt \
        format=coreml nms=True imgsz=640

- `nms=True` matters, for the same reason it does for `yolo11n`
  (`tools/export-yolo.md`): it wraps the model in a Vision-compatible
  pipeline (NMS included), so `VNCoreMLRequest` yields
  `VNRecognizedObjectObservation` with labels and boxes directly - without
  it you get raw tensor output and a lot more glue code.
- Copy the result to `HermesGlasses/Models/badge11n.mlpackage`.
- `BadgeDetector` loads it by name (`BadgeDetector.modelName`): keep the
  filename `badge11n`, or update that constant to match.
- Registering the `.mlpackage` in `HermesGlasses.xcodeproj/project.pbxproj`
  (fileRef + buildFile, mirroring the `yolo11n` entries) is a separate,
  deliberate step - do it once you actually have a model that passes the
  gate below. Don't add the pbxproj entry for a placeholder.

## Before you ship it

**mAP is not the metric. Did the name come out is.** A model can score well
on held-out validation and still be useless here, because validation mAP
measures box overlap against ground truth, not "did OCR come back with
`Priya Raman`" on real, low-resolution, on-device crops.

Compile the model and run `tools/badge-probe.swift` against a folder of
real person crops (pull them off a device via the Files app - see
`EncounterStore`'s `photos/` directory) or synthetic ones:

    xcrun coremlcompiler compile HermesGlasses/Models/badge11n.mlpackage /tmp
    xcrun swiftc HermesGlasses/Services/Social/BadgeRegion.swift \
      HermesGlasses/Services/Social/BadgeCrop.swift \
      tools/badge-probe.swift -o /tmp/badge-probe \
      && /tmp/badge-probe ~/Desktop/person-crops /tmp

The gate: the detected column must read more names than the `BadgeRegion`
band column on your own crops. If it does not, the band ships and the
model waits - that is why the band is still there, and why `BadgeDetector`
treats "no model" as a normal, silent, one-time-logged state rather than a
degraded one. Record the tally in the commit message that adds the model
and the pbxproj entry.
