# Onboarding and phone mode — design

Date: 2026-07-24
Screens: design doc 1d (onboarding), 5a (Devices), 5b (phone mode)

## Problem

Three gaps a first-time user hits immediately:

1. **No permissions on-ramp.** Mic and speech authorization are requested
   deep inside `startSession()`; camera has no `NSCameraUsageDescription`
   at all. A new user's first action produces system dialogs with no
   explanation, and a denial surfaces as an error alert mid-session.
2. **Start listening is a dead button without glasses.** It is disabled
   until `registrationState == .registered`, so someone who has not paired
   (or left the glasses at home) cannot use the app at all.
3. **Phone mode (5b) is not implemented.** The Devices row is a `Soon`
   badge. The iPhone camera cannot act as the eye, and there is nothing
   that shows what the lens *would* be displaying.

## Decisions

| Question | Decision |
| --- | --- |
| First launch | Three-step wizard: Glasses → Permissions → Ready |
| No-glasses fallback | Session starts in phone mode immediately; the UI names the mode rather than asking |
| Simulated lens location | Replaces the session screen body while a phone-mode session runs |
| Camera duty cycle | Live for the whole phone-mode session |
| "Use this iPhone" | Three-state preference: Auto (default) / Always / Off |

## Architecture

Three independent units, each usable without the others.

### 1. `PermissionsCoordinator` — Services/PermissionsCoordinator.swift

`@MainActor @Observable`. Wraps the three system authorizations behind one
readable surface so the wizard, Settings, and `startSession()` all agree on
what is granted.

```swift
enum PermissionKind: CaseIterable { case microphone, speechRecognition, camera }
enum PermissionState { case notDetermined, granted, denied }

func state(of kind: PermissionKind) -> PermissionState   // sync, no prompt
func request(_ kind: PermissionKind) async -> PermissionState
func requestEssentials() async                            // mic, then speech
var essentialsGranted: Bool                               // mic && speech
```

Reads map to `AVAudioApplication.shared.recordPermission`,
`SFSpeechRecognizer.authorizationStatus()`, and
`AVCaptureDevice.authorizationStatus(for: .video)`. Requests are sequential —
two concurrent system dialogs stack badly.

Depends on: AVFoundation, Speech. Nothing in the app depends on it except
the wizard, the session view model's preflight, and the Devices page.

Location and motion stay just-in-time. They are optional context features,
already requested lazily by `DeviceContextProvider` and
`NavigationController`, and putting them in the wizard would ask for
location before the user has any reason to grant it.

### 2. `VisionSource` — Services/VisionSource.swift

The seam that makes phone mode reach every camera feature. Five call sites
use the glasses camera today (visual queries, "remember this person",
conversation capture, the Lens screen, the Photo test); all five move to
this protocol and gain phone mode at once.

```swift
struct VisionFrame { let image: UIImage?; let pixelBuffer: CVPixelBuffer? }

protocol VisionSource: AnyObject {
    var sourceLabel: String { get }        // "Ray-Ban camera" / "iPhone camera"
    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws
    func stopLiveStream()
    func capturePhoto() async throws -> Data
}
```

`VisionFrame` is exactly what `LensViewModel` already reduces a
`MWDATCamera.VideoFrame` to, so the conversion moves one level down rather
than being invented.

- `HermesCameraManager` conforms via an adapter that decodes `VideoFrame`
  once at the boundary. Its DAT-specific `configure(session:)` / `reset()`
  stay off the protocol — they are lifecycle, not capture.
- `PhoneCameraManager` (new) wraps `AVCaptureSession`: back wide-angle
  camera, `AVCaptureVideoDataOutput` (BGRA) on a serial queue, 4:3 preset
  to match the glasses' aspect. `capturePhoto()` returns a JPEG of the
  latest live frame — the same "no second stream" trick
  `HermesCameraManager` uses — so a visual query never stutters the feed.

### 3. `LensContent` — Services/LensContent.swift

A Foundation-only value describing what is on the lens right now. Lets a
SwiftUI view render the same thing the glasses render without either
renderer knowing about the other.

```swift
enum LensContent: Equatable {
    case blank
    case listening(partial: String)
    case thinking(query: String)
    case photoCaptured
    case reply(text: String, speaking: Bool)
    case definition(text: String, imageURL: String?)
    case navigation(title: String, step: String, eta: String, mapURL: String?)
    case encounterPrompt
    case recording
    case encounterSaved(note: String)
    case newConversation
}
```

Text derivation (`headline`, `body`, `statusLine`) lives on the enum, not in
the view, so it unit-tests standalone with `swiftc` like `DwellTracker`.

`HermesDisplayManager` gains `private(set) var content: LensContent` plus an
`onContentChanged` callback, assigned in every `show*` and `clear()`.

**Critical:** `content` must be assigned *before* each method's
"is the display attached" guard. In phone mode no `DeviceSession` is
attached, so a guarded assignment would leave the simulated lens blank —
which is the whole feature.

## Mode selection

```swift
enum PhoneModePreference: String { case auto, always, off }   // phone_mode_preference
enum VisionRoute { case glasses, phone }
```

On `HermesSessionViewModel`:

```
glassesAvailable = wearables registrationState == .registered
visionRoute:  .always → .phone
              .off    → .glasses
              .auto   → glassesAvailable ? .glasses : .phone
vision:       visionRoute == .phone ? phoneCamera : cameraManager
```

`glassesAvailable` is the single signal for both route selection and
`Start listening` enablement, so the button and the mode can never
disagree. It is registration, not link state: the glasses often report
registered while momentarily out of Bluetooth range, and dropping to phone
mode for a two-second dropout would be worse than waiting.

`startSession()` in phone mode:

1. Request camera permission. On denial the session still starts — voice
   works, visual queries return the existing photo-error path.
2. Skip `ensureCameraSession()` and the display attach — there is no
   glasses session to attach to.
3. Start the phone live stream and set `phoneModeActive = true`.
4. Continue with audio + recognition exactly as today; the mic is already
   the iPhone's by default.

`Start listening` is enabled whenever `visionRoute == .phone` or
`glassesAvailable`; it is disabled only in the one honest dead case —
preference `.off` with no glasses. The header pill reads `Phone mode`, and the bottom
bar reads `Listening · phone mode`, so the active sensor is never a
mystery. Nothing is sticky: the next session re-evaluates and picks the
glasses back up automatically.

## Views

- `OnboardingView` — the wizard, in the Hermes design system. Step 1
  auto-advances when `registrationState` becomes `.registered`; its
  secondary action ("Use this iPhone instead") just advances, since Auto
  already falls back. Step 2 lists the three permissions with live state
  and an `Allow access` button; `Continue` unblocks once mic and speech are
  resolved (granted *or* denied — a denial must not trap the user, only
  warn). Step 3 is the green-check summary and `Start Session`. Gated at
  the app root on `onboarding_complete`, beside the existing
  `RegistrationView` overlay.
- `SimulatedLensView` — renders a `LensContent` inside the framed
  `SIMULATED LENS · 640×200` box of 5b.
- `PhoneModeSessionView` — the 5b screen: `PHONE MODE` header with a
  Devices pill, live feed with the simulated lens overlaid, `iPhone rear
  cam` / fps chips, preset and camera tiles, speak-replies toggle, then the
  shared waveform bar and End. A transcript button flips to the normal chat
  body, so the conversation is never unreachable.
- `ContentView` swaps its body for `PhoneModeSessionView` while
  `phoneModeActive` and the user has not flipped to the transcript.
- `DevicesPage` replaces the `Soon` badge with the three-state picker and
  drops "Not wired up yet" from the footer.

## Error handling

Every failure degrades rather than blocks, matching the existing camera and
display rules.

- Camera permission denied in phone mode → session still starts; the feed
  area shows "Camera access denied — Open Settings", visual queries return
  the existing photo-error path.
- `AVCaptureSession` fails to start → same treatment, banner in the feed
  area, voice loop untouched.
- Speech or mic denied → wizard warns and Settings-links; `startSession()`
  keeps its current error surface.
- Glasses appear mid-session in Auto → no hot switch. The current session
  keeps its source; the next one picks glasses. Hot-swapping the vision
  source mid-session would tear down a stream under the Lens screen and the
  conversation capture at once, for no user benefit.

## Testing

- `tests/lens-content/main.swift` — pure `LensContent` text derivation and
  equality, run with `swiftc` (no XCTest target in this project).
- `PermissionsCoordinator`, `PhoneCameraManager`, and the views wrap system
  frameworks; they are verified by `xcodebuild` plus on-device runs, as
  with `HermesCameraManager` today.
- Regression: the seven existing standalone suites must still pass, since
  `VisionSource` touches `LensViewModel` and the conversation-capture path.

## New files

Each needs the four manual `project.pbxproj` insertions (no synchronized
groups in this project).

| File | Purpose |
| --- | --- |
| `Services/PermissionsCoordinator.swift` | mic / speech / camera state + requests |
| `Services/VisionSource.swift` | protocol, `VisionFrame`, glasses adapter |
| `Services/PhoneCameraManager.swift` | `AVCaptureSession` vision source |
| `Services/LensContent.swift` | neutral lens-content model |
| `Views/OnboardingView.swift` | three-step first-run wizard |
| `Views/SimulatedLensView.swift` | `LensContent` → SwiftUI, framed as 5b |
| `Views/PhoneModeSessionView.swift` | the 5b session screen |

Also: add `NSCameraUsageDescription` to `HermesGlasses/Info.plist`.

## Out of scope

- Front-camera support and the "Lens preset" tile being interactive; the
  tiles render current state only.
- Hot-swapping vision source mid-session (see Error handling).
- Simulating the lens while the glasses are the active source — the real
  lens is authoritative there.
