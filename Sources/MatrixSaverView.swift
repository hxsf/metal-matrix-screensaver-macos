import AppKit
import MetalKit
import ScreenSaver

@objc(MetalMatrixView)
public final class MetalMatrixView: ScreenSaverView {
    private var metalView: MTKView?
    private var renderer: MatrixRenderer?
    private let settingsController = MatrixSettingsWindowController()
    private let fpsLabel = NSTextField(labelWithString: "")
    private var lastFPSUpdate = CACurrentMediaTime()
    private var frameCounter = 0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        setupMetalView()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        setupMetalView()
    }

    public override var hasConfigureSheet: Bool {
        true
    }

    public override var configureSheet: NSWindow? {
        settingsController.window
    }

    public override func startAnimation() {
        super.startAnimation()
        applySettings()
        renderer?.resume(size: bounds.size)
        metalView?.isPaused = false
    }

    public override func stopAnimation() {
        metalView?.isPaused = true
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        applySettings()
        metalView?.draw()
        updateFPSLabel()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalView?.frame = bounds
        renderer?.resize(size: newSize)
    }

    private func setupMetalView() {
        guard metalView == nil else { return }

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("MetalMatrix: Metal is not available on this Mac")
            return
        }

        let view = MTKView(frame: bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.002, green: 0.004, blue: 0.002, alpha: 1.0)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = 60

        do {
            let renderer = try MatrixRenderer(view: view, isPreview: isPreview)
            view.delegate = renderer
            addSubview(view)
            setupFPSLabel()
            self.renderer = renderer
            self.metalView = view
        } catch {
            NSLog("MetalMatrix: failed to initialize renderer: \(error)")
        }
    }

    private func setupFPSLabel() {
        fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: isPreview ? 10 : 13, weight: .medium)
        fpsLabel.textColor = NSColor(calibratedRed: 0.72, green: 1, blue: 0.64, alpha: 0.9)
        fpsLabel.drawsBackground = false
        fpsLabel.isBezeled = false
        fpsLabel.isEditable = false
        fpsLabel.isSelectable = false
        fpsLabel.alignment = .right
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fpsLabel)
        NSLayoutConstraint.activate([
            fpsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            fpsLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        ])
    }

    private func applySettings() {
        let settings = MatrixSettings.load()
        renderer?.apply(settings: settings)
        fpsLabel.isHidden = !settings.showFPS
    }

    private func updateFPSLabel() {
        guard !fpsLabel.isHidden else { return }
        frameCounter += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFPSUpdate
        guard elapsed >= 0.4 else { return }
        let fps = Double(frameCounter) / elapsed
        fpsLabel.stringValue = String(format: "FPS %.1f", fps)
        frameCounter = 0
        lastFPSUpdate = now
    }
}
