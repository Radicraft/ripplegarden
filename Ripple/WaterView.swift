import SwiftUI
import MetalKit
import UIKit

/// An MTKView that forwards raw touches to the renderer. UIKit rather than a
/// SwiftUI gesture because we want every touch, multi-finger, with no
/// recognizer delay in front of it.
final class TouchMetalView: MTKView {

    var renderer: WaterRenderer?

    private let tapHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let releaseHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        isMultipleTouchEnabled = true
        tapHaptic.prepare()
        releaseHaptic.prepare()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// `majorRadius` is the contact patch, not force. 3D Touch is gone on
    /// current hardware, so this is the only press signal a finger still gives
    /// us, and it is noisy enough to be seasoning rather than a control.
    private func weight(of touch: UITouch) -> Float {
        WaterRenderer.weight(forMajorRadius: touch.majorRadius)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let w = weight(of: touch)
            renderer?.touchDown(id: touch.hash,
                                at: touch.location(in: self),
                                in: bounds.size,
                                weight: w)
            tapHaptic.impactOccurred(intensity: CGFloat(0.45 + 0.55 * w))
        }
        tapHaptic.prepare()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            renderer?.touchMoved(id: touch.hash, to: touch.location(in: self), in: bounds.size)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { renderer?.touchUp(id: touch.hash) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { renderer?.touchUp(id: touch.hash) }
    }

    func chargedRelease(_ charge: Float) {
        releaseHaptic.impactOccurred(intensity: CGFloat(0.4 + 0.6 * charge))
        releaseHaptic.prepare()
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
            renderer.onChargedRelease = { [weak view] charge in
                view?.chargedRelease(charge)
            }
            renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
            if DemoScript.isEnabled { DemoScript.run(on: view, renderer: renderer) }
        }
        return view
    }

    func updateUIView(_ uiView: TouchMetalView, context: Context) {}
}
