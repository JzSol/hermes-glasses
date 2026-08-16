# Roster face lookup — design

Date: 2026-08-16
Branch: `ice2026`

## Problem

The Lookup app on `ice2026` identifies a stranger by sending their face to
an AI provider with web search on (`PersonWebLookup.lookupByFace`, 10 search
invocations, a 60 s budget), falling back to badge OCR plus a web search on
the badge name.

Three things are wrong with that for the actual use case — an ICE 2026
attendee list the wearer already has:

1. **It asks the internet a question it already knows the answer to.** The
   people worth identifying are a known, bounded set of 45. A web search is
   the wrong instrument for a closed roster.
2. **It leaks.** A stranger's face crop leaves the phone on every attempt,
   including the ones that fail. Nothing else in this app does that.
3. **It cannot tell namesakes apart and admits it.** The prompt's own escape
   hatch is `NO_MATCH`, and a 60 s budget still resolves to "Couldn't find
   anything solid online" for anyone without a public profile — which at a
   student-heavy conference is most of the roster.

## Goal

Identify a person by matching their face against a roster the wearer
imported, entirely on-device. Name and details on the lens in the time the
gate already takes; "Not in the roster" when they are not.

## Non-goals

- Web lookup of any kind. The path is deleted, not made optional.
- Badge OCR inside Lookup. `BadgeReader` stays in the codebase and keeps
  serving the encounter/People path; Lookup stops calling it.
- Face recognition anywhere outside Lookup. `EncounterTimeline` grouping
  stays keyed on badge text — see "Stance change".
- Roster editing in-app. Import is one-shot and replaces; the source of
  truth is the folder on the Mac.
- Recognising anyone not in the roster.

## The data

`~/Downloads/ice2026-people`, confirmed as the whole roster:

- 45 files, flat, no subdirectories, no sidecar metadata.
- `<Full Name>.jpg`, e.g. `Prasanth Sasikumar.jpg`, `Malsha de Zoysa.jpg`.
  Names carry spaces, mixed case, and lowercase particles.
- 512×512 each, 23–120 KB. Portrait headshots.
- **One photo per person.** No pose, expression or lighting variation to
  average over.

## Decisions taken

| Decision | Choice | Why |
| --- | --- | --- |
| Identity source | Imported roster only | Closed set; the answer is already known |
| Matcher | Bundled face-embedding CoreML model | See "Rejected alternatives" |
| No-match behaviour | Say "Not in the roster", stop | User's call; keeps the pipeline fully on-device |
| Missing model | Feature reports itself unavailable | No silent degradation — see "The floor question" |
| Import | One folder, `.fileImporter`, replaces the roster | Matches how the folder is actually maintained |
| Import tiers | Flat file / subfolder / optional `people.json` | Today's folder works untouched; richer forms layer on |
| Accept rule | Threshold **and** runner-up margin | A single threshold names the nearest stranger |
| Thresholds | Measured by `tools/face-probe.swift`, not guessed | `BadgeRegion`'s lesson, applied before the mistake |

## Rejected alternatives

**`VNGenerateImageFeaturePrintRequest` + `computeDistance`.** Ships today
with no model, no Python, no download, and stays on-device. Rejected as the
matcher because it is a general *image* descriptor, not a *face* descriptor:
it keys on background, crop framing, lighting and pose alongside identity.
Against 45 candidates it would confuse similar-looking people confidently
and silently, and the failure mode of this feature is putting a real name on
the wrong face in front of that person.

**Send the face plus candidate roster photos to the AI provider.** No ML
work at all. Rejected: it re-introduces the exact leak this change exists to
close, now leaking the roster too, and costs money per glance.

**Feature print now, real model behind a `FaceEmbedder` protocol** (the
`BadgeDetector`/`BadgeRegion` ladder). Rejected here even though it is this
repo's usual shape, because the two cases differ in what the floor costs
when wrong. The band's failure is *silence* — no name read, wearer sees
nothing, tries again. A weak embedder's failure is *a confident wrong name*.
A floor is worth shipping when its failure is silence, not when its failure
is a lie. Hence: model required, feature reports itself unavailable without
one.

## Architecture

New directory `HermesGlasses/Services/People/`.

### `RosterPerson` (model)

```swift
struct RosterPerson: Identifiable, Codable {
    let id: UUID
    var name: String
    var org: String?
    var title: String?
    var notes: String?
    var photoFilenames: [String]
    /// One per photo that yielded a detectable face. L2-normalised.
    var embeddings: [[Float]]
}
```

`embeddings` is stored, not recomputed at launch: 45 people × one CoreML
inference each is seconds of work that has no business happening on the path
to a lens frame. It is keyed to the bundled model — see "Model identity"
below.

### `RosterStore`

Application Support/`Roster/` — `roster.json` + `photos/`. Deliberately a
copy of `EncounterStore`'s contract, because that contract is already proven
here: whole index in memory as the source of truth, mutations applied
synchronously under an `NSLock`, bytes written on one **static** serial
`DispatchQueue` so a second instance opened over the same directory reads
what the first one queued.

Surface:

```swift
func all() -> [RosterPerson]
func replaceAll(_ people: [RosterPerson], photos: [String: Data]) throws
func removeAll() throws
func photoURL(_ filename: String) -> URL
```

`replaceAll` is the only write path. Import is a replace, so there is no
merge logic to get wrong, and no half-imported state: the new roster is
staged and swapped, or the old one survives untouched.

### `RosterImporter`

Takes a security-scoped folder URL from `.fileImporter` and walks it in
three tiers:

| Shape | Yields |
| --- | --- |
| `<Name>.jpg` | Person `<Name>`, one photo ← **today's folder** |
| `<Name>/*.jpg` | Person `<Name>`, every image inside |
| `people.json` alongside | Merged **by name** onto the above; adds `org`, `title`, `notes`, and may list `photos` explicitly |

Name derivation is the filename's stem, verbatim, whitespace-trimmed. No
title-casing, no separator-splitting: `Malsha de Zoysa` and `Sahan H` are
correct as written and any cleverness would damage them. Accepts `.jpg`,
`.jpeg`, `.png`, `.heic`; ignores dotfiles and anything else.

`people.json`, when present:

```json
[
  { "name": "Ryo Hajika", "org": "Empathic Computing Lab",
    "title": "PhD Candidate", "notes": "Met at ISMAR 2025",
    "photos": ["ryo-1.jpg", "ryo-2.jpg"] }
]
```

Entries whose `name` matches no photo are still imported (details-only, never
matchable by face) and **counted in the report** rather than dropped, because
a typo'd name in the JSON is otherwise invisible.

The name→person grouping is pure and lives in `RosterImporter.plan(files:json:)`
so it can be tested without a filesystem.

### Import report

Import ends on a summary the user must see, not a spinner that stops.
Illustrative shape only — which photos actually fail is unknown until
`face-probe` Mode 1 runs (step 1 of "Sequencing"):

```
45 people, 45 photos.
2 photos had no detectable face — those people cannot be recognised:
  <name>, <name>
```

This is the single most useful thing the importer does. A portrait with no
detectable face is a person who will never be identified, no matter how good
the model is, and it must be findable before the conference rather than
during it.

### `FaceEmbedder`

Wraps an **optional** bundled `HermesGlasses/Models/faceid.mlpackage`.

- `static var isAvailable: Bool` — model present and loadable.
- `func embed(_ faceCrop: UIImage) async -> [Float]?` — nil when no face
  survives alignment.

Pipeline per crop, run detached at `.utility` like `BadgeReader`'s passes:

1. `VNDetectFaceLandmarksRequest` → the largest face's eye/nose/mouth points.
2. **Similarity-transform alignment** to the model's canonical 5-point
   template, output 112×112. ArcFace-class models are trained on aligned
   crops and lose a great deal of accuracy without this step; skipping it is
   the most common way an off-the-shelf face model underperforms its
   published numbers.
3. Normalise pixels as the exported model expects (`(x − 127.5)/128` for the
   ArcFace family; recorded in `tools/export-face.md` and asserted at load).
4. Inference → vector → L2-normalise, so cosine similarity is a dot product.

Alignment is shared by both sides — import and live snap run the identical
function. If they ever diverge, every similarity is meaningless, so there is
exactly one implementation and no parameters.

### `FaceMatcher` (pure)

```swift
struct FaceMatcher {
    var acceptThreshold: Float   // top-1 must reach this
    var margin: Float            // and beat top-2 by this

    enum Result {
        case match(personID: UUID, score: Float)
        case unknown(Reason)
    }
    enum Reason {
        case emptyRoster
        case belowThreshold(best: Float)
        case ambiguous(best: Float, runnerUp: Float)
    }

    func match(probe: [Float], gallery: [RosterPerson]) -> Result
}
```

Person score = **max** over that person's embeddings (best-matching photo
wins; averaging would let one bad portrait drag a good one down). Accept
only when `best >= acceptThreshold` **and** `best − runnerUp >= margin`,
where the runner-up is the best score belonging to a *different* person.

The margin is the part that matters. Cosine similarity always has a nearest
neighbour, and a threshold alone will happily elect it. Two roster members
who look alike is exactly the situation where a wrong name does real damage,
and `ambiguous` is the honest answer there.

No Foundation, no Vision, no UIKit — plain arithmetic over `[Float]`, tested
standalone.

### Lookup rewrite

`LookupViewModel.processCandidate` becomes:

```
gate fires
  → crop person from frame                     (unchanged)
  → frontalFace(in: crop)                      (unchanged — detection only)
  → face crop, padding 0.35                    (unchanged)
  → FaceEmbedder.embed                         (new)
  → FaceMatcher.match against RosterStore.all  (new)
  → finish(name, details) | backToScanning("Not in the roster")
```

Deleted from the file: the `DirectClient.hasKey` gate, both
`PersonWebLookup` calls, the `BadgeReader` fallback, and the
`.searching(name:)` phase (nothing searches any more). `Phase.reading`
becomes `.matching`.

`LookupHit` gains `org`, `title`, `notes` and a `personID`. The lens card
already takes `name` + `info`; `info` becomes the details joined from
org/title/notes rather than a web summary.

`HermesApp.lookup`'s `summary` and doc comment change — they currently
advertise a web search.

### Files deleted

- `HermesGlasses/Services/PersonWebLookup.swift`
- `tests/lookup/main.swift`'s `PersonWebLookup.parse` / `userText`
  assertions (the `PersonLookupGate` assertions stay)

`DirectClient.askOneShot(webSearch:webSearchMaxUses:)` and the
`AIProvider`/`AnthropicProvider` web-search plumbing **stay**: they are
generic, already covered by `tests/providers`, and unrelated to Lookup's
identity source.

## Model

Not bundled today. `tools/export-face.md` documents the conversion, mirroring
`tools/export-yolo.md`:

- **Recommended source:** an ArcFace-class recogniser — InsightFace
  `buffalo_l` (w600k_r50) ONNX, or MobileFaceNet for a smaller package.
  112×112 input, 512-d output, 5-point aligned.
- `coremltools.convert` to `.mlpackage`, committed as
  `HermesGlasses/Models/faceid.mlpackage` so builds stay reproducible
  without Python (the standing rule for `yolo11n`).
- The doc records input size, channel order, normalisation constants and
  output dimension. `FaceEmbedder` asserts them at load rather than
  assuming — a silently mismatched normalisation produces embeddings that
  look fine and match nothing.

**Licensing is a real constraint, not a footnote.** InsightFace's pretrained
weights are released for non-commercial research use. That fits this
project; it must be recorded in the doc so it is not discovered later.

### Model identity

`roster.json` stores the model identifier the embeddings were produced with.
On launch, if the bundled model's identifier differs, the roster is marked
**stale** and Lookup says so with a Re-import action. Embeddings from one
model are meaningless to another, and silently comparing across a model
swap would produce confident nonsense.

## Tooling

### `tools/face-probe.swift`

macOS, compiles the real `FaceMatcher` and the real alignment code in — the
`badge-probe` convention, so the probe measures what ships.

**Mode 1 — coverage (runs with no model).** Vision face detection over every
photo in a folder: how many faces, how large, how frontal, which files have
none. This is the pre-flight over the 45, and it is step one of
implementation.

**Mode 2 — separation (needs the model).** Embeds the roster and prints the
similarity distribution: every intra-person pair (where multiple photos
exist) against every inter-person pair, the closest confusable pairs by
name, and the `acceptThreshold`/`margin` those distributions imply.

**Mode 3 — live (needs the model and device crops).** Point it at person
crops pulled off the device and report which roster member each matches at
the chosen thresholds. This is the gate that decides whether the numbers
from Mode 2 survive contact with `.low` glasses video.

The constants land in the app only after Mode 2, and are re-checked after
Mode 3 — the same discipline `BadgeRegion` records for OCR.

## UI

**`RosterView`** — Settings → People roster. Built from `HermesDesign`
primitives (`HermesSection`, `HermesRow`, `HermesCard`), not a stock `List`:

- Header card: person count, photo count, import date, model-stale warning.
- **Import folder** → `.fileImporter(allowedContentTypes: [.folder])`.
  Progress while embedding, then the import report.
- Thumbnail list, name + org/title, tap for detail.
- **Remove all**, confirmed.

**`LookupView`** — the result card gains org/title/notes and drops any
"searching the web" language. New empty state when the roster is empty
("No roster imported") linking to `RosterView`, and an unavailable state
when `FaceEmbedder.isAvailable == false` ("Face model not installed").

**Lens** — unchanged mechanism (`showPersonLookupOnLens(name:info:)`).
`showLookupSearchingOnLens` loses its `name:` overload and its copy becomes
"Matching…".

## Error handling

| Condition | Behaviour |
| --- | --- |
| No model bundled | Lookup opens to an unavailable state; the gate never arms |
| Empty roster | Empty state, link to import |
| Roster stale (model changed) | Banner + Re-import; matching disabled |
| No face in the live crop | Existing `frontalFace` path — back to scanning |
| Embedding fails | Back to scanning, logged, snap spent (gate cooldown holds) |
| Below threshold | Lens: "Not in the roster" |
| Ambiguous | Lens: "Not sure — too close to call", logged with both names |
| Import: unreadable folder | Report the error, keep the existing roster |
| Import: photo with no face | Counted and named in the report, person still imported |

`ambiguous` is deliberately distinct from `belowThreshold` in the log even
though the wearer sees a similar message: they mean different things when
tuning thresholds.

## Testing

Standalone `swiftc` suites, per house style.

**`tests/face-match/`** (new) — `FaceMatcher` over synthetic vectors:
empty roster; single clear winner; below threshold; two people within the
margin → `ambiguous`; max-not-mean across a person's photos; identical
scores; an embedding of the wrong dimension.

**`tests/roster/`** (new) — `RosterImporter.plan` over synthetic file lists:
flat files; subfolders; mixed; `people.json` merge by name; a JSON entry
matching no photo; non-image files ignored; names with spaces, particles and
a trailing initial preserved verbatim; duplicate names collapsing to one
person.

**`tests/lookup/`** (edited) — web-path assertions removed, gate assertions
kept.

**`tests/apps/`** (edited) — `HermesApp.lookup`'s changed summary.

> Both new `main.swift` files end in `print(...)` then `exit(...)`. New
> assertions go **above** those two lines — appended below they never run and
> the suite still reports green.

Not unit-tested, and honest about it: `FaceEmbedder` (needs the model and a
device), alignment geometry (verified visually through `face-probe` Mode 1),
and the `RosterStore` disk queue (inherits `EncounterStore`'s proven shape).

## Files touched

New:

```
HermesGlasses/Services/People/RosterPerson.swift
HermesGlasses/Services/People/RosterStore.swift
HermesGlasses/Services/People/RosterImporter.swift
HermesGlasses/Services/People/FaceEmbedder.swift
HermesGlasses/Services/People/FaceMatcher.swift
HermesGlasses/Views/RosterView.swift
tools/export-face.md
tools/face-probe.swift
tests/face-match/main.swift
tests/roster/main.swift
```

Edited: `LookupViewModel.swift`, `LookupView.swift`, `HermesApp.swift`,
`HermesSessionViewModel.swift` (lens copy), `SettingsView.swift` (roster
row + route), `CLAUDE.md`, `tests/lookup/main.swift`, `tests/apps/main.swift`.

Deleted: `PersonWebLookup.swift`.

> Every new `.swift` file needs its four hand edits in `project.pbxproj`
> (file reference, build file, group child, sources phase) with sequential
> IDs — this project has no synchronized groups. `faceid.mlpackage` is
> registered as a resource alongside `yolo11n.mlpackage`.

## Stance change

CLAUDE.md currently states, under encounter grouping:

> **Grouping is by badge text, never by face.** … There is no face
> recognition in this app …

The second clause becomes false and must be rewritten rather than left to
contradict the code. New wording, in both the grouping bullet and the Lookup
bullet:

> Face recognition exists in exactly one place: the Lookup app, matching
> against a roster the wearer imported, entirely on-device — no network, no
> provider, nothing leaves the phone. Encounter/People grouping is still by
> badge text and never by face, and the two systems share no identity data:
> a roster match is a momentary read on the lens, never written into an
> encounter.

The Lookup bullet's current text (face crop leaves the device, web search
depth, `NO_MATCH` parsing) is deleted with the code it describes.

## Open risks

### Roster coverage, measured 2026-08-16

`face-probe coverage ~/Downloads/ice2026-people`, 45 images:

- **45/45 have a findable face, and all 45 have eye landmarks.** Nobody in
  the roster is unrecognisable for want of a detectable face, and every
  portrait can be aligned. This was the question worth asking first, and the
  answer is the good one.
- **16 portraits have a face smaller than the recogniser's 112 px input.**
  Face bounding-box width across the set: min 52 px, median 155 px, max 295
  px (of a 512 px frame). The 16 below 112 px get *upsampled* into the model,
  so they carry less detail than the model expects. The smallest —
  `Demitha Manawadu` (52 px), `Vishwani Geeganage` (58 px), `Ryo Hajika`
  (68 px), `Malsha de Zoysa` (69 px) — are the roster entries most likely to
  fail to match, and the cheapest fix is a tighter crop or a better source
  photo for those few.
- **Three portraits are turned ~45° away** (Vision yaw −0.79 rad):
  `Asitha Wickramarachchi`, `Senilka Madurapperumage`, `Thevindu Dilmith`.
  The live probe is gated to near-frontal faces by `frontalFace`, so these
  three will be compared frontal-against-profile — the worst case for an
  embedding. They are the first candidates for a replacement photo.

None of this blocks implementation; it sets expectations and names the ~19
entries whose photos are worth improving before the event.

### Vision feature print, measured and rejected 2026-08-16

The design rejected `VNGenerateImageFeaturePrintRequest` on reasoning. It was
then built and measured, because "it needs no download" is a strong enough
pull to deserve evidence rather than an argument.

`face-probe separation` over the 45 portraits, 990 stranger pairs:

| | cosine |
| --- | --- |
| median stranger pair | 0.571 |
| p99 stranger pair | 0.804 |
| **worst stranger pair** | **0.866** (Ovindu Atukorala ↔ Sashen Matheesha) |

`face-probe simulate` — each portrait degraded the way the live path really
degrades it, then scored against its own original (p10 = the weak end of
same-person, which is what a threshold has to admit):

| variant | p10 same-person | beats 0.866? |
| --- | --- | --- |
| glasses-res 96 px | 0.528 | no |
| glasses-res 64 px | 0.492 | no (4 lost the face entirely) |
| soft focus | 0.558 | no |
| tilt 10° | 0.825 | no |
| under-exposed | 0.940 | yes — sanity check only, near-identical image |

**0 of 4 decisive variants separate.** At glasses resolution the same person
scores ~0.53 against themselves while two different people reach 0.87: the
distributions are not merely overlapping, they are inverted. A stranger
resembles you more than a degraded photo of you does. No threshold exists,
and an app built on this would name people confidently and wrongly.

This is why `FaceEmbedder` has no fallback backend, and it is the standing
answer to "why not just use the built-in one". `FaceEmbedding` keeps the
`.visionFeaturePrint` backend so the probe can re-run this comparison
against any future candidate; the app never selects it.

### Other risks

**The resolution cliff, again.** The roster is crisp 512×512 headshots; the
probe is a face inside a person box inside a `.low` glasses frame at
conversational range. This is the same asymmetry `BadgeRegion`'s header
documents for OCR, and it is why `face-probe` Mode 3 exists as a separate
gate from Mode 2. Thresholds that look excellent on roster-vs-roster pairs
may be unusable live. Mitigation if so: raise the gate's proximity
requirement in `PersonLookupGate` so the face is bigger before a snap fires.

**One photo per person.** With no intra-person pairs, Mode 2 can measure how
far apart *different* people sit but not how far apart the *same* person
sits across pose and lighting — the number that actually determines the
threshold. The importer supports subfolders precisely so this can be fixed
by adding a second photo per person; until then the threshold is calibrated
against inter-person separation alone and should be set conservatively.

**A conference is an adversarial setting for a face matcher.** Lanyard-level
lighting, people in motion, faces at an angle, and 45 candidates who may
include relatives or lookalikes. The `ambiguous` verdict is not a nicety.

**The model is the critical path.** Nothing is testable end-to-end until
`faceid.mlpackage` exists, and its conversion needs a Python environment with
`coremltools` on the developer's machine. Work that does not depend on it —
the store, the importer, the matcher, both test suites, the UI, and
`face-probe` Mode 1 — is sequenced first, so the model blocks only the last
step.

## Sequencing

1. `face-probe` Mode 1 over the 45 photos — coverage, before anything else.
   Its output may change the roster before a line of app code depends on it.
2. `RosterPerson`, `RosterStore`, `RosterImporter` + `tests/roster/`.
3. `FaceMatcher` + `tests/face-match/`.
4. `RosterView` and the Settings route; import works, faceless, reporting
   coverage.
5. `tools/export-face.md`, model conversion, `FaceEmbedder`, `face-probe`
   Modes 2–3, thresholds.
6. `LookupViewModel` rewrite, `PersonWebLookup` deletion, CLAUDE.md.
