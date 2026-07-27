# Encounter Timeline — Design

**Date:** 2026-07-26
**Status:** Approved

## Problem

Conversation capture ("record this conversation") already detects people,
crops their photo, and transcribes what is said — but it throws away *when*.
The transcript collapses into one joined string and the person photos land in
an unordered pile with no link to the moment they were seen or the words
spoken around them. Reviewing an entry tells you that you met three people
and said eighteen things, in no particular relation to each other.

What is wanted instead: a **timeline** — a person is seen, their photo is
taken, their name tag is read, and the conversation is transcribed, all as
timestamped events in one ordered stream.

## Goals

- Every capture produces an ordered, timestamped event stream, not a blob.
- A sighting carries a **name** where a badge can be read.
- Name-tag reading is **on-device by default**; an AI fallback exists but is
  opt-in and clearly disclosed.
- Old entries and single-shot "remember this person" captures keep working,
  with no data migration.
- Nothing about persisting a conversation depends on the network.

## Non-goals

Named explicitly, because several of these appeared in mockups during design:

- **PDF export of a timeline.** Natural follow-up (`LensPDFRenderer` exists);
  a separate spec.
- **A global day timeline** across Lens / Map / People. The event model is
  shaped so this can be layered on later; it is not built here.
- **A cross-encounter person directory.** Badge text does not merge people
  across recordings.
- **Face recognition or re-identification of any kind.** Grouping is by badge
  text alone. Hermes never claims two faces are the same person.
- **Speaker diarization.** See "Honest limitations" below.

## Prior art in this codebase

Three of the four capabilities already exist and are reused unchanged:

- `HermesSessionViewModel.startConversationCapture()` (~line 1424) runs YOLO
  filtered to `person` boxes via `ConversationCaptureModel.people(_:)`,
  dwells 2 s with `DwellTracker`, and crops the person with
  `LensViewModel.crop(_:to:padding:)`.
- `ConversationCaptureModel` gates snaps (10 s apart, 12 max).
- `EncounterStore` persists JSON index + `photos/*.jpg` under Application
  Support.

The new work is the event model, badge OCR, and the review screen.

## Data model

### `EncounterEvent` (new file `Services/Social/EncounterEvent.swift`)

```swift
struct EncounterEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case sighting, speech }
    let id: UUID
    let kind: Kind
    let timestamp: Date
    /// `.speech`: what was said. `.sighting`: unused, empty.
    var text: String
    /// `.sighting`: crops in capture order, first is cover. May be empty
    /// when the photo write failed — the sighting still happened.
    var photoFilenames: [String]
    /// `.sighting`: parsed name tag, when one could be read.
    var badge: Badge?
}

struct Badge: Codable, Equatable {
    enum Source: String, Codable { case onDevice, assisted, manual }
    var name: String?
    var title: String?
    var org: String?
    /// What OCR actually saw, verbatim, so a bad parse is recoverable.
    var rawLines: [String]
    var source: Source
}
```

### `Encounter` (extend)

Gains `var events: [EncounterEvent]`, decoding to `[]` when the key is
absent — the same migration shape `photoFilename` → `photoFilenames` already
uses.

`note` and `photoFilenames` **stay**, written as *derived* values alongside
the events (`note` = speech lines joined, `photoFilenames` = every sighting's
photos in order). `EncounterRow`, the day grouping, and every other existing
reader therefore need no change.

### Events are stored raw and grouped at render — load-bearing

Every sighting is stored as its own event, always. Badge-name grouping is a
pure function applied **at render time**, never at save time.

This is what makes the deferred AI pass work: when a name arrives ten seconds
after the recording stopped and fills in a previously-blank sighting, the
timeline regroups by itself. Grouping at capture time would freeze the
pre-assist answer and there would be no correct moment to redo it.

### Photo filenames

Filenames are assigned by the store as it writes. So
`ConversationCaptureModel` accumulates events holding a `photoIndex: Int?`,
and a new `EncounterStore.save(events:photos:)` resolves index → filename
while writing. A photo that fails to write leaves its event with an empty
`photoFilenames` rather than dropping the event.

## Pure logic

Both types are Foundation-only with standalone `swiftc` suites, per house
style.

### `BadgeParser` (new file `Services/Social/BadgeParser.swift`)

`[String]` of OCR lines → `Badge?`.

- Drops lines with no letters or fewer than 2 characters.
- Strips honorifics (`Dr.`, `Mr.`, `Ms.`, `Mrs.`, `Prof.`).
- **Name**: the first remaining line of 1–4 tokens, title-case or ALL-CAPS,
  containing no digits. ALL-CAPS is title-cased for display.
- **Org**: a line matching an organisation keyword
  (`Ltd|Limited|Inc|LLC|GmbH|University|Hospital|Labs?|Group|Institute|
  College|School|Centre|Center`), else the last unclaimed line.
- **Title**: whatever single line remains between name and org.
- Returns `nil` rather than guessing when no line looks like a name.
- `rawLines` always carries the input verbatim.

Tests: `tests/badge/`.

### `EncounterTimeline` (new file `Services/Social/EncounterTimeline.swift`)

`Encounter` → an ordered timeline. Takes the whole `Encounter` (itself
Foundation-only) so the legacy fallback has `note` and `photoFilenames` to
work from.

```swift
struct EncounterTimeline: Equatable {
    enum Kind: Equatable { case singleNote, conversation }

    struct Row: Identifiable, Equatable {
        enum Content: Equatable {
            /// Cover first; `frameCount == photoFilenames.count`.
            case sighting(photoFilenames: [String], badge: Badge?)
            case speech(text: String)
        }
        let id: UUID          // the first contributing event's id
        let timestamp: Date   // earliest contributing event
        let content: Content
    }

    let kind: Kind
    let rows: [Row]

    static func build(_ encounter: Encounter) -> EncounterTimeline
}
```

- **Kind**: `.conversation` whenever `events` is non-empty. Only the legacy
  path (`events == []`) can produce `.singleNote`.
- **Ordering**: by `timestamp` ascending, stable on ties by insertion order.
- **Grouping**: sightings whose *normalized* badge names match (lowercased,
  whitespace-collapsed, punctuation stripped) collapse into one row — first
  photo is the cover, later photos append as extra frames, and the row keeps
  the earliest timestamp. The merged row's badge is the highest-priority
  source present (`manual` > `onDevice` > `assisted`).
- **Unbadged sightings never merge**, with each other or with anything else.
- **Speech** rows pass through in order, unmerged.
- **Legacy synthesis**: given `events == []`, build a timeline from `note` +
  `photoFilenames`. With ≤1 photo the kind is `.singleNote`; otherwise
  `.conversation`. This is how old entries and single-shot "remember this
  person" captures render on the new screen with no data migration.

Tests: `tests/timeline/`.

## Capture pipeline

### On-device read, at snap time

New `Services/Social/BadgeReader.swift` wraps `VNRecognizeTextRequest` over
the person crop `handleCaptureDetections` already produces.

- `recognitionLevel = .accurate`
- **`usesLanguageCorrection = false`** — badges are proper nouns, and language
  correction mangles surnames into dictionary words.
- Observations below `0.4` confidence are dropped; the rest go to
  `BadgeParser`.

The sighting event is appended to the model **immediately**, with its photo
and no badge. The OCR runs off the main actor and calls back
`ConversationCaptureModel.updateBadge(eventID:badge:)` when it lands. A slow
read never delays capture; a failed one leaves the sighting unnamed.

### Deferred assist, after the stop command

`finishConversationCapture()` **saves the encounter first**, exactly as
today. Only then does it start a detached task over the sightings that came
back with no badge.

Each assisted read is genuinely one-shot: a new
`DirectClient.askOneShot(prompt:photoJPEG:)` builds an `AIRequest` with
`history: []` and never reads or writes the persisted same-day history. The
existing `ask()` would splice badge photos into the user's actual
conversation memory.

Prompt: *"Read the name badge or name tag worn by the person in this photo.
Reply with the lines of text printed on the badge, one per line, and nothing
else. If there is no badge, reply NONE."*

The reply goes through the **same `BadgeParser`**, so there is one parsing
story. A reply of `NONE` (or one that parses to `nil`) leaves the sighting
unnamed. `Badge.source` is `.assisted`.

Bounded, because this is the one part that costs money: reads run
**sequentially**, at most **6 per capture** (against the 12-photo snap cap),
each with a 20 s timeout, and the whole pass is abandoned on the first
`AIProviderError.missingKey` or HTTP auth failure rather than repeating it
five more times. The cap is logged when it truncates.

Results land via a new `EncounterStore.update(encounterID:eventID:badge:)` plus an
`encounterRevision` bump — so an open People screen fills in names live.

### Settings

Both under Settings → People, gated by the existing `social_notes_enabled`:

| Key | Default | Effect |
|---|---|---|
| `badge_ocr_enabled` | **on** | On-device Vision badge reading |
| `badge_assist_enabled` | **off** | AI fallback for unreadable badges |

While assist is on, `PeopleView`'s "Stored on this iPhone only" notice
changes to name the configured provider. That notice is this feature's
honesty and must not stay true-looking when it isn't.

Assist is silently skipped when no provider key is set; the setting row
states why.

### Lens

New `LensContent` case:

```swift
case personSighted(name: String?, subtitle: String?)
```

Rather than overloading `.photoCaptured`, which the visual-query path still
uses. Label `PERSON`; body the name, or "Photo captured" when unnamed;
subtitle line carries `title · org`. Both renderers (`HermesDisplayScreens`,
`SimulatedLensView`) pick it up, and `tests/lens-content/` gains the case so
the accessors stay total.

Shown only at snap time and only for the on-device read. Assisted names
arrive after the recording is over, when there is nothing on the lens to
update.

## Review screen

`EncounterDetailView` switches on `EncounterTimeline.kind` — pure logic
decides, the view only renders.

- **`.singleNote`** keeps exactly today's screen (photo + editable note). A
  single-shot capture is two facts; rendering it as a two-row timeline would
  be a regression.
- **`.conversation`** renders rows from `HermesSection` / `HermesRow` /
  `HermesDivider`:
  - **Sighting** — 52pt thumbnail, name (or "Unnamed"), `title · org`
    beneath, frame count when >1, and a small marker when
    `source == .assisted`. Tapping opens all frames, the verbatim
    `rawLines`, and an editable name field.
  - **Speech** — monospaced timestamp, then the line. The timestamp prints
    only when the minute changes, so a fast exchange is not a column of
    identical clocks.

Correcting a name writes through `EncounterStore.update(encounterID:eventID:badge:)` with
`source: .manual` — the *same* write path the assist pass uses, so there is
one way for a badge to change and one revision bump.

The whole-note `TextField` stays only on `.singleNote`. On a conversation the
note is derived transcript, so it is shown read-only rather than offering an
edit the next derived write would overwrite.

## Failure modes

All silent, all still saving:

| What fails | Result |
|---|---|
| Vision reads nothing | Unnamed sighting, photo kept |
| Assist off, or call fails | Unnamed sighting, no error surfaced |
| No provider key | Assist skipped, reason shown in Settings |
| Photo write fails | Sighting event kept with empty `photoFilenames` |
| Camera never opens | Transcript-only timeline (today's behaviour) |
| Corrupt index | Existing `EncounterStore` behaviour — logged, empty list |

## Honest limitations

- **The mic is the wearer's, and `SFSpeechRecognizer` does no diarization.**
  The transcript is *everything heard*, not who-said-what. A speech row may
  sit next to Sarah's photo without meaning Sarah said it. The review screen
  must not imply otherwise.
- **The glasses live stream only reliably opens at `.low`**, and while it is
  running `capturePhoto()` returns the latest live frame — there is no
  higher-res still to fall back on. A badge at conversational distance may
  simply not resolve. This is the single biggest risk to the feature's
  value and only device testing can settle it.

## Testing

New standalone suites:

- `tests/badge/` — parser: name/title/org extraction, honorifics, ALL-CAPS,
  digit rejection, `nil` on garbage, `rawLines` preservation.
- `tests/timeline/` — ordering, badge grouping, unbadged non-merging, source
  priority on merge, legacy synthesis for both kinds.

Extended:

- `tests/conversation/` — timestamped event recording, `updateBadge`,
  interaction with the existing snap gate.
- `tests/encounters/` — events round-trip, legacy decode, `update(eventID:)`.
- `tests/lens-content/` — the new case.

Then:

```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build
```

Then device. The simulator cannot answer the question this feature turns on —
whether a lanyard badge is legible in a `.low` glasses frame at conversational
distance. That result is reported separately, not folded into a green build.

## Xcode registration

Four new files, four manual `project.pbxproj` edits each (`PBXBuildFile`,
`PBXFileReference`, parent group `children`, target `PBXSourcesBuildPhase`):

- `HermesGlasses/Services/Social/EncounterEvent.swift`
- `HermesGlasses/Services/Social/BadgeParser.swift`
- `HermesGlasses/Services/Social/EncounterTimeline.swift`
- `HermesGlasses/Services/Social/BadgeReader.swift`

Verify with `plutil -lint HermesGlasses.xcodeproj/project.pbxproj`.
