//
// PersonLookupGate.swift
//
// The pure heart of the Lookup app: given each frame's person boxes and a
// clock, decide when someone is CLOSE (tall box), FACED (centered in the
// wearer's view) and has STAYED there long enough to snap. Foundation +
// CoreGraphics only, tested standalone in tests/lookup/.
//
// The gate deliberately knows nothing about faces or badges - those checks
// need Vision and run outside it. It fires once, then waits: the caller
// reports back with `fired(at:)` (snap accepted - long cooldown, so the
// same person is not looked up twice in a row) or `rejected(at:)` (not
// facing us / no badge - short cooldown, then try again).
//
// Boxes are normalized [0,1] with top-left origin, the app-wide convention
// (see ObjectDetector).
//

import Foundation
import CoreGraphics

struct PersonLookupGate {
    struct Config {
        /// A person closer than conversational range fills most of the
        /// frame's height on the glasses stream; below this they are "too
        /// far away" to be who the wearer is talking to.
        var minHeight: CGFloat = 0.4
        /// How far the box's center may sit from the frame's center line.
        /// The wearer faces someone by looking at them.
        var maxCenterOffset: CGFloat = 0.28
        /// How long the person must hold before the gate fires.
        var holdSeconds: TimeInterval = 1.5
        /// Detector dropouts shorter than this keep the hold alive - YOLO
        /// misses frames without the person having gone anywhere.
        var lapseSeconds: TimeInterval = 0.6
        /// After a successful snap: long, so one person isn't re-fired.
        var firedCooldownSeconds: TimeInterval = 8.0
        /// After a rejection (not facing, no badge): short retry window.
        var rejectedCooldownSeconds: TimeInterval = 2.0
        /// Minimum overlap with the previous frame's box to count as the
        /// same person continuing their hold.
        var minIoU: CGFloat = 0.3

        init() {}
    }

    struct Update: Equatable {
        /// The box currently being held on, nil when nobody qualifies.
        let target: CGRect?
        /// 0...1 fraction of the hold completed.
        let progress: Double
        /// Non-nil exactly once per completed hold: snap this person now.
        let fire: CGRect?
    }

    private let config: Config
    private var holdStart: TimeInterval?
    private var lastRect: CGRect?
    private var lastSeen: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0
    /// Fired, but the caller has not said fired()/rejected() yet - never
    /// fire twice for one snap.
    private var awaitingVerdict = false

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func update(personBoxes: [CGRect], at now: TimeInterval) -> Update {
        if awaitingVerdict {
            return Update(target: lastRect, progress: 1, fire: nil)
        }
        if now < cooldownUntil {
            return Update(target: nil, progress: 0, fire: nil)
        }

        // Largest qualifying box: of the people close and centered enough,
        // the biggest is the nearest.
        let candidate = personBoxes
            .filter {
                $0.height >= config.minHeight
                    && abs($0.midX - 0.5) <= config.maxCenterOffset
            }
            .max { $0.width * $0.height < $1.width * $1.height }

        guard let candidate else {
            guard let start = holdStart,
                  now - lastSeen <= config.lapseSeconds else {
                resetTracking()
                return Update(target: nil, progress: 0, fire: nil)
            }
            // A dropped detection frame, not a departed person: freeze the
            // clock where it last saw them instead of crediting unseen time.
            let frozen = min((lastSeen - start) / config.holdSeconds, 1)
            return Update(target: lastRect, progress: frozen, fire: nil)
        }

        // Same person continuing, or a new hold from zero.
        if let previous = lastRect,
           Self.iou(previous, candidate) >= config.minIoU {
            // continue the running hold
        } else {
            holdStart = now
        }
        lastRect = candidate
        lastSeen = now

        let start = holdStart ?? now
        let elapsed = now - start
        let progress = min(elapsed / config.holdSeconds, 1)
        // The epsilon absorbs float error in the caller's timestamps: a
        // hold of exactly holdSeconds must fire.
        if elapsed >= config.holdSeconds - 1e-9 {
            awaitingVerdict = true
            return Update(target: candidate, progress: 1, fire: candidate)
        }
        return Update(target: candidate, progress: progress, fire: nil)
    }

    /// The snap was accepted (face + badge landed): long cooldown.
    mutating func fired(at now: TimeInterval) {
        awaitingVerdict = false
        cooldownUntil = now + config.firedCooldownSeconds
        resetTracking()
    }

    /// The snap was rejected (not facing us, unreadable badge): brief
    /// cooldown, then the hold restarts.
    mutating func rejected(at now: TimeInterval) {
        awaitingVerdict = false
        cooldownUntil = now + config.rejectedCooldownSeconds
        resetTracking()
    }

    private mutating func resetTracking() {
        holdStart = nil
        lastRect = nil
    }

    /// Intersection-over-union of two rects; 0 for disjoint or degenerate.
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }
}
