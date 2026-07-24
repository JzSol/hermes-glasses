//
// DwellTracker.swift
//
// Pure dwell logic for the Lens (Object Snap) view: decides which detected
// object sits under the center reticle and fires a snap event after the
// reticle has stayed on the same object for `dwellDuration`. Identity
// across frames is same label + IoU >= `iouThreshold` (boxes jitter frame
// to frame). After a snap the object is in cooldown - it cannot re-snap
// until the reticle leaves it.
//
// Deliberately UIKit- and Vision-free (CoreGraphics + Foundation only) so
// tests/dwell can compile it with plain swiftc.
//

import Foundation
import CoreGraphics

/// One detected object in a frame. `rect` is normalized [0,1] with
/// TOP-LEFT origin - Vision's bottom-left boxes are converted before
/// they get here.
struct Detection: Equatable {
    let label: String
    let confidence: Float
    let rect: CGRect
}

/// A finished look: a snapped gaze segment that has now ended. `duration`
/// runs from when the gaze first landed on the object until it left.
struct CompletedLook: Equatable {
    let label: String
    let duration: TimeInterval
}

struct DwellUpdate: Equatable {
    /// 0...1 fraction of the dwell completed for the current target.
    let progress: Double
    /// The box currently under the reticle, nil if none.
    let target: Detection?
    /// Non-nil exactly once per completed dwell: crop this object now.
    let snap: Detection?
    /// Non-nil exactly once when a snapped look ends: the object left the
    /// reticle (or a different object took over). Carries its total duration.
    let completedLook: CompletedLook?
}

final class DwellTracker {
    private var dwellDuration: TimeInterval
    private let iouThreshold: Double
    private let reticle = CGPoint(x: 0.5, y: 0.5)

    private var currentTarget: Detection?
    private var dwellStart: TimeInterval?
    private var inCooldown = false
    private var currentSnapped = false

    init(dwellDuration: TimeInterval = 2.0, iouThreshold: Double = 0.3) {
        self.dwellDuration = dwellDuration
        self.iouThreshold = iouThreshold
    }

    /// Change the dwell threshold live. Takes effect immediately: the
    /// in-progress dwell's `progress` and snap point both use the new value.
    func setDwellDuration(_ seconds: TimeInterval) {
        dwellDuration = seconds
    }

    func update(detections: [Detection], at time: TimeInterval) -> DwellUpdate {
        // Candidate = box containing the reticle whose center is nearest it.
        let candidate = detections
            .filter { $0.rect.contains(reticle) }
            .min { distanceToReticle($0) < distanceToReticle($1) }

        guard let candidate else {
            let ended = finishSegment(at: time)
            return DwellUpdate(progress: 0, target: nil, snap: nil, completedLook: ended)
        }

        let sameObject = currentTarget.map {
            $0.label == candidate.label && iou($0.rect, candidate.rect) >= iouThreshold
        } ?? false

        guard sameObject else {
            let ended = finishSegment(at: time)
            currentTarget = candidate
            dwellStart = time
            inCooldown = false
            currentSnapped = false
            return DwellUpdate(
                progress: 0, target: candidate, snap: nil, completedLook: ended
            )
        }

        // Follow the box as it drifts so IoU is judged frame-to-frame,
        // not against where the object was 2 s ago.
        currentTarget = candidate

        if inCooldown {
            return DwellUpdate(progress: 1, target: candidate, snap: nil, completedLook: nil)
        }

        let elapsed = time - (dwellStart ?? time)
        if elapsed >= dwellDuration {
            inCooldown = true
            currentSnapped = true
            return DwellUpdate(
                progress: 1, target: candidate, snap: candidate, completedLook: nil
            )
        }
        return DwellUpdate(
            progress: elapsed / dwellDuration, target: candidate,
            snap: nil, completedLook: nil
        )
    }

    /// End the current gaze segment and reset. Returns a CompletedLook only
    /// if the segment had already snapped (a real "look").
    private func finishSegment(at time: TimeInterval) -> CompletedLook? {
        var ended: CompletedLook? = nil
        if currentSnapped, let target = currentTarget, let start = dwellStart {
            ended = CompletedLook(label: target.label, duration: time - start)
        }
        currentTarget = nil
        dwellStart = nil
        inCooldown = false
        currentSnapped = false
        return ended
    }

    /// Called on session stop: emit the in-progress look if it had snapped,
    /// then reset. Pass the same clock used for `update` (CACurrentMediaTime).
    func flush(at time: TimeInterval) -> CompletedLook? {
        finishSegment(at: time)
    }

    // MARK: - Geometry

    private func distanceToReticle(_ d: Detection) -> CGFloat {
        let c = CGPoint(x: d.rect.midX, y: d.rect.midY)
        return hypot(c.x - reticle.x, c.y - reticle.y)
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return Double(interArea / unionArea)
    }
}
