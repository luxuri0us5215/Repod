import Foundation

/// Touch-independent wheel math. UIKit's downward-positive Y axis makes
/// increasing atan2 angles clockwise, so a positive result means move down.
struct WheelRotationTracker {
    private var previousAngle: Double?
    private var previousTime: TimeInterval?
    private var accumulatedDegrees = 0.0
    private var smoothedSpeed = 0.0
    private var direction = 0

    mutating func reset() {
        previousAngle = nil
        previousTime = nil
        accumulatedDegrees = 0
        smoothedSpeed = 0
        direction = 0
    }

    /// Returns signed discrete steps; callers send feedback once per accepted
    /// step. The first sample establishes a baseline and never moves selection.
    mutating func update(angle: Double, timestamp: TimeInterval) -> Int {
        guard angle.isFinite, timestamp.isFinite else {
            reset()
            return 0
        }
        guard let oldAngle = previousAngle, let oldTime = previousTime else {
            previousAngle = angle
            previousTime = timestamp
            return 0
        }

        previousAngle = angle
        previousTime = timestamp
        let elapsed = timestamp - oldTime
        // A suspended/cancelled gesture must not turn its next sample into a jump.
        guard elapsed > 0, elapsed <= 0.25 else {
            accumulatedDegrees = 0
            smoothedSpeed = 0
            direction = 0
            return 0
        }

        var delta = angle - oldAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let degrees = delta * 180 / .pi
        guard abs(degrees) > 0.02 else {
            smoothedSpeed *= exp(-elapsed / 0.06)
            return 0
        }

        let nextDirection = degrees > 0 ? 1 : -1
        if nextDirection != direction {
            // Reversing should respond immediately, without paying off the
            // remainder accumulated while travelling the other way.
            accumulatedDegrees = 0
            smoothedSpeed = 0
            direction = nextDirection
        }

        let instantaneousSpeed = abs(degrees) / max(elapsed, 1.0 / 240.0)
        let smoothing = 1 - exp(-elapsed / 0.06)
        smoothedSpeed += smoothing * (instantaneousSpeed - smoothedSpeed)
        let threshold: Double
        if smoothedSpeed >= 360 {
            threshold = 15
        } else if smoothedSpeed >= 180 {
            threshold = 20
        } else {
            threshold = 30
        }

        accumulatedDegrees += degrees
        let count = Int((abs(accumulatedDegrees) + 1e-9) / threshold)
        accumulatedDegrees -= Double(count * direction) * threshold
        return count * direction
    }
}
