import SwiftUI
import MetalKit

/// An MTKView that forwards raw touches to the renderer. UIKit rather than a
/// SwiftUI gesture because we want every touch, multi-finger, with no
/// recognizer delay in front of it.
final class TouchMetalView: MTKView {

    var renderer: WaterRenderer?
    private var lastDragPoint: [Int: CGPoint] = [:]

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        isMultipleTouchEnabled = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let p = touch.location(in: self)
            renderer?.addSplat(at: p, in: bounds.size,
                               radius: Tuning.tapRadius,
                               amplitude: Tuning.tapAmplitude)
            lastDragPoint[touch.hash] = p
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let p = touch.location(in: self)
            let last = lastDragPoint[touch.hash] ?? p
            let dx = p.x - last.x, dy = p.y - last.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance >= Tuning.dragSpacing else { continue }

            // Lay splats along the segment so a fast flick still draws a wake
            // rather than a dotted line.
            let steps = min(Int(distance / Tuning.dragSpacing), 8)
            for i in 1...max(steps, 1) {
                let t = CGFloat(i) / CGFloat(max(steps, 1))
                let q = CGPoint(x: last.x + dx * t, y: last.y + dy * t)
                renderer?.addSplat(at: q, in: bounds.size,
                                   radius: Tuning.dragRadius,
                                   amplitude: Tuning.dragAmplitude)
            }
            lastDragPoint[touch.hash] = p
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { lastDragPoint.removeValue(forKey: touch.hash) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { lastDragPoint.removeValue(forKey: touch.hash) }
    }
}

struct WaterView: UIViewRepresentable {

    final class Coordinator {
        var renderer: WaterRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TouchMetalView {
        let device = MTLCreateSystemDefaultDevice()
        let view = TouchMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        if let renderer = WaterRenderer(view: view) {
            view.delegate = renderer
            view.renderer = renderer
            context.coordinator.renderer = renderer
            renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
            if DemoScript.isEnabled { DemoScript.run(on: view, renderer: renderer) }
        }
        return view
    }

    func updateUIView(_ uiView: TouchMetalView, context: Context) {}
}
