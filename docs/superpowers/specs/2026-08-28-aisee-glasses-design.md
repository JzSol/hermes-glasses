# AiSee glasses (Realtek RTK SDK) — sample app and Hermes integration

**Date:** 2026-08-28
**SDK:** RTKAIDeviceConnection 1.6.4 (280), RTKLEFoundation 1.8.0 (1394), from
`~/Downloads/RTKAIDeviceConnectionSDK_demo-beta`
**Status:** approved design, pre-implementation

## Goal

1. Prove the AiSee glasses work end to end from a minimal, self-written SwiftUI
   app: BLE connect, battery, still photo, live video stream, microphone.
2. Add the AiSee glasses to Hermes as a second glasses vendor, alongside Meta
   Ray-Ban (DAT SDK), reusing the exact code proven in step 1.

Out of scope for v1: touch-key triggers, HUD (the device has no display),
firmware upgrade, capture import, the SDK's built-in AI voice conversation
classes, the livestream's AAC audio track.

## Background constraints (from `FINDINGS.md`, SDK 1.6.4)

These are device behaviours the design must encode, not tune around:

| # | Observation | Consequence |
|---|---|---|
| F1 | Mic open across a `snapshot()` → 2/12 success, then the device **wedges** (`DeviceFailure.failure(code: 4)` in ~130 ms forever; only a power cycle clears it) | Mic and camera are never open together. Close mic ≥ 400 ms before a shot, settle 300 ms. |
| F2 | Livestream teardown takes 1–7 s, non-deterministic; stills right after it time out | Await `stop()` + hotspot release, then a 1 s settle before the next still. |
| F3 | Camera stays in low-res mode after a livestream | Accepted as a quality regression; no workaround exists in the API. |
| F4 | Transfer watchdog is 6 s **between packets**, not total | Do not impose a total timeout shorter than the SDK's own. |
| F6 | `AVAudioSession` deactivate/activate around a capture → 47 % success | Never toggle the audio session around a capture. |
| — | `stopCaptureTransfer()` must always be called after `snapshot()`, even on failure (SDK docs) | `defer`. |
| — | Audio stream targets are removed by the SDK at every stream start/end; re-add in `onAudioStreamStartedHandler` (SDK docs) | `AiSeeMicrophone` re-attaches on every start. |

## Part A — sample app: `aisee-glass-sample`

Location: `~/Documents/GitHub/aisee-glass-sample/` (own git repo).

```
AiSeeGlassSample.xcodeproj         SwiftUI, iOS 17.0, iphoneos only, Swift 5
AiSeeGlassSample/
  App/
    AiSeeGlassSampleApp.swift
    ContentView.swift              connect card · battery · Take Photo + thumbnail
                                   · Live Preview toggle · Mic toggle + level meter
                                   · scrolling log pane
    SampleModel.swift              @Observable glue between UI and the kit
  AiSeeGlassKit/                   ← copied verbatim into Hermes (Part B)
    AiSeeConnectionService.swift
    AiSeePhotoCapture.swift
    AiSeeLiveStream.swift
    AiSeeH264Decoder.swift         VideoToolbox H.264 → CVPixelBuffer, no SDK import
    AiSeeMicrophone.swift
    AiSeeDeviceCoordinator.swift
    AiSeeSequencing.swift          pure logic, no SDK import
    AiSeeTypes.swift               AiSeeError, AiSeeFrame, AiSeeConnectionState
  Info.plist
Vendor/RTK/
  RTKAIDeviceConnection.framework  RTKAudioConnectSDK.framework
  RTKAudioStreaming.framework      RTKLEFoundation.framework
  OpenAIRealtimeAccess.framework   (transitive dependency of RTKAIDeviceConnection)
  libavcodec/libavformat/libavutil/libswresample.framework + module.modulemap
Tests/                             swiftc-run unit tests for AiSeeSequencing and PCM conversion
```

Not used: `RTKUIiOS.framework` (vendor discovery UI), storyboards, the demo's
`PhotoLibraryStore`/`TonePlayer`.

Info.plist keys: `NSBluetoothAlwaysUsageDescription`,
`NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`,
`UIBackgroundModes = [bluetooth-central, audio]`.

Project generation: `project.yml` + xcodegen if installed; otherwise a
hand-written pbxproj. Either way the file is committed.

### AiSeeGlassKit — component contracts

All SDK-touching files are wrapped in `#if canImport(RTKAIDeviceConnection)`.
`AiSeeSequencing.swift` and `AiSeeTypes.swift` import Foundation only.

**`AiSeeTypes`**
```swift
enum AiSeeConnectionState: Equatable { case disconnected, scanning, connecting, connected(name: String) }
struct AiSeeFrame { let image: UIImage?; let pixelBuffer: CVPixelBuffer? }   // mirrors Hermes VisionFrame
enum AiSeeError: LocalizedError {
    case notConnected, captureInProgress, streamUnavailable
    case deviceWedged            // DeviceFailure.failure(code: 4) — "Restart your glasses"
    case sdk(Error)              // anything else, wrapped
}
```

**`AiSeeConnectionService`** (`@MainActor`, `@Observable`)
- Owns one `RTKProfileConnectionManager` (delegate = self), registers
  `IntelligenceDeviceConnection` for GATT peripherals.
- `startScan()` / `stopScan()` → `discovered: [DiscoveredDevice(id, name, rssi)]`.
- `connect(_ id)` → `activate()` → `basicRoutine?.budInfo()` → `battery: Int?`;
  `state` transitions as above.
- `disconnect()`.
- Remembers the last connected peripheral identifier in `UserDefaults`
  (`aisee_last_peripheral`) and auto-reconnects on launch if it advertises.
- Exposes `connection: IntelligenceDeviceConnection?` to the other kit files
  (never to the UI).

**`AiSeeSequencing`** (pure)
```swift
enum AiSeeSequencing {
    struct State { var micOpen: Bool; var streaming: Bool; var lastStreamStop: Date? }
    enum Step: Equatable { case closeMic, wait(ms: Int), shoot, reopenMic, serveLatestFrame }
    static let micCloseLeadMs = 400, micSettleMs = 300, postStreamSettleMs = 1000
    static func stillPhotoPlan(state: State, now: Date) -> [Step]
}
```
Rules:
1. `streaming` → `[serveLatestFrame]`.
2. `micOpen` → `[closeMic, wait(400), wait(300), shoot, reopenMic]`.
3. `lastStreamStop` less than 1000 ms ago → prepend `wait(remaining)`.
4. otherwise `[shoot]`.

**`AiSeeDeviceCoordinator`** (actor) — the only caller of the SDK's
start/stop entry points.
- `capturePhoto() async throws -> Data`: asks `AiSeeSequencing` for a plan and
  executes it. Serialized: a second call waits for the first. Maps
  `DeviceFailure.failure(code: 4)` to `.deviceWedged`.
- `startMicrophone(onBuffer:)` / `stopMicrophone()`.
- `startLiveStream(onFrame:onError:)` / `stopLiveStream()`; the latter awaits
  the SDK `stop()` and records `lastStreamStop`.
- Tracks `micOpen`, `streaming`, `latestFrame`.

**`AiSeePhotoCapture`**
- `snapshot(quality: 5, pictureSize: (960, 640), playingTone: false)` →
  `getPictureData` → `defer { stopCaptureTransfer() }` (awaited, not fire-and-forget).
- Retries only `DeviceFailure.failure(code: 5)` (EMMC busy), up to 3 times with
  300 ms backoff. Nothing else is retried (see FINDINGS on re-shooting into a
  recovering glass).
- Logs `✅ shoot Nms + transfer Nms (N bytes)` / `❌ <phase> FAILED after Nms: <error>`
  in the FINDINGS format via an `onLog: (String) -> Void` hook.

**`AiSeeLiveStream`**
- Wraps `LiveCaptureStream(accessoryConnection:)`, `start(via: .wifi, sampleReceivers: [self])`.
- Implements `LiveStreamSampleReceiving`. Samples arrive as **H.264**
  `CMSampleBuffer`s (verified against the demo), so the kit decodes them with a
  hardware `VTDecompressionSession` (`AiSeeH264Decoder.swift`, adapted from the
  demo's `CMSampleBufferToPixelBufferAdapter`: latest-frame-wins, session
  recreated on `-12903/-12911/-12990` after a background excursion). The SDK's
  `LiveStreamVideoDecoder` is not used — it caps at 2 fps and yields `CGImage`,
  too slow for YOLO. Each decoded `CVPixelBuffer` → `AiSeeFrame` (`UIImage` via
  CIImage).
- `stop()` awaits SDK `stop()`; termination callback surfaces as `onError`.

**`AiSeeMicrophone`**
- `startInputAudioStream(mode: .default)`; on `onAudioStreamStartedHandler`
  attaches a `PCMResampler(audioFrom: connection.outDataFormat, resampleTo: 16 kHz mono Int16)`
  whose downstream is an `AudioStreamInputable` adapter that packs bytes into
  `AVAudioPCMBuffer` (Int16, 16 kHz, mono) and calls `onBuffer`.
- `stop()` → `stopInputAudioStream()`.
- Also reports a peak level (0…1) for the sample app's meter.

### Sample UI behaviour

- Connect card: scan list with RSSI; tapping connects. Shows name, battery,
  state dot.
- Take Photo: runs `coordinator.capturePhoto()`; shows thumbnail + bytes + timing.
  Disabled while disconnected.
- Live Preview toggle: shows frames in an `Image`; while on, Take Photo serves
  the latest frame (and says so in the log).
- Mic toggle: level meter; log shows buffers/sec and format.
- Log pane: every kit `onLog` line, newest at bottom, copyable.

## Part B — Hermes integration

### Files added
```
HermesGlasses/Services/AiSee/            AiSeeGlassKit files, verbatim
HermesGlasses/Services/AiSee/AiSeeCameraSource.swift   VisionSource adapter
Vendor/RTK/                              same frameworks as the sample
```

### Build settings (HermesGlasses target)
- `FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*] = $(SRCROOT)/Vendor/RTK`
- Frameworks in "Link Binary" and "Embed Frameworks" phases;
  `EXCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*] = *.framework` so the
  simulator build neither links nor embeds them.
- `OTHER_LDFLAGS` unchanged. Swift code gated by `#if canImport(RTKAIDeviceConnection)`;
  a stub `AiSeeConnectionService` (always `.disconnected`) compiles on the simulator.

### Settings — Devices page
- New "Glasses" picker: **Meta Ray-Ban** / **AiSee**. `UserDefaults` key
  `glasses_vendor`, values `meta` (default) / `aisee`.
- When AiSee is selected the page shows: scan/connect controls, device name,
  battery, state dot, and capability chips **Camera ✓ · Audio ✓ · No display**.
  The Meta registration row and the "Glasses camera permission" row are hidden.
- The "Glasses Display" settings page is shown only for Meta.

### `HermesSessionViewModel`
- `glassesVendor: GlassesVendor` (read from defaults, observable).
- `glassesAvailable` becomes:
  `vendor == .meta ? deviceSelector.activeDevice != nil : aisee.state.isConnected`.
- `vision` returns `AiSeeCameraSource` on the glasses route when vendor is AiSee.
- The glasses-route session start skips `createSession` and the display attach
  for AiSee; `isGlassesConnected` reflects the AiSee state.
- `requestGlassesCameraAccess()` is a no-op for AiSee (no permission step).

### `VisionSource.swift`
```swift
final class AiSeeCameraSource: VisionSource {
    var sourceLabel: String { "AiSee camera" }
    // isStreaming / startLiveStream / stopLiveStream / capturePhoto forward to AiSeeDeviceCoordinator
}
```
`VisionRouting` is unchanged: `.glasses` resolves to whichever vendor is selected.

### `HermesAudioManager`
- `MicSource` gains `.aiseeGlasses` (label "AiSee glasses"). Selectable only
  when vendor is AiSee and connected; otherwise the picker falls back to iPhone
  with the existing notice mechanism.
- On `.aiseeGlasses`, `startCapture` does not build the `AVAudioEngine` input
  tap; it calls `coordinator.startMicrophone { buffer in recognizer.append(buffer) }`.
  `stopCapture` calls `stopMicrophone()`. The audio session stays configured
  exactly as today (playback still needs it) and is never deactivated around a
  capture (F6).
- The recognizer's suspend/resume around TTS playback is unchanged; the
  glasses mic stream is left open during playback (only the recognizer is
  paused), because reopening it costs a stream start and re-attach.
- When a visual query fires while the AiSee mic is open, the coordinator's
  plan closes and reopens the mic around the shot; the audio manager observes
  `coordinator.micOpen` to keep its own state honest.

### `CLAUDE.md` additions
A "AiSee glasses" block listing: device-only frameworks and the simulator gate;
mic/camera exclusion and the wedge; `stopCaptureTransfer` always; livestream
settle; where `glasses_vendor` lives.

## Error handling

| Situation | Behaviour |
|---|---|
| Not connected when a feature needs the glasses | `AiSeeError.notConnected`; Hermes falls back to the phone per `PhoneModePreference` exactly as for unreachable Ray-Bans |
| `deviceWedged` | Surfaced as "AiSee camera stopped responding — restart your glasses". Hermes marks the AiSee route ineligible until the next reconnect |
| BLE drop mid-session | `state → .disconnected`; coordinator resets `micOpen`/`streaming`; auto-reconnect attempts on advertisement |
| Livestream terminates with error | `onError` → Lens view shows the existing error banner; `lastStreamStop` recorded |
| Transfer timeout (`BTFoundation` 101) | Not retried; error propagates with the phase name |

## Testing

**Unit (swiftc, no Xcode, matching `DwellTracker`/`VisionRouting` convention)**
- `AiSeeSequencing.stillPhotoPlan` for all four rule combinations, including the
  post-stream remaining-wait arithmetic.
- The PCM adapter: a synthetic 100-sample Int16 buffer round-trips to an
  `AVAudioPCMBuffer` with the right frame count and format.

**On device — sample app**
- Scenario A (control): 1 foreground + 8 background captures, all succeed.
- Scenario D-equivalent: mic on, 10 captures — all succeed (the coordinator
  applies the 400/300 ms close automatically).
- Livestream 3 s → stop → capture: succeeds after the settle.
- Mic meter moves; buffers arrive at 16 kHz mono.

**On device — Hermes**
- Builds for iphoneos and iphonesimulator.
- With vendor = AiSee: "what am I looking at?" answers from an AiSee photo; the
  Lens screen shows the live feed and YOLO boxes; the voice loop transcribes
  from the AiSee mic; a visual query mid-conversation closes/reopens the mic
  without a wedge across 10 repetitions.
- With vendor = Meta: no behaviour change (regression pass of the existing
  photo test, Lens, voice loop).
