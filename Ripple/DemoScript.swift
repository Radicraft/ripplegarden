import UIKit

/// Launch with `-demo` to fire a fixed sequence. Lets the look be checked in
/// the Simulator, where there is no finger to tap with, and gives a repeatable
/// frame to compare against after a tuning change.
enum DemoScript {

    private enum Beat {
        /// A quick tap at a fraction of the view.
        case tap(TimeInterval, CGFloat, CGFloat)
        /// Finger down, held for a duration, then lifted.
        case hold(TimeInterval, CGFloat, CGFloat, TimeInterval)
    }

    private static let beats: [Beat] = [
        // Head-on collision: two taps at the same instant, close enough that
        // their fronts meet in the middle while still strong.
        .tap(0.20, 0.24, 0.30),
        .tap(0.20, 0.76, 0.30),

        // A lone ring for comparison, so the collision has something to beat.
        .tap(1.60, 0.50, 0.62),

        // Into the corner, for the double reflection.
        .tap(2.60, 0.14, 0.86),

        // A long press: the bowl deepens and widens, then rebounds as a swell.
        .hold(4.00, 0.50, 0.45, 1.20),

        // Two more collisions across the fresh swell.
        .tap(6.40, 0.22, 0.55),
        .tap(6.40, 0.78, 0.55),
    ]

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    static func run(on view: UIView, renderer: WaterRenderer) {
        var syntheticID = 9000

        for beat in beats {
            switch beat {
            case let .tap(delay, fx, fy):
                schedule(delay, view) { size in
                    renderer.addSplat(at: point(fx, fy, size), in: size,
                                      radius: Tuning.tapRadius,
                                      amplitude: Tuning.tapAmplitude)
                }

            case let .hold(delay, fx, fy, duration):
                syntheticID += 1
                let id = syntheticID
                schedule(delay, view) { size in
                    renderer.touchDown(id: id, at: point(fx, fy, size), in: size, weight: 0.5)
                }
                schedule(delay + duration, view) { _ in
                    renderer.touchUp(id: id)
                }
            }
        }
    }

    private static func point(_ fx: CGFloat, _ fy: CGFloat, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * fx, y: size.height * fy)
    }

    private static func schedule(_ delay: TimeInterval, _ view: UIView,
                                 _ body: @escaping (CGSize) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
            guard let view, view.bounds.width > 0 else { return }
            body(view.bounds.size)
        }
    }
}
