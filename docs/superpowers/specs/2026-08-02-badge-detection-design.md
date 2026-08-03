# Badge & ID detection — design

Date: 2026-08-02

## Problem

The Lens/encounter vision path classifies with stock `yolo11n` (COCO 80,
confidence ≥ 0.4) and reports `label + rect`. That is the entire
classification output, and it carries no notion of a name badge or an ID
card.

The badge-reading path therefore never uses detection at all. `BadgeReader`
takes the padded **person** crop and *assumes* where a badge is:
`BadgeRegion`'s fixed band, 22%–72% of the crop's height, inset 8% each
side. It magnifies that band and runs OCR over it.

That guess was measured and is better than nothing, but it is still a
guess. It misses a badge clipped at the hip, a card on a retractable reel
worn low, a tag held up to the glasses, a lanyard swung round to one side.
It cannot say *what kind* of badge it saw. It cannot read a QR code,
because it does not know a QR code is there. And when it lands on a shirt
fold instead of a badge, the OCR pass has nothing to find.

## Goal

Locate the badge instead of assuming it, and extract everything printed on
it: name/title/org, any barcode payload, the badge's type, and the portrait
photo printed on ID cards.

## Non-goals

- Adding classes to the Lens object vocabulary generally. This is the badge
  case only.
- Live per-frame badge detection. See "Runtime" below.
- Face recognition. Grouping remains by badge text, never by face — see
  CLAUDE.md. The portrait crop is stored imagery, never an identity key.

## Decisions taken

| Decision | Choice | Why |
| --- | --- | --- |
| Detection strategy | Second, dedicated fine-tuned model on the person crop | See "Rejected alternatives" |
| Runtime | Snap time only | Off the 24 fps hot path; a few runs per conversation |
| Classes | 4: conference lanyard, corporate ID, clinical ID, handheld ID | Gives badge *type* free, in the same pass as the box |
| Payload | Name/title/org + barcode + type + portrait | All four requested |
| Portraits | Own setting, default **off** | The one payload a person would object to on sight |

## Rejected alternatives

**Fine-tune `yolo11n` itself to 81 classes (COCO + badge).** One model, one
inference — but keeping `person` requires training on COCO *plus* the badge
data or the model catastrophically forgets, and `person` is the foundation
of `DwellTracker` identity and `ConversationCapture.people()`. Worse, it
returns badge detection to the full 640×640 frame, where a lanyard at the
glasses' `.low` stream resolution is a handful of pixels. That is the exact
failure `BadgeRegion`'s header documents from the OCR side: *the text never
had the pixels*. Running detection on the person crop is what makes the
pixels exist.

**No training: `VNDetectRectanglesRequest` + text + barcodes.** Ships
without a dataset, but fires on phone screens, book covers, pockets and the
blank backs of badges, and cannot report badge type.

The barcode half of this alternative is adopted regardless — it is free,
on-device, and decodes exactly where OCR guesses. **In this branch that
adoption is model-gated, not unconditional**: `BarcodeReader.read` is only
called from `readDetected`, which requires a localised box, so with no
`badge11n.mlpackage` bundled the barcode pass never runs at all. It ships
inert until a model lands - see "Open risks" - which is correct (without a
box you cannot tell whose QR you decoded) but is a fact this section should
not obscure.

## Architecture

One seam changes: `HermesSessionViewModel:1735`'s
`BadgeReader.readBadge(from: personImage)`. That call site and everything
below it is untouched.

```
person crop (existing, 25% padded)
      │
      ▼
BadgeDetector ──► 0..n badge boxes + class
      │
      │  (empty ──► BadgeRegion band — today's behaviour, unchanged)
      ▼
BadgeCrop: pad, clamp, upscale to ≥ 1000 px short side
      │
      ├─► VNDetectBarcodesRequest  ─► vCard / MECARD / attendee id
      ├─► VNRecognizeTextRequest   ─► lines ─► BadgeParser (unchanged)
      ├─► detector class label     ─► Badge.kind
      └─► VNDetectFaceRectangles   ─► printed portrait crop
      │
      ▼
   merged Badge
```

### New files

- **`HermesGlasses/Services/Social/BadgeDetector.swift`** — CoreML wrapper
  around `badge11n`. One-shot: it runs on a still crop, not a stream, so it
  carries none of `ObjectDetector`'s latest-wins backpressure. It performs
  the same bottom-left → top-left rect flip, at the same single boundary.
- **`HermesGlasses/Services/Social/BadgeCrop.swift`** — pure CoreGraphics.
  Expand a detected box by padding, clamp to the image, compute the upscale
  (reusing `BadgeRegion.upscaleFactor`, which is already measured and
  tested). Compiles under plain `swiftc` for `tests/badge-crop/`.
- **`HermesGlasses/Services/Social/BarcodeReader.swift`** — thin
  `VNDetectBarcodesRequest` wrapper plus a **pure** payload parser (vCard
  `FN`/`ORG`/`TITLE`, MECARD, bare URL/id) that tests can exercise without
  Vision.
- **`HermesGlasses/Models/badge11n.mlpackage`** — committed artifact,
  exactly as `yolo11n.mlpackage` is, so builds stay reproducible without
  Python.

### Changed files

- **`BadgeReader`** becomes the orchestrator of the four extraction passes.
  `BadgeRegion` is demoted from *the* strategy to *the fallback* — and is
  otherwise left exactly as measured, because it is now what catches badges
  the model missed.
- **`Badge`** (in `EncounterEvent.swift`) gains four optionals.
- **`BadgeParser`** gains the merge/precedence rule below.
- **`BadgeAssist`** sends the tight badge crop instead of the whole person
  photo — cheaper and far more legible within the same 6-read cap. When no
  badge was detected it sends the person photo exactly as it does today;
  those sightings are precisely the ones assist exists for.
- **`EncounterStore`** writes portrait JPEGs alongside sighting photos.
- **`tools/train-badge.md`**, **`tools/badge-probe.swift`** — new.

## Data model

```swift
extension Badge {
    enum Kind: String, Codable {
        case conferenceLanyard, corporateID, clinicalID, handheldID
    }
}

// added to Badge:
var kind: Kind?
var barcodePayload: String?
var portraitFilename: String?
var badgeRect: CGRect?     // in unit coords of the person crop
```

All four are optional, so `Badge`'s synthesized decoder reads existing
`encounters.json` unchanged. No migration shim is needed here — unlike the
`photoFilename` → `photoFilenames` case, nothing is being renamed or
retyped.

`Badge.Source` gains `barcode`, ranked between `manual` and `onDevice`:

```
manual (3) > barcode (2) > onDevice (1) > assisted (0)
```

A decoded vCard is not a guess; it outranks OCR. Slotting it into the
existing `rank` ladder keeps one precedence story rather than a parallel
concept, and `EncounterTimeline`'s merge logic needs no change.

## Payload extraction

**Name / title / org.** Unchanged `BadgeParser`, fed OCR lines from the
*tight* badge crop rather than the guessed band. The conservative
"return nil rather than guess" contract stands.

**Barcode.** `VNDetectBarcodesRequest` over the badge crop. Conference
badges commonly encode a vCard (`BEGIN:VCARD`), a MECARD, or a bare
attendee id/URL. A parsed `FN`/`ORG`/`TITLE` populates the badge directly
at `.barcode` rank; an opaque id is kept in `barcodePayload` and nothing
else.

**Kind.** The detector's own class label. Free — same pass as the box.

**Portrait.** `VNDetectFaceRectanglesRequest` restricted to inside the
badge box; the largest face is the printed portrait. Cropped, written to
`photos/`, referenced by `portraitFilename`.

## Privacy

The portrait is a face cropped from a person's ID document. It is the only
payload here that someone would object to on sight, so:

- It is gated by its own setting, **`badge_portraits_enabled`, default
  off**. With it off, the face pass simply does not run; detection, OCR,
  barcode and kind are unaffected. Every other part of the pipeline works
  without it.
- The **stored portrait file** is never included in the `BadgeAssist`
  payload - it is written under its own filename and nothing on the assist
  path reads it. But the AI pass sends the badge crop (`badgeRect`), and
  `badgeRect` **is** the badge: on an ID card, the printed portrait is
  inside that crop too. Once a model ships, turning badge assist on sends a
  tight crop centred on the person's ID photograph - a *stronger*
  disclosure than the pre-detection whole-person photo, not a weaker one.
- `PeopleView`'s "Stored on this iPhone only" notice covers the stored file
  under the existing rule. It does not describe what badge assist sends -
  `SettingsView`'s "Keep ID photos" footer must say so explicitly, and does.

## Runtime

Snap time only. The detector runs on the person crop after a dwell fires —
a handful of times per conversation, never on the 24 fps stream. Nothing is
added to per-frame cost, thermal budget, or battery, and the model can
afford to be slower than a live one.

Consequence accepted: there is no live "badge detected — hold still"
feedback on the lens. Adding it later means promoting the detector to the
frame path, which is a separate decision with a real cost.

## Fallbacks and invariants

- **Every failure means "no badge".** Model missing from the bundle, load
  failure, zero detections, barcode garbage, face request error — all fall
  through silently. Never an error the wearer sees, never a reason not to
  save an encounter. This is the existing contract and it is not weakened.
- **Zero detections falls back to the `BadgeRegion` band**, so a badge worn
  somewhere the model was not trained on is no worse off than today.
- **OCR and detection stay off the main actor**, via the same
  `Task.detached(priority: .utility)` discipline as `BadgeReader` today, and
  for the documented reason (`nonisolated(nonsending)` under Swift 6.2+
  would otherwise turn every sighting into a main-thread hang).
- **`badge_ocr_enabled` off ⇒ the detector does not run.** `BadgeAssist`'s
  two-flag spend guard is untouched. A working detector shrinks the
  "badge is nil" set that assist selects from, which lowers spend by itself.
- **No user-facing toggle for the detector.** It is an implementation
  detail of badge reading. (`badge_portraits_enabled` is a payload
  decision, not a detector one.)
- **Grouping stays by badge text.** `kind` and `portraitFilename` are
  display data. Neither may become a grouping key.

## Training

`tools/train-badge.md`, sibling to `export-yolo.md`: dataset layout, the
ultralytics fine-tune command from `yolo11n.pt`, export with `nms=True
imgsz=640` (required — it wraps the model in a Vision-compatible NMS
pipeline so `VNCoreMLRequest` yields `VNRecognizedObjectObservation`
directly), and the copy into `Models/`.

Four classes, weighted across all four wearing geometries: neck lanyard,
hip/chest clip, clinical stack, held-up card. Orientation robustness
matters — cards on retractable reels arrive sideways and upside down.

**The decisive constraint: capture training images through the actual
glasses stream at `.low`.** A model trained on crisp phone photos will
validate beautifully and find nothing on device — the same resolution cliff
`BadgeRegion` documents from the OCR side. Most labeling effort goes on
real glasses frames; public ID-card datasets are supplementary and skew
towards scanned/held-up geometry.

## Measurement

`tools/badge-probe.swift`, in the mould of `ocr-probe.swift`: compile the
real `BadgeRegion` and `BadgeCrop`, run a folder of person crops through
both paths, print band-read vs detected-read side by side.

mAP is not the metric. *Did the name come out* is. **The model does not
replace the band until the probe says it beats the band**, and the existing
rule — re-measure before arguing with the constants — extends to it.

## Testing

- **`tests/badge-crop/`** (new) — pure geometry: box padding, clamping to
  image bounds, upscale factor, bottom-left → top-left conversion,
  degenerate and out-of-range boxes.
- **`tests/badge/`** (extended) — vCard/MECARD parsing, opaque-payload
  handling, and the source-precedence merge rules.

Both suites end in `print(...)` then `exit(...)`. New assertions go
**above** those two lines; appended below they never execute and the suite
still reports all-green.

The model itself is not unit-testable. `tools/badge-probe.swift` is its
test.

## Project registration

Four new Swift files plus `badge11n.mlpackage` need manual
`project.pbxproj` registration — this project has no synchronized groups,
so each needs its four hand edits with sequential IDs.

## Open risks

1. **The dataset is the project.** Everything else here is plumbing that
   can be written in a day. If the glasses-resolution training set is thin,
   the model underperforms the band and the probe will say so — at which
   point the fallback path is the whole feature, and that is today's
   behaviour.
2. **Two-stage error compounding.** A missed person box means a missed
   badge. Already true today, not made worse, but it caps the ceiling.
3. **Barcode reach.** QR decoding needs more pixels than it might seem at
   `.low`. If the barcode pass rarely fires at conversational distance, its
   value concentrates on the held-up-card case.
