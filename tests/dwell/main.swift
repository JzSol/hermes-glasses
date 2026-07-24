//
// Standalone tests for DwellTracker. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Lens/DwellTracker.swift \
//     tests/dwell/main.swift -o /tmp/dwell-tests && /tmp/dwell-tests
//
import Foundation
import CoreGraphics

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectClose(_ got: Double, _ want: Double, _ label: String) {
    expect(abs(got - want) < 0.01, "\(label) (got \(got), want \(want))")
}

func det(_ label: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
         conf: Float = 0.9) -> Detection {
    Detection(label: label, confidence: conf,
              rect: CGRect(x: x, y: y, width: w, height: h))
}

// A box covering the center of the frame
let cup = det("cup", x: 0.35, y: 0.35, w: 0.3, h: 0.3)
// Same cup, jittered a little (IoU with `cup` well above 0.3)
let cupJittered = det("cup", x: 0.37, y: 0.34, w: 0.3, h: 0.3)
// A box nowhere near the center
let offCenter = det("book", x: 0.0, y: 0.0, w: 0.2, h: 0.2)

// 1. No detections -> no progress, no target
var t = DwellTracker()
var u = t.update(detections: [], at: 0)
expect(u.progress == 0 && u.target == nil && u.snap == nil, "empty frame")

// 2. Off-center boxes are ignored
u = t.update(detections: [offCenter], at: 0.1)
expect(u.target == nil, "off-center box ignored")

// 3. Dwell accumulates on a centered box and fires at 2 s
t = DwellTracker()
u = t.update(detections: [cup], at: 10.0)
expectClose(u.progress, 0, "dwell starts at 0")
expect(u.target?.label == "cup", "target acquired")
u = t.update(detections: [cup], at: 11.0)
expectClose(u.progress, 0.5, "dwell halfway at 1 s")
expect(u.snap == nil, "no snap before 2 s")
u = t.update(detections: [cup], at: 12.0)
expect(u.snap?.label == "cup", "snap fires at 2 s")
expectClose(u.progress, 1.0, "progress full at snap")

// 4. Cooldown: same object never re-snaps while it stays under the reticle
u = t.update(detections: [cup], at: 13.0)
expect(u.snap == nil, "no re-snap during cooldown")
expectClose(u.progress, 1.0, "progress stays full during cooldown")

// 5. Cooldown clears when the reticle leaves; dwell restarts fresh
u = t.update(detections: [offCenter], at: 14.0)
expect(u.target == nil, "target lost when centered box gone")
u = t.update(detections: [cup], at: 15.0)
expectClose(u.progress, 0, "dwell restarts after leaving")
u = t.update(detections: [cup], at: 17.0)
expect(u.snap != nil, "second snap after re-dwell")

// 6. Jitter tolerance: a shifted same-label box continues the dwell
t = DwellTracker()
_ = t.update(detections: [cup], at: 20.0)
u = t.update(detections: [cupJittered], at: 21.0)
expectClose(u.progress, 0.5, "jittered box continues dwell")

// 7. A different label under the reticle resets the dwell
t = DwellTracker()
_ = t.update(detections: [cup], at: 30.0)
let bowl = det("bowl", x: 0.3, y: 0.3, w: 0.4, h: 0.4)
u = t.update(detections: [bowl], at: 31.0)
expectClose(u.progress, 0, "label change resets dwell")
expect(u.target?.label == "bowl", "new target adopted")

// 8. Nearest box-center wins when several boxes contain the reticle
t = DwellTracker()
let tight = det("cup", x: 0.42, y: 0.40, w: 0.18, h: 0.22)  // center (0.51, 0.51)
let tvOff = det("tv", x: 0.0, y: 0.0, w: 0.95, h: 0.95)     // center (0.475, 0.475)
u = t.update(detections: [tvOff, tight], at: 40.0)
expect(u.target?.label == "cup", "nearest-center box wins")

// 9. Tracker follows the box as it drifts (target rect updates)
t = DwellTracker()
_ = t.update(detections: [cup], at: 50.0)
u = t.update(detections: [cupJittered], at: 50.5)
expect(u.target?.rect == cupJittered.rect, "target follows drifting box")

// 10. A snapped look reports its full duration when the reticle leaves
t = DwellTracker()
_ = t.update(detections: [cup], at: 100.0)   // acquire
u = t.update(detections: [cup], at: 102.0)   // snap at 2 s
expect(u.snap != nil, "snap fires (look 10)")
u = t.update(detections: [cup], at: 103.5)   // still looking, in cooldown
expect(u.completedLook == nil, "no completed look while still looking")
u = t.update(detections: [], at: 104.0)      // look away
expect(u.completedLook?.label == "cup", "completed look reports label")
expectClose(u.completedLook?.duration ?? 0, 4.0, "duration is landing-to-leave")

// 11. A glance shorter than the snap threshold reports no completed look
t = DwellTracker()
_ = t.update(detections: [cup], at: 200.0)
u = t.update(detections: [cup], at: 201.0)   // 1 s, never snapped
u = t.update(detections: [], at: 201.2)      // look away
expect(u.completedLook == nil, "sub-threshold glance is not a look")

// 12. Two separate looks at the same label each report a completed look
t = DwellTracker()
_ = t.update(detections: [cup], at: 300.0)
_ = t.update(detections: [cup], at: 302.0)   // snap 1
u = t.update(detections: [], at: 303.0)      // leave -> look 1 (3.0 s)
expectClose(u.completedLook?.duration ?? 0, 3.0, "first look duration")
_ = t.update(detections: [cup], at: 310.0)   // re-acquire
_ = t.update(detections: [cup], at: 312.0)   // snap 2
u = t.update(detections: [], at: 312.5)      // leave -> look 2 (2.5 s)
expectClose(u.completedLook?.duration ?? 0, 2.5, "second look duration")

// 13. flush reports the in-progress look only if it had snapped
t = DwellTracker()
_ = t.update(detections: [cup], at: 400.0)
_ = t.update(detections: [cup], at: 402.0)   // snap, still looking
let flushed = t.flush(at: 403.0)
expectClose(flushed?.duration ?? 0, 3.0, "flush captures in-progress snapped look")
t = DwellTracker()
_ = t.update(detections: [cup], at: 500.0)   // acquired, never snapped
expect(t.flush(at: 500.5) == nil, "flush of un-snapped segment is nil")

// 14. A different label under the reticle ends the previous snapped look
t = DwellTracker()
_ = t.update(detections: [cup], at: 600.0)
_ = t.update(detections: [cup], at: 602.0)   // snap cup
let bowl2 = det("bowl", x: 0.3, y: 0.3, w: 0.4, h: 0.4)
u = t.update(detections: [bowl2], at: 603.0) // switch target
expect(u.completedLook?.label == "cup", "target switch ends previous look")
expectClose(u.completedLook?.duration ?? 0, 3.0, "switch look duration")

// 15. setDwellDuration moves the snap threshold live
t = DwellTracker()
t.setDwellDuration(1.0)
_ = t.update(detections: [cup], at: 700.0)
u = t.update(detections: [cup], at: 700.5)   // 0.5 s, below the new 1.0 s
expect(u.snap == nil, "no snap before shortened threshold")
u = t.update(detections: [cup], at: 701.0)   // 1.0 s
expect(u.snap != nil, "snap fires at shortened threshold")

// 16. A shorter duration reaches full progress sooner
t = DwellTracker()
t.setDwellDuration(0.5)
_ = t.update(detections: [cup], at: 800.0)
u = t.update(detections: [cup], at: 800.25)  // half of 0.5 s
expectClose(u.progress, 0.5, "progress scales to the new duration")

// 17. A longer duration delays the snap past the old 2 s default
t = DwellTracker()
t.setDwellDuration(3.0)
_ = t.update(detections: [cup], at: 900.0)
u = t.update(detections: [cup], at: 902.0)   // 2 s, below the new 3.0 s
expect(u.snap == nil, "no snap at 2 s when threshold is 3 s")
u = t.update(detections: [cup], at: 903.0)   // 3.0 s
expect(u.snap != nil, "snap fires at 3 s threshold")

if failures > 0 { print("\n\(failures) FAILURES"); exit(1) }
print("\nAll dwell tests passed")
