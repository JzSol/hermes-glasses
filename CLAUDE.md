# Hermes Glasses - notes for Claude

Part of the Sidekick project. See README.md for architecture and setup.

## Current state (2026-07-10)

Voice loop and vision loop both work end-to-end on device:
live on-device transcription (SFSpeechRecognizer) → `{"type":"query"}` over
WebSocket → Python bridge → `hermes chat -q [--image] -Q` → response text +
TTS (PCM16 mono 24 kHz) back to the phone. Visual queries trigger a glasses
photo via the DAT camera API.

## Key facts that are easy to get wrong

- **STT is on-device.** The app does NOT stream mic audio to the bridge
  anymore. The bridge's audio/VAD/Google-STT path is legacy fallback only.
- **Audio session uses mode `.default`, not `.voiceChat`** - voiceChat's DSP
  gates speech to the noise floor (~20 dB down). There is therefore NO echo
  cancellation: the recognizer is suspended while Hermes speaks and resumes
  0.7 s after playback ends.
- **Never detach the TTS player node** - `AVAudioEngine.detachNode` on a live
  node raises NSException (SIGABRT). The player is attached once and reused.
- **SFSpeechRecognizer:** `task.cancel()` fires the old task's handler with an
  error. Restart cycles are guarded by a generation counter or the recognizer
  goes deaf after the first suspend/resume.
- **Glasses camera needs a separate permission** granted through the Meta AI
  app: `wearables.requestPermission(.camera)` (the Photo test button runs it).
  Streams fail with `permissionDenied` otherwise.
- **Camera streams are one-shot:** fresh `addStream()` per capture, stopped
  via `defer` on every path. Config matches Meta's CameraAccess sample
  (`.raw`, `.low`, 24 fps).
- **WebSocket frames:** binary from app = mic audio (legacy). Photos travel
  ONLY as base64 JSON. The bridge runs `websockets.serve(..., max_size=16MiB)`
  because a base64 JPEG exceeds the 1 MiB default.
- **Display HUD (Ray-Ban Display):** `HermesDisplayManager` attaches
  `addDisplay()` to the SAME DeviceSession as the camera. Every display
  call is best-effort - errors are logged, never surfaced. Settings keys:
  `display_hud_enabled` (default true), `display_silent_mode`.
- **Glasses mic and the HUD are mutually exclusive.** The glasses mic is
  Bluetooth HFP (the DAT SDK has no audio capability); an active HFP/SCO
  link makes the glasses firmware show its CALL SCREEN on the lens, which
  covers all DAT display content. iPhone mic = HUD visible; glasses mic =
  call screen. Firmware behavior - cannot be overridden from the app.
- **Headset mode is the pocket setup:** `MicSource.headset` routes HFP to
  earbuds (never to the glasses - port chosen by name heuristic in
  `HermesAudioManager.looksLikeGlasses`), so the lens keeps the HUD while
  mic + TTS live in the ears. Falls back to the iPhone mic (with a notice)
  when no non-glasses HFP device is present.
- **Device context:** every query carries a context line (time, location,
  motion, connectivity, battery, weather). Direct mode (the provider path)
  gets it as a SECOND, uncached system block (persona block stays first + cached);
  bridge mode gets it as a "[Context: …]" prefix on the query text - the
  bridges need no changes. History stores raw user text only. Keys:
  `context_enabled` / `context_precise_location` (both default true).
- **On-device intents (`IntentDetector`):** the finalized transcript is
  classified BEFORE the AI brain. "take me to X" / "I want to go to X" starts
  `NavigationController` (MapKit route + CoreLocation) and never hits the AI;
  the lens shows a Mapbox static map re-centered on the user (https images
  only, 600x600, throttled >=15 m and >=4 s). "what is X" runs the normal
  answer AND fetches a Wikipedia lead image, rendered as text + `Image` on the
  lens. Keys: `navigation_enabled`, `definition_images_enabled`; Mapbox token
  in Keychain via `MapCredentials`. All display-only + best-effort.
- **Social encounters ("remember this person"):** a whole-utterance command
  (NOT a substring - "remember" is too common) starts a capture: the glasses
  photo and the spoken note run IN PARALLEL (`encounterPhotoTask` is joined by
  `finishEncounter`, so they can land in either order). The next finalized
  utterance is claimed as the note before any other intent runs; "cancel"
  discards; 30 s of silence saves the photo with an empty note; a camera
  failure saves the note alone. Persisted by `EncounterStore` to Application
  Support (`encounters.json` + `photos/*.jpg`) - no AI, no bridge, no network.
  Reviewed in `PeopleView`. Key: `social_notes_enabled`.
- **Settings is a hub, not one scroll** (`Views/SettingsView.swift`, extracted
  out of ContentView): a glasses status card plus one row per area, detail one
  tap deeper. Text the user types (bridge endpoint, API key) is owned by the
  ROOT SettingsView and committed on Done *and* swipe-dismiss - sub-pages take
  bindings, so nothing is lost whichever page is open.
- **Lens view (Object Snap):** live glasses video via a persistent stream -
  the ONE exception to one-shot camera streams, owned by
  `HermesCameraManager.startLiveStream`/`stopLiveStream` and running only
  while `LensView` is on screen. Lens does NOT need (and must never start)
  the voice session: it connects a camera-only DeviceSession via
  `HermesSessionViewModel.ensureCameraSession()` (reuses the voice session
  when one is live) and releases it on close - opening Lens never leaves
  the mic listening. While it runs, `capturePhoto()` serves the
  latest live frame as JPEG (voice visual queries keep working; no second
  stream). Detection: bundled `yolo11n.mlpackage` (ultralytics export,
  `nms=True` - see `tools/export-yolo.md`) via `VNCoreMLRequest`;
  `ObjectDetector` converts Vision's bottom-left boxes to top-left-origin
  `Detection`s ONCE at that boundary. `DwellTracker` (pure logic, tested in
  `tests/dwell/`) fires a snap after 2 s of center-reticle coverage with
  IoU-based identity + post-snap cooldown. Snaps are session-only, in
  memory, no AI/bridge/network.
- **Conversation capture ("record this conversation"):** whole-utterance
  start/stop commands (`IntentDetector.conversationStartCommands` /
  `conversationStopCommands`; stop is checked with `isConversationStop`
  ONLY while active - during a capture EVERY utterance is claimed as
  transcript before intents/AI, nothing reaches the brain). Runs inside
  the voice session; vision side reuses the Lens machinery (live stream +
  YOLO + `DwellTracker`) filtered to `person` boxes - a 2 s look snaps a
  crop, gated by `ConversationCaptureModel` (10 s between snaps, 12 max,
  tested in `tests/conversation/`). Stop saves ONE encounter: full
  transcript as the note + every snap. `Encounter` now holds
  `photoFilenames: [String]` (decoder migrates the old single
  `photoFilename` key; `photoFilename` is a computed first-photo
  accessor). `endSession()` SAVES a running capture (silently) instead of
  discarding it - opposite of the half-finished "remember this person"
  rule. Same `social_notes_enabled` gate; UI toggle is the Record chip in
  the status row.
- **Replies with options become buttons** (`ChoiceDetector`, pure, tested in
  `tests/choices/`). "A) Sydney, B) Melbourne, …" turns into lens buttons,
  chat chips, and a line on the simulated lens; tapping one submits the
  option's WORDS, not its letter. Deliberately conservative - two or more
  markers, ascending from A/1, each with text - because a false positive
  replaces Stop/Repeat on a display the wearer can't easily escape. A reply
  carrying options never auto-dwells away.
- **Mic tap-to-switch cannot pre-filter by device.** HFP ports only appear
  in `availableInputs` once the audio category allows Bluetooth, and the
  iPhone-mic path deliberately doesn't (it stops iOS hijacking the input).
  Enumerating anyway made connected glasses report "not available", so
  `toggleMicSource` walks to the next route that actually takes and
  `setMicSource` returns whether it did.
- **The Meta AI camera grant is requested AT PAIRING**
  (`ensureGlassesCameraAfterPairing`, fired from `ContentView.onChange` of
  `registrationState`), offered again in onboarding, shown in Settings →
  Devices → Glasses camera, warned about under the eye toggle, and
  requestable from the Lens error state. It used to be requested in exactly
  one place - the Photo test button - so anyone who never pressed it hit
  "camera unavailable" in Lens and photo-less encounters, with nothing
  explaining why. Never gate a feature on this grant without offering the
  interactive request; `ensureCameraPermission(interactive: false)` alone is
  a dead end.
- **The test panel must work from a cold start.** It exists to diagnose a
  broken setup, so requiring a running session is backwards. `testPhoto`
  borrows a camera-only session via `withCameraSession` and releases it;
  `testVisualQuery` warms one first; `testDisplay` already made its own.
  Only bridge-mode brain tests still need a session, because they need the
  socket.
- **Stream resolution is negotiated, never assumed.** `addStream` returns a
  bare `nil` (no thrown error, no reason) when the firmware won't serve the
  config you asked for. The Lens live stream used to demand `.high` while
  every path that works on device - one-shot capture, and Meta's own
  CameraAccess sample - uses `.low`; the symptom was "Could not open the
  glasses camera stream" plus a photo-less "remember this person".
  `startLiveStream` now walks `.high → .medium → .low`, twice, and logs
  which one opened. If you add a config knob, ladder it.
- **Navigation needs location BEFORE routing.** `MKDirections` routes from
  `MKMapItem.forCurrentLocation()`, which needs a fix to already exist.
  `startUpdatingLocation()`/`startUpdatingHeading()` therefore run at the
  top of `begin()`, not after the route resolves - otherwise the map screen
  only worked if a voice session had already turned location on. For the
  same reason `handle(location:)` records `lastLocation` *before* its route
  guard: fixes arrive while the route is still computing.
- **The compass must be legible without a Mapbox token.** Heading rotates
  the lens map image, but that image only exists with a token - so turning
  the phone looked like it did nothing. `renderFrame` appends
  "<destination> is to your right" to the step text, which changes as you
  turn either way.
- **Navigation/display callbacks are wired in `init`, not `startSession`.**
  `wireDisplayAndNavigation()` must stay in the initialiser: the map screen
  can start a route with no voice session running, and when `onRoute` was
  nil the route computed correctly but nothing received it - the banner sat
  on "No route running" and every failure was silent. Anything reachable
  without a session must not depend on session-scoped wiring.
- **Heading comes from the phone, never the glasses.** The DAT SDK exposes
  no compass, so `NavigationController` runs `startUpdatingHeading()` and
  publishes `heading` + `relativeBearing` on `RouteSnapshot`. It drives
  three things: the in-app map camera (`followsHeading: true`), the
  direction arrow in the map banner, and the `bearing` parameter on the
  Mapbox static URL so the LENS map turns with the wearer instead of
  staying north-up. Heading repaints are gated at 20° (`minTurnDegrees`) -
  hand-shake would otherwise saturate the lens send throttle. Bearing maths
  is pure and tested in `tests/bearing/`.
- **Two ways to start a route.** Voice resolves a name
  (`start(destination:mode:)`); the map screen's search passes an already
  resolved `MKMapItem` (`start(place:mode:)`) so the user gets the place
  they tapped, not a second geocode of the same string. Suggestions come
  from `PlaceSearch` (MKLocalSearchCompleter), biased to the visible map
  region.
- **Camera permission is TWO different grants.** The glasses camera is
  authorised through the Meta AI companion app
  (`wearables.checkPermissionStatus(.camera)`); the iPhone camera through
  iOS (`AVCaptureDevice`). Capture paths must gate on
  `ensureVisionPermission(interactive:)` and `hasVisionSource`, never on
  `ensureCameraPermission` / `isGlassesConnected` directly - those are the
  glasses answers, and in phone mode they are always no. Four paths were
  silently disabled this way: the encounter photo, direct-mode visual
  queries, conversation-capture snaps, and bridge photo requests.
- **One AVCaptureSession per camera.** In phone mode the session already
  streams for the 5b feed, so a second consumer must observe rather than
  start its own: `addVisionFrameObserver(_:_:)` (keys: `lens`,
  `conversation-capture`) and `visionStreamIsShared`. Never call
  `vision.stopLiveStream()` for a stream you didn't start - it blanks the
  screen the user is looking at.
- **The eye is a visible toggle, not an inference.** `HermesEyeToggle`
  (Glasses / Phone) sits in the session header and writes
  `phoneModePreference` (`.auto` / `.always`); it shows a warning triangle
  when Glasses is selected but unreachable. Don't reintroduce prose that
  explains an inferred state - say it in the control.
- **Never offer "Connect Glasses" to registered glasses.** `startRegistration`
  on an already-registered user throws "User is already registered", which
  is a dead end. `ContentView.GlassesSetupState` splits `notPaired` (pair
  them) from `pairedButUnreachable` (wake them, or re-pair via Settings →
  Devices). Pairing errors route to Devices through `SettingsRoute`.
- **"Are glasses paired" is NOT "can a glasses session start".**
  `registrationState == .registered` and a non-empty `wearables.devices`
  both stay true for glasses that are paired but out of range, while
  `createSession` throws `DeviceSessionError.noEligibleDevice`. The only
  honest predicate is the SDK's own selector:
  `deviceSelector.activeDevice != nil` (`HermesSessionViewModel.glassesAvailable`).
  Getting this wrong made Auto phone-mode never fall back, so Lens, Start
  listening, and the encounter photo all insisted on absent glasses.
  Route selection itself is pure and tested in `tests/vision-routing/`.
- **Never predict hardware without a fallback.** Eligibility can lapse
  between the check and the start, so the glasses path falling through to
  the phone is handled at three points: `startSession()`, `LensViewModel.start()`,
  and `captureVisionPhoto()`. `PhoneCameraManager.capturePhoto()` will spin
  the camera up for a single frame if nothing is streaming, so either eye
  can serve a still. `logVisionDiagnostics(_:)` prints registration, device
  link states, `activeDevice`, and the chosen route - use it before
  theorising about which eye was picked.
- **The vision route is pinned for the life of a session.** `visionRoute`
  is recomputed only while nothing is pinned; a session or the Lens view
  calls `pinVisionRoute`. Without this, a momentary SDK flap redirected a
  capture to a camera that wasn't running (a "remember this person" note
  saved with no photo).
- **The visual language lives in `Views/HermesDesign.swift`** (imported
  from the "Hermes Glasses UI" design doc, turns 4 + 5). ONE accent -
  terracotta `#C4622D` and its shades; warm neutrals (cream `#F7F5F2`
  canvas, warm black `#1C1B1A`), never stock iOS greys or per-row rainbow
  icons. Build screens out of the primitives there (`HermesSection`,
  `HermesCard`, `HermesRow`, `HermesIconTile`, `HermesChip`,
  `HermesStatusPill`, `HermesDeviceCard`, `HermesScrollPage`) rather than
  re-styling a `List`; pages that keep a stock `Form` (Voice, Display,
  Context…) call the local `hermesFormStyle()` so the canvas matches.
  `HermesMark` is the winged logo as a `Shape` (SVG polygons on a 140x72
  canvas); the wordmark is system `.heavy` + wide tracking, since no
  Montserrat file ships with the app.
- **The test panel is NOT on the session screen** - it lives in
  Settings -> Developer (design 5d) along with the diagnostics rows.
  Nothing floats over the conversation.
- **The session screen's quick actions** (Lens / People / Map / Log) are
  the way into every feature screen; the header keeps only the lockup,
  the glasses pill, new-chat, and the gear.
- **`NavigationMapView` is the in-app route screen** (design 4f), fed by
  `HermesSessionViewModel.activeRoute`, which mirrors
  `NavigationController.onRoute`. Read-only: routes still start by voice
  only; the one control is End route (== "stop navigation").
- **`VoiceCommandCatalog` feeds the "What can I say?" page** from the
  detectors' own phrase lists (`IntentDetector.navTriggers` etc. are internal,
  NOT private, for exactly this). Never hand-copy trigger phrases into the UI -
  add them to the detector and the tester-facing list updates itself.

## Build & run

```bash
# iOS (from repo root; use your own device ID from `xcrun devicectl list devices`)
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build

# Bridge (from bridge/) - logs to stdout; tests:
python -m unittest test_hermes_bridge -v
```

## Next milestones

- Route audio through the glasses microphone (`startCapture(useGlassesMic:
  true)`, HFP path) - currently the iPhone mic is used.
- Normalize EXIF rotation of glasses photos before sending to Hermes.
- Word-boundary matching for visual keywords ("outlook" currently matches
  "look").
