import SwiftUI
import MetalKit
import UIKit

/// Where raw touches go. The game decides what a touch means (tap, hold,
/// swell, edge current, koi poke) and forwards the water-shaped part of it to
/// the renderer.
protocol TouchInput: AnyObject {
    func touchBegan(id: Int, at point: CGPoint, in size: CGSize, weight: Float)
    func touchMoved(id: Int, to point: CGPoint, in size: CGSize)
    func touchEnded(id: Int, at point: CGPoint, in size: CGSize)
}

/// An MTKView that forwards raw touches. UIKit rather than a SwiftUI gesture
/// because we want every touch, multi-finger, with no recognizer delay in
/// front of it.
final class TouchMetalView: MTKView {

    weak var input: TouchInput?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        isMultipleTouchEnabled = true
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
            input?.touchBegan(id: touch.hash, at: touch.location(in: self),
                              in: bounds.size, weight: weight(of: touch))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            input?.touchMoved(id: touch.hash, to: touch.location(in: self), in: bounds.size)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            input?.touchEnded(id: touch.hash, at: touch.location(in: self), in: bounds.size)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            input?.touchEnded(id: touch.hash, at: touch.location(in: self), in: bounds.size)
        }
    }
}

struct WaterView: UIViewRepresentable {

    let controller: GameController

    final class Coordinator {
        var renderer: WaterRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TouchMetalView {
        let device = MTLCreateSystemDefaultDevice()
        let view = TouchMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        // The solid bodies on the water sort against each other, so the
        // drawable pass carries depth. Everything else ignores it.
        view.depthStencilPixelFormat = .depth32Float
        view.framebufferOnly = true
        view.isOpaque = true
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.input = controller

        if let renderer = WaterRenderer(view: view) {
            view.delegate = renderer
            context.coordinator.renderer = renderer
            controller.attach(renderer: renderer)
            renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        }
        return view
    }

    func updateUIView(_ uiView: TouchMetalView, context: Context) {}
}
