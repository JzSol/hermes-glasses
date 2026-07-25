//
// Bearing.swift
//
// Which way the destination is, given which way you're facing.
//
// The glasses expose no compass, so heading comes from the phone's
// magnetometer (CLLocationManager.startUpdatingHeading). This file turns
// that heading plus two coordinates into something a HUD can say out loud.
//
// Foundation only - no CoreLocation - so it unit-tests standalone with
// swiftc, like NavigationFormat and DwellTracker.
//

import Foundation

enum Bearing {
    /// Initial great-circle bearing from one point to another, in degrees
    /// clockwise from true north, normalised to 0..<360.
    ///
    /// "Initial" matters: over any distance the bearing you must hold
    /// changes, and this is the one to set off on.
    static func initial(from: MapCoordinate, to: MapCoordinate) -> Double {
        let lat1 = from.lat * .pi / 180
        let lat2 = to.lat * .pi / 180
        let deltaLon = (to.lon - from.lon) * .pi / 180

        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return normalized360(degrees)
    }

    /// Where a bearing sits relative to the way you are facing:
    /// 0 = straight ahead, positive = to the right, negative = to the left,
    /// 180 = directly behind. Always in (-180, 180].
    ///
    /// Naive subtraction breaks across north (a target at 10° while facing
    /// 350° is 20° to the right, not 340° to the left), so the result is
    /// folded back into range.
    static func relative(bearing: Double, heading: Double) -> Double {
        var delta = normalized360(bearing - heading)
        if delta > 180 { delta -= 360 }
        return delta
    }

    /// Coarse direction, for a HUD line or a spoken cue.
    enum Direction: Equatable {
        case ahead
        case slightRight
        case right
        case slightLeft
        case left
        case behind

        var label: String {
            switch self {
            case .ahead: return "ahead"
            case .slightRight: return "slightly right"
            case .right: return "to your right"
            case .slightLeft: return "slightly left"
            case .left: return "to your left"
            case .behind: return "behind you"
            }
        }

        /// SF Symbol for the arrow on the lens.
        var systemImage: String {
            switch self {
            case .ahead: return "arrow.up"
            case .slightRight: return "arrow.up.right"
            case .right: return "arrow.right"
            case .slightLeft: return "arrow.up.left"
            case .left: return "arrow.left"
            case .behind: return "arrow.uturn.down"
            }
        }
    }

    /// Buckets chosen so "ahead" is wide enough to be stable while walking -
    /// a narrow cone flickers between ahead and slight-left with every step.
    static func direction(relative: Double) -> Direction {
        let d = relative
        switch abs(d) {
        case ..<25:
            return .ahead
        case ..<70:
            return d > 0 ? .slightRight : .slightLeft
        case ..<135:
            return d > 0 ? .right : .left
        default:
            return .behind
        }
    }

    private static func normalized360(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}
