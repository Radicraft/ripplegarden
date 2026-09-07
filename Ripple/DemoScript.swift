import UIKit

/// Launch with `-demo` to fire a fixed sequence of splats. Lets the look be
/// checked in the Simulator, where there is no finger to tap with, and gives a
/// repeatable frame to compare against after a tuning change.
enum DemoScript {

    /// (delay in seconds, x and y as a fraction of the view, radius, amplitude)
    private static let beats: [(TimeInterval, CGFloat, CGFloat, Float, Float)] = [
        // Two simultaneous taps: their crests meet on the vertical bisector.
        (0.20, 0.28, 0.32, Tuning.tapRadius, Tuning.tapAmplitude),
        (0.20, 0.72, 0.32, Tuning.tapRadius, Tuning.tapAmplitude),
        // A single clean ring, later, lower down.
        (0.75, 0.50, 0.70, Tuning.tapRadius, Tuning.tapAmplitude),
        // Close to the edge, to show the reflection off the wall.
        (1.30, 0.12, 0.86, Tuning.tapRadius, Tuning.tapAmplitude),
        // A rhythm on one spot: each tap adds to the standing pattern left by
        // the last. This is the resonance mechanic, in its crudest form.
        (3.00, 0.50, 0.45, Tuning.tapRadius, Tuning.tapAmplitude),
        (3.55, 0.50, 0.45, Tuning.tapRadius, Tuning.tapAmplitude),
        (4.10, 0.50, 0.45, Tuning.tapRadius, Tuning.tapAmplitude),
        (4.65, 0.50, 0.45, Tuning.tapRadius, Tuning.tapAmplitude),
    ]

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    static func run(on view: UIView, renderer: WaterRenderer) {
        for (delay, fx, fy, radius, amplitude) in beats {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view, view.bounds.width > 0 else { return }
                let p = CGPoint(x: view.bounds.width * fx, y: view.bounds.height * fy)
                renderer.addSplat(at: p, in: view.bounds.size, radius: radius, amplitude: amplitude)
            }
        }
    }
}
