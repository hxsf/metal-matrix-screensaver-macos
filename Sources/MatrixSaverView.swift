import AppKit
import CoreGraphics
import Darwin
import MetalKit
import ScreenSaver

@objc(MetalMatrixView)
public final class MetalMatrixView: ScreenSaverView {
    private var metalView: MTKView?
    private var renderer: MatrixRenderer?
    private let settingsController = MatrixSettingsWindowController()
    private let fpsLabel = NSTextField(labelWithString: "")
    private let debugLabel = NSTextField(labelWithString: "")
    private var fpsWidthConstraint: NSLayoutConstraint?
    private var fpsHeightConstraint: NSLayoutConstraint?
    private var debugWidthConstraint: NSLayoutConstraint?
    private var debugHeightConstraint: NSLayoutConstraint?
    private var currentSettings = MatrixSettings.load()
    private var renderingSuspended = true
    private var systemIsAsleep = false
    private var lastFPSUpdate = CACurrentMediaTime()
    private var frameCounter = 0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0
        wantsLayer = true
        installPowerObservers()
        setupMetalView()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0
        wantsLayer = true
        installPowerObservers()
        setupMetalView()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    public override var hasConfigureSheet: Bool {
        true
    }

    public override var configureSheet: NSWindow? {
        settingsController.window
    }

    public override func startAnimation() {
        super.startAnimation()
        applySettings(force: true)
        renderer?.resume(size: bounds.size)
        renderingSuspended = shouldSuspendForCurrentDisplay()
        lastFPSUpdate = CACurrentMediaTime()
        frameCounter = 0
        metalView?.isPaused = renderingSuspended
    }

    public override func stopAnimation() {
        renderingSuspended = true
        DebugDisplayRegistry.shared.mark(displayID: currentDisplayID, active: false, fps: nil)
        metalView?.isPaused = true
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        renderingSuspended = shouldSuspendForCurrentDisplay()
        if renderingSuspended {
            DebugDisplayRegistry.shared.mark(displayID: currentDisplayID, active: false, fps: nil)
            metalView?.isPaused = true
        } else {
            renderer?.resume(size: bounds.size)
            metalView?.isPaused = false
        }
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
        view.preferredFramesPerSecond = max(1, currentSettings.frameRate)

        do {
            let renderer = try MatrixRenderer(view: view, isPreview: isPreview)
            renderer.frameRendered = { [weak self] now in
                DispatchQueue.main.async {
                    self?.updateOverlays(now: now)
                }
            }
            view.delegate = renderer
            addSubview(view)
            self.metalView = view
            setupFPSLabel()
            setupDebugLabel()
            self.renderer = renderer
        } catch {
            NSLog("MetalMatrix: failed to initialize renderer: \(error)")
        }
    }

    private func installPowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self,
                           selector: #selector(displayStateChanged(_:)),
                           name: NSWorkspace.screensDidSleepNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(displayStateChanged(_:)),
                           name: NSWorkspace.screensDidWakeNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(systemWillSleep(_:)),
                           name: NSWorkspace.willSleepNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(systemDidWake(_:)),
                           name: NSWorkspace.didWakeNotification,
                           object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(displayStateChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsDidChange(_:)),
                                               name: MatrixSettings.didChangeNotification,
                                               object: nil)
    }

    @objc private func displayStateChanged(_ notification: Notification) {
        renderingSuspended = shouldSuspendForCurrentDisplay()
        if renderingSuspended {
            DebugDisplayRegistry.shared.mark(displayID: currentDisplayID, active: false, fps: nil)
            metalView?.isPaused = true
        } else {
            renderer?.resume(size: bounds.size)
            metalView?.isPaused = false
        }
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        systemIsAsleep = true
        renderingSuspended = true
        metalView?.isPaused = true
    }

    @objc private func systemDidWake(_ notification: Notification) {
        systemIsAsleep = false
        displayStateChanged(notification)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        applySettings(force: true)
        displayStateChanged(notification)
    }

    private func shouldSuspendForCurrentDisplay() -> Bool {
        guard currentSettings.pauseWhenDisplaysSleep else {
            return systemIsAsleep
        }
        if systemIsAsleep { return true }
        if let window, !window.isVisible { return true }
        guard let screen = window?.screen else { return false }
        return screen.isDisplayAsleep
    }

    private func setupFPSLabel() {
        fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: isPreview ? 10 : 13, weight: .medium)
        fpsLabel.textColor = NSColor(calibratedRed: 0.72, green: 1, blue: 0.64, alpha: 0.9)
        fpsLabel.drawsBackground = false
        fpsLabel.isBezeled = false
        fpsLabel.isEditable = false
        fpsLabel.isSelectable = false
        fpsLabel.alignment = .right
        fpsLabel.lineBreakMode = .byWordWrapping
        fpsLabel.maximumNumberOfLines = 0
        fpsLabel.cell?.wraps = true
        fpsLabel.cell?.usesSingleLineMode = false
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        addOverlaySubview(fpsLabel)
        let width = fpsLabel.widthAnchor.constraint(equalToConstant: 100)
        let height = fpsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)
        fpsWidthConstraint = width
        fpsHeightConstraint = height
        NSLayoutConstraint.activate([
            fpsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            fpsLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            width,
            height
        ])
    }

    private func setupDebugLabel() {
        debugLabel.font = NSFont.monospacedSystemFont(ofSize: isPreview ? 9 : 12, weight: .medium)
        debugLabel.textColor = NSColor(calibratedRed: 0.72, green: 1, blue: 0.64, alpha: 0.9)
        debugLabel.drawsBackground = true
        debugLabel.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        debugLabel.isBezeled = false
        debugLabel.isEditable = false
        debugLabel.isSelectable = false
        debugLabel.alignment = .left
        debugLabel.lineBreakMode = .byWordWrapping
        debugLabel.maximumNumberOfLines = 0
        debugLabel.cell?.wraps = true
        debugLabel.cell?.usesSingleLineMode = false
        debugLabel.stringValue = "MetalMatrix debug\ninitializing"
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        addOverlaySubview(debugLabel)
        let width = debugLabel.widthAnchor.constraint(equalToConstant: isPreview ? 260 : 430)
        let height = debugLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: isPreview ? 80 : 110)
        debugWidthConstraint = width
        debugHeightConstraint = height
        NSLayoutConstraint.activate([
            debugLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            debugLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            width,
            height
        ])
        debugLabel.isHidden = true
    }

    private func addOverlaySubview(_ view: NSView) {
        if let metalView {
            addSubview(view, positioned: .above, relativeTo: metalView)
        } else {
            addSubview(view)
        }
    }

    private func applySettings(force: Bool = false) {
        let settings = MatrixSettings.load()
        let changed = settings != currentSettings
        guard force || changed else { return }
        currentSettings = settings
        let frameRate = max(1, settings.frameRate)
        animationTimeInterval = 1.0
        metalView?.preferredFramesPerSecond = frameRate
        renderer?.apply(settings: settings)
        if changed || force {
            configureOverlayLabel(for: settings)
        }
        fpsLabel.isHidden = !(settings.showFPS || settings.showDebugInfo)
        debugLabel.isHidden = true
        if settings.showDebugInfo && !fpsLabel.stringValue.hasPrefix("MetalMatrix debug") {
            updateDebugLabel(now: CACurrentMediaTime())
        }
    }

    private func configureOverlayLabel(for settings: MatrixSettings) {
        if settings.showDebugInfo {
            fpsLabel.font = NSFont.monospacedSystemFont(ofSize: isPreview ? 9 : 12, weight: .medium)
            fpsLabel.alignment = .left
            fpsLabel.drawsBackground = true
            fpsLabel.backgroundColor = NSColor.black.withAlphaComponent(0.5)
            fpsWidthConstraint?.constant = isPreview ? 260 : 430
            fpsHeightConstraint?.constant = isPreview ? 86 : 118
        } else {
            fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: isPreview ? 10 : 13, weight: .medium)
            fpsLabel.alignment = .right
            fpsLabel.drawsBackground = false
            fpsWidthConstraint?.constant = 100
            fpsHeightConstraint?.constant = 18
        }
    }

    private func updateOverlays(now: CFTimeInterval) {
        frameCounter += 1
        let elapsed = now - lastFPSUpdate
        guard elapsed >= 0.4 else { return }
        let fps = Double(frameCounter) / elapsed
        DebugDisplayRegistry.shared.mark(displayID: currentDisplayID, active: true, fps: fps)
        if currentSettings.showDebugInfo {
            updateDebugLabel(now: now)
        } else if !fpsLabel.isHidden {
            fpsLabel.stringValue = String(format: "FPS %.1f / %d", fps, currentSettings.frameRate)
        }
        frameCounter = 0
        lastFPSUpdate = now
    }

    private func updateDebugLabel(now: CFTimeInterval) {
        let text = DebugOverlay.snapshot(currentDisplayID: currentDisplayID,
                                         device: metalView?.device,
                                         targetFrameRate: currentSettings.frameRate)
        fpsLabel.stringValue = text
        fpsLabel.invalidateIntrinsicContentSize()
        debugLabel.stringValue = text
        debugLabel.invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private var currentDisplayID: CGDirectDisplayID? {
        window?.screen?.displayID
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    var isDisplayAsleep: Bool {
        guard let displayID else {
            return false
        }
        return CGDisplayIsAsleep(displayID) != 0
    }
}

private final class DebugDisplayRegistry {
    static let shared = DebugDisplayRegistry()

    private struct Entry {
        var active: Bool
        var fps: Double?
        var updatedAt: CFTimeInterval
    }

    private var entries: [CGDirectDisplayID: Entry] = [:]
    private let lock = NSLock()

    func mark(displayID: CGDirectDisplayID?, active: Bool, fps: Double?) {
        guard let displayID else { return }
        lock.lock()
        entries[displayID] = Entry(active: active, fps: fps, updatedAt: CACurrentMediaTime())
        lock.unlock()
    }

    func lines(currentDisplayID: CGDirectDisplayID?) -> [String] {
        let screens = NSScreen.screens
        let now = CACurrentMediaTime()

        lock.lock()
        let snapshot = entries
        lock.unlock()

        return screens.enumerated().map { index, screen in
            guard let displayID = screen.displayID else {
                return "D\(index + 1) unknown off"
            }
            let marker = displayID == currentDisplayID ? "*" : " "
            let state: String
            if screen.isDisplayAsleep {
                state = "off"
            } else if let entry = snapshot[displayID],
                      entry.active,
                      now - entry.updatedAt < 2,
                      let fps = entry.fps {
                state = String(format: "%.1f fps", fps)
            } else {
                state = "off"
            }
            return "\(marker)D\(index + 1) \(displayID): \(state)"
        }
    }
}

private enum DebugOverlay {
    static func snapshot(currentDisplayID: CGDirectDisplayID?, device: MTLDevice?, targetFrameRate: Int) -> String {
        let process = ProcessMetricsSampler.shared.sample()
        var lines = ["MetalMatrix debug  target \(targetFrameRate) fps"]
        lines.append(contentsOf: DebugDisplayRegistry.shared.lines(currentDisplayID: currentDisplayID))
        lines.append(String(format: "CPU %.1f%%  MEM %@", process.cpuPercent, formatBytes(process.residentBytes)))
        let gmem = device.map { formatBytes(UInt64($0.currentAllocatedSize)) } ?? "n/a"
        lines.append("GPU global n/a  GMEM self \(gmem)")
        return lines.joined(separator: "\n")
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1_048_576
        if mib < 1024 {
            return String(format: "%.1f MiB", mib)
        }
        return String(format: "%.2f GiB", mib / 1024)
    }
}

private final class ProcessMetricsSampler {
    static let shared = ProcessMetricsSampler()

    private var lastCPUSeconds: Double?
    private var lastSampleTime: CFTimeInterval?
    private let lock = NSLock()

    func sample() -> (cpuPercent: Double, residentBytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        let cpuSeconds = currentCPUSeconds()
        let cpuPercent: Double
        if let lastCPUSeconds, let lastSampleTime {
            let elapsed = max(now - lastSampleTime, 0.001)
            cpuPercent = max(0, (cpuSeconds - lastCPUSeconds) / elapsed * 100)
        } else {
            cpuPercent = 0
        }
        lastCPUSeconds = cpuSeconds
        lastSampleTime = now

        return (cpuPercent, currentResidentBytes())
    }

    private func currentCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }

    private func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
