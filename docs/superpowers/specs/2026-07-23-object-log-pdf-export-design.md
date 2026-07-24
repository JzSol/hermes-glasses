# Object Log & PDF Export for Lens — Design

Date: 2026-07-23
Status: Approved (design), pending implementation plan

## Goal

In the Lens (Object Snap) screen, accumulate a per-object log during a session
and export it as a shareable PDF (e.g. to WhatsApp). Each logged object shows
its name, a cropped image, how many times it was looked at, and the total time
the user looked at it. Sessions are saved to disk so past sessions can be
browsed and re-exported. Other export formats may come later; PDF is the only
format for v1.

## Non-goals (v1)

- No editable/custom object names — raw YOLO labels only.
- No re-identification of the same physical object across separate looks
  (identity is per continuous gaze; aggregation is by label).
- No export formats other than PDF.
- No AI/bridge/network involvement — everything is on-device, like today's Lens.

## Decisions (from brainstorming)

- **Look-time semantics:** *Sum all looks by label.* One log entry per YOLO
  label, aggregating every completed look on that label across the session.
- **Naming:** raw YOLO label (`person`, `cup`, `chair`, ...).
- **Persistence:** saved to disk, mirroring `EncounterStore`, so past sessions
  are browsable and re-exportable.
- **Export UX:** both — an Export button on the live Lens screen for the
  current session, and a new "Object Log" browse screen for past sessions,
  each with its own Export.
- **PDF layout:** one row per object — crop thumbnail on the left, name + total
  look-time + look count on the right.

## Data model

### A "look" and its duration

A **look** is a continuous gaze on an object that reached the existing 2 s dwell
snap threshold. Its duration is measured from when the gaze first landed on the
object (0 s) until the gaze leaves it (reticle exits the box, or the target
changes) — so it includes the initial 2 s plus any additional hold. Glances
shorter than 2 s never snap and are ignored entirely (no image, no count, no
time contribution).

### Log entry (per label, aggregated)

```
label: String            // YOLO label, e.g. "person"
totalLookTime: TimeInterval  // sum of every completed look's duration
lookCount: Int           // number of completed looks (== number of snaps of this label)
image: UIImage           // representative crop — the first snap of this label
firstSeen: Date
lastSeen: Date
```

## Components

### 1. `DwellTracker` (existing, `Services/Lens/DwellTracker.swift`) — emit completed looks

`DwellTracker` today fires a snap at 2 s and discards `elapsed`. Extend it so it
reports the total duration of a look when that look ends.

- `DwellUpdate` gains a field `completedLook: CompletedLook?` where
  `CompletedLook` carries `(label: String, duration: TimeInterval)`. It is
  non-nil **exactly once**, on the update where a *snapped* gaze segment ends
  (the reticle leaves the object or the target changes to a different object).
- Track the segment start time (already implicit in `dwellStart`) and a flag for
  whether the current segment has snapped. Only segments that snapped emit a
  `completedLook`.
- Add `flush(at: TimeInterval) -> CompletedLook?` called on session stop: if the
  current segment has already snapped, emit its duration up to the passed stop
  time so the last object being looked at when Lens closes still counts. Passing
  the timestamp in keeps the tracker time-source-agnostic, as it is today.
- Remains UIKit/Vision-free so `tests/dwell/main.swift` still compiles with plain
  `swiftc`.

`Detection` and `DwellUpdate` live in this file; `Detection` is shared with
Conversation capture and must not change shape.

### 2. `LensLogAggregator` (new, pure Foundation) — the summing math

A small `struct`/`class` with no UIKit dependency, so the aggregation is unit
tested directly rather than only through the UI.

```
mutating func recordSnap(label: String, at: Date)      // ensure entry, stamp firstSeen
mutating func recordLook(label: String, duration: TimeInterval, at: Date)  // += duration, += 1 count, update lastSeen
func entries() -> [Entry]                                // sorted by totalLookTime desc
```

`Entry` here is image-free (label, totalLookTime, lookCount, firstSeen,
lastSeen). Images are held separately by the view model.

### 3. `LensViewModel` (existing, `ViewModels/LensViewModel.swift`) — wire it together

- Owns one `LensLogAggregator` plus a `[label: UIImage]` map (first crop wins).
- In `runCaptureEffect` (where a snap is created today): also call
  `aggregator.recordSnap(label:at:)` and store the crop in the image map if the
  label is not yet present.
- When handling a `DwellUpdate` whose `completedLook` is non-nil: call
  `aggregator.recordLook(label:duration:at:)`.
- The existing live `snaps: [LensSnap]` strip is unchanged — it stays as
  per-snap visual feedback. The aggregated log is separate and is what gets
  saved and exported.
- Expose a computed `logEntries: [LensLogEntry]` (aggregator entries joined with
  their images) for the export button and, if desired, a live summary.
- On `stop()`: call `dwell.flush(at:)`, fold the result into the aggregator, then
  if the log is non-empty, save a `LensSession` via the store (silently) and bump
  a revision. This mirrors conversation-capture's save-on-stop behavior.

### 4. `LensSessionStore` (new, `Services/Lens/LensSessionStore.swift`) — persistence

Mirrors `EncounterStore` exactly.

- Root: `Application Support/LensSessions/`, with `index.json` and a `photos/`
  subdirectory of JPEGs.
- Model:
  ```
  struct LensSession: Codable, Identifiable {
      let id: UUID
      let startedAt: Date
      let endedAt: Date
      var entries: [Entry]
      struct Entry: Codable {
          let label: String
          let totalLookTime: TimeInterval
          let lookCount: Int
          let photoFilename: String   // file inside photos/
      }
  }
  ```
- API: `save(startedAt:endedAt:entries:images:)` (writes one JPEG per entry,
  named `<sessionId>-<index>.jpg`, appends to the index, rewrites `index.json`
  atomically), `all()` (newest first), `photoData(for:)`, `delete(id:)` (also
  removes JPEG files). Tolerant of a corrupt/missing index like the encounter
  store. Foundation-only, `@unchecked Sendable`.

### 5. `LensPDFRenderer` (new, `Services/Lens/LensPDFRenderer.swift`) — PDF generation

- Built on `UIGraphicsPDFRenderer` (PDFKit not required for generation).
- Input: either an in-memory `[LensLogEntry]` (export-now from the live screen)
  or a saved `LensSession` + its loaded images. A single internal render path
  takes `(title, rows)` so both callers share it.
- Layout: a title line (session date), then one row per object — crop thumbnail
  on the left, `name · total time · (N looks)` on the right. Rows paginate when
  they overflow a page.
- Time formatting helper: `< 60 s` → `"14.2s"`; `>= 60 s` → `"1m 04s"`.
- Returns `Data`.

### 6. UI

- **Lens toolbar (`Views/LensView.swift`):** add an Export button, enabled only
  when the log is non-empty. Renders the current session's PDF from the live
  aggregator and presents a share sheet (`ShareLink` or
  `UIActivityViewController`) so it can go to WhatsApp. Exporting does not stop
  the session; the session still saves normally on close.
- **`ObjectLogView` (new, `Views/ObjectLogView.swift`):** modeled on
  `PeopleView`. Lists saved sessions newest-first, grouped by day, each row
  showing the date and object count. Re-reads on a `lensSessionRevision` id.
- **`LensSessionDetailView` (new):** the row list for a saved session (image +
  name + total time + count), plus an Export/Share button (shares the rendered
  PDF) and a Delete button.
- **Entry point:** a new "Object Log" row in the Settings hub
  (`Views/SettingsView.swift`), placed next to the People entry.

### 7. Session-VM wiring (`ViewModels/HermesSessionViewModel.swift`)

Mirror the encounter wiring so views hold no state:
- Hold a `LensSessionStore` instance.
- `var lensSessionRevision: Int` bumped after a save/delete.
- Read-through helpers: `allLensSessions()`, `lensSessionPhoto(_:)` /
  `lensSessionPhotos(_:)`, `deleteLensSession(_:)`.

## Data flow

```
live frames → ObjectDetector → [Detection]
   → DwellTracker.update → DwellUpdate{ progress, target, snap, completedLook }
        snap != nil      → LensViewModel.runCaptureEffect → crop → LensSnap (strip)
                                                          → aggregator.recordSnap + store image
        completedLook    → aggregator.recordLook
   LensView Export button → LensPDFRenderer(logEntries) → share sheet
   LensViewModel.stop()   → dwell.flush → aggregator → LensSessionStore.save → bump revision
ObjectLogView → HermesSessionViewModel.allLensSessions → LensSessionDetailView
   → Export → LensPDFRenderer(session, images) → share sheet
   → Delete → LensSessionStore.delete → bump revision
```

## Error handling

- All camera/detection paths already best-effort; unchanged.
- Store I/O follows `EncounterStore`: atomic index writes, tolerant loads, log
  and continue on failure. A save failure on stop is logged, never surfaced, and
  never blocks closing Lens.
- PDF generation failure returns `nil`/throws; the UI shows a non-fatal notice
  and leaves the session intact.
- Empty log on stop → no session saved (nothing to save).

## Testing

- `tests/dwell/main.swift` (extend): a snapped segment that ends emits a
  `completedLook` with the full segment duration; a sub-2 s glance emits none;
  two separate looks at the same label produce two completed-look events;
  `flush(at:)` emits the in-progress look only if it had snapped.
- New `tests/lenslog/` (or co-located, Foundation-only, plain `swiftc`):
  - `LensLogAggregator`: recordSnap creates an entry and stamps firstSeen;
    recordLook sums durations and counts; multiple labels stay separate; entries
    sort by totalLookTime desc.
  - `LensSessionStore`: save writes JPEGs + index; `all()` returns newest-first;
    `photoData(for:)` round-trips bytes; `delete` removes both index entry and
    JPEG files; corrupt index tolerated.
- PDF layout is visual; no automated test (manual verification on device).

## Build

iOS: `xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses
-destination 'generic/platform=iOS' build`. Standalone logic tests via `swiftc`
per the existing `tests/` pattern.
