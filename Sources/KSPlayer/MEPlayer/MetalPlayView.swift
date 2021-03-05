//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import CoreMedia
import MetalKit

final class MetalPlayView: MTKView, FrameOutput {
    private let render = MetalRender()
    var options: KSOptions
    weak var renderSource: OutputRenderSourceDelegate?
    private var pixelBuffer: BufferProtocol? {
        didSet {
            if let pixelBuffer = pixelBuffer {
                autoreleasepool {
                    let size = options.drawableSize(par: pixelBuffer.size, sar: pixelBuffer.sar)
                    if drawableSize != size {
                        drawableSize = size
                    }
                    colorPixelFormat = KSOptions.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
                    #if targetEnvironment(simulator)
                    if #available(iOS 13.0, tvOS 13.0, *) {
                        (layer as? CAMetalLayer)?.colorspace = pixelBuffer.colorspace
                    }
                    #else
                    (layer as? CAMetalLayer)?.colorspace = pixelBuffer.colorspace
                    #endif
                    #if os(macOS) || targetEnvironment(macCatalyst)
                    (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
                    #endif
                    guard let drawable = currentDrawable else {
                        return
                    }
                    render.draw(pixelBuffer: pixelBuffer, display: options.display, drawable: drawable)
                }
            }
        }
    }

    init(options: KSOptions) {
        self.options = options
        super.init(frame: .zero, device: MetalRender.device)
        framebufferOnly = true
        preferredFramesPerSecond = KSPlayerManager.preferredFramesPerSecond
        isPaused = true
    }

    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: CGRect) {
        if let frame = renderSource?.getOutputRender(type: .video) as? VideoVTBFrame, let corePixelBuffer = frame.corePixelBuffer {
            renderSource?.setVideo(time: frame.cmtime)
            pixelBuffer = corePixelBuffer
        }
    }

    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    override func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if options.display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            options.display.touchesMoved(touch: touches.first!)
        }
    }
    #endif
    func toImage() -> UIImage? {
        pixelBuffer?.image().flatMap { UIImage(cgImage: $0) }
    }
}
