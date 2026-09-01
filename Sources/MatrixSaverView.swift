import AppKit
import CoreGraphics
import Darwin
import MetalKit
import ScreenSaver

@objc(MetalMatrixView)
public final class MetalMatrixView: ScreenSaverView {
    private var metalView: MTKView?
    private var renderer: MatrixRenderer?
    private lazy var settingsController = MatrixSettingsWindowController()
    private let fpsLabel = NSTextField(labelWithString: "")
    private let debugLabel = NSTextField(labelWithString: "")
    private var fpsWidthConstraint: NSLayoutConstraint?
    private var fpsHeightConstraint: NSLayoutConstraint?
    private var debugWidthConstraint: NSLayoutConstraint?
    private var debugHeightConstraint: NSLayoutConstraint?
    private var currentSettings = MatrixSettings.load()
    private var animationActive = false
    private var rendererGeneration: UInt64 = 0
    private var renderingSuspended = true
    private var systemIsAsleep = false
    private var lastFPSUpdate = CACurrentMediaTime()
    private var lastPresentedFrameCount: UInt64 = 0
    private var simulationReadyRequest: UInt64 = 0
    private var waitingForSimulationReady = false

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        DebugLifetimeRegistry.shared.register(view: self)
        animationTimeInterval = 1.0
        wantsLayer = true
        installPowerObservers()
        setupFPSLabel()
        setupDebugLabel()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        DebugLifetimeRegistry.shared.register(view: self)
        animationTimeInterval = 1.0
        wantsLayer = true
        installPowerObservers()
        setupFPSLabel()
        setupDebugLabel()
    }

    deinit {
        DebugLifetimeRegistry.shared.unregister(view: self)
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
        animationActive = true
        DebugLifetimeRegistry.shared.setActive(view: self, active: true)
        applySettings(force: true)
        lastFPSUpdate = CACurrentMediaTime()
        lastPresentedFrameCount = 0
        updateRenderingState()
    }

    public override func stopAnimation() {
        animationActive = false
        DebugLifetimeRegistry.shared.setActive(view: self, active: false)
        updateRenderingState()
        teardownMetalView()
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        updateRenderingState()
        let now = CACurrentMediaTime()
        if currentSettings.showDebugInfo && now - lastFPSUpdate > 0.8 {
            updateDebugLabel(now: now)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalView?.frame = bounds
        renderer?.resize(size: newSize)
        if animationActive {
            updateRenderingState()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard animationActive else { return }

        invalidateSimulationReadyWait()
        metalView?.isPaused = true
        DispatchQueue.main.async { [weak self] in
            self?.updateRenderingState()
        }
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
        view.depthStencilPixelFormat = .invalid
        view.clearColor = MTLClearColor(red: 0.002, green: 0.004, blue: 0.002, alpha: 1.0)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = max(1, currentSettings.frameRate)

        do {
            let renderer = try MatrixRenderer(view: view, isPreview: isPreview)
            rendererGeneration &+= 1
            view.delegate = renderer
            if fpsLabel.superview === self {
                addSubview(view, positioned: .below, relativeTo: fpsLabel)
            } else {
                addSubview(view)
            }
            self.metalView = view
            setupFPSLabel()
            setupDebugLabel()
            self.renderer = renderer
            configurePresentationCallback()
        } catch {
            NSLog("MetalMatrix: failed to initialize renderer: \(error)")
        }
    }

    private func teardownMetalView() {
        guard metalView != nil || renderer != nil else { return }
        invalidateSimulationReadyWait()
        rendererGeneration &+= 1
        metalView?.isPaused = true
        metalView?.delegate = nil
        renderer?.setFramePresentedHandler(minimumInterval: 0, handler: nil)
        renderer?.shutdown()
        metalView?.removeFromSuperview()
        renderer = nil
        metalView = nil
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
        performOnMain { [weak self] in
            self?.updateRenderingState()
        }
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        performOnMain { [weak self] in
            self?.systemIsAsleep = true
            self?.updateRenderingState()
        }
    }

    @objc private func systemDidWake(_ notification: Notification) {
        performOnMain { [weak self] in
            self?.systemIsAsleep = false
            self?.updateRenderingState()
        }
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        performOnMain { [weak self] in
            self?.invalidateSimulationReadyWait()
            self?.metalView?.isPaused = true
            self?.applySettings(force: true)
            self?.updateRenderingState()
        }
    }

    private func performOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    private func updateRenderingState() {
        let hasDrawableSize = bounds.width > 0 && bounds.height > 0
        let isAttachedToWindow = window != nil
        renderingSuspended = !animationActive || !hasDrawableSize || !isAttachedToWindow || shouldSuspendForCurrentDisplay()
        if renderingSuspended {
            invalidateSimulationReadyWait()
            DebugDisplayRegistry.shared.mark(displayID: currentDisplayID, active: false, fps: nil)
            metalView?.isPaused = true
            renderer?.setSimulationActive(false)
            return
        }

        setupMetalView()
        guard metalView != nil, renderer != nil else {
            renderingSuspended = true
            return
        }
        metalView?.frame = bounds
        renderer?.resume(size: bounds.size)
        guard metalView?.isPaused == true,
              let renderer else { return }
        guard !waitingForSimulationReady else { return }
        waitingForSimulationReady = true
        simulationReadyRequest &+= 1
        let readyRequest = simulationReadyRequest
        let generation = rendererGeneration
        renderer.whenSimulationReady { [weak self, weak renderer] in
            DispatchQueue.main.async {
                guard let self,
                      self.simulationReadyRequest == readyRequest else { return }
                self.waitingForSimulationReady = false
                guard let renderer,
                      self.animationActive,
                      !self.renderingSuspended,
                      self.rendererGeneration == generation,
                      self.renderer === renderer else { return }
                self.metalView?.isPaused = false
            }
        }
    }

    private func invalidateSimulationReadyWait() {
        guard waitingForSimulationReady else { return }
        waitingForSimulationReady = false
        simulationReadyRequest &+= 1
    }

    private func shouldSuspendForCurrentDisplay() -> Bool {
        guard currentSettings.pauseWhenDisplaysSleep else {
            return systemIsAsleep
        }
        if systemIsAsleep { return true }
        guard let screen = window?.screen else { return false }
        return screen.isDisplayAsleep
    }

    private func setupFPSLabel() {
        guard fpsLabel.superview == nil else { return }
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
        guard debugLabel.superview == nil else { return }
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
        configurePresentationCallback()
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
            fpsWidthConstraint?.constant = isPreview ? 330 : 700
            fpsHeightConstraint?.constant = isPreview ? 210 : 270
        } else {
            fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: isPreview ? 10 : 13, weight: .medium)
            fpsLabel.alignment = .right
            fpsLabel.drawsBackground = false
            fpsWidthConstraint?.constant = 100
            fpsHeightConstraint?.constant = 18
        }
    }

    private func updateOverlays(now: CFTimeInterval) {
        let elapsed = now - lastFPSUpdate
        let updateInterval: CFTimeInterval = currentSettings.showDebugInfo ? 1.0 : 0.4
        guard elapsed >= updateInterval else { return }
        let presentedFrames = renderer?.diagnosticsSnapshot().presentedFrames ?? lastPresentedFrameCount
        let frameDelta = presentedFrames >= lastPresentedFrameCount
            ? presentedFrames - lastPresentedFrameCount
            : 0
        let fps = Double(frameDelta) / elapsed
        DebugDisplayRegistry.shared.mark(displayID: currentDisplayID, active: true, fps: fps)
        if currentSettings.showDebugInfo {
            updateDebugLabel(now: now)
        } else if !fpsLabel.isHidden {
            fpsLabel.stringValue = String(format: "FPS %.1f / %d", fps, currentSettings.frameRate)
        }
        lastPresentedFrameCount = presentedFrames
        lastFPSUpdate = now
    }

    private func configurePresentationCallback() {
        guard let renderer else { return }
        guard currentSettings.showFPS || currentSettings.showDebugInfo else {
            renderer.setFramePresentedHandler(minimumInterval: 0, handler: nil)
            return
        }

        lastPresentedFrameCount = renderer.diagnosticsSnapshot().presentedFrames
        lastFPSUpdate = CACurrentMediaTime()
        let generation = rendererGeneration
        let interval: CFTimeInterval = currentSettings.showDebugInfo ? 1.0 : 0.4
        renderer.setFramePresentedHandler(minimumInterval: interval) { [weak self, weak renderer] now in
            DispatchQueue.main.async {
                guard let self,
                      let renderer,
                      self.animationActive,
                      self.rendererGeneration == generation,
                      self.renderer === renderer else { return }
                self.updateOverlays(now: now)
            }
        }
    }

    private func updateDebugLabel(now: CFTimeInterval) {
        let device = metalView?.device
        let preferredDevice = metalView?.preferredDevice
        let viewSnapshot = DebugViewSnapshot(
            identifier: String(format: "%08X", UInt32(truncatingIfNeeded: ObjectIdentifier(self).hashValue)),
            viewSize: bounds.size,
            drawableSize: metalView?.drawableSize ?? .zero,
            backingScale: window?.backingScaleFactor ?? 0,
            animationActive: animationActive,
            renderingSuspended: renderingSuspended,
            paused: metalView?.isPaused ?? true,
            attached: window != nil,
            visible: window?.isVisible ?? false,
            occluded: window?.occlusionState.contains(.visible) ?? false,
            screenName: window?.screen?.localizedName ?? "n/a",
            deviceName: device?.name ?? "n/a",
            deviceRegistryID: device?.registryID,
            preferredDeviceRegistryID: preferredDevice?.registryID
        )
        let text = DebugOverlay.snapshot(currentDisplayID: currentDisplayID,
                                         device: device,
                                         targetFrameRate: currentSettings.frameRate,
                                         view: viewSnapshot,
                                         renderer: renderer?.diagnosticsSnapshot(),
                                         now: now)
        fpsLabel.stringValue = text
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

struct DebugLifetimeSnapshot {
    var views: Int
    var activeViews: Int
    var renderers: Int
}

final class DebugLifetimeRegistry {
    static let shared = DebugLifetimeRegistry()

    private var views: Set<ObjectIdentifier> = []
    private var activeViews: Set<ObjectIdentifier> = []
    private var renderers: Set<ObjectIdentifier> = []
    private let lock = NSLock()

    func register(view: MetalMatrixView) {
        lock.lock()
        views.insert(ObjectIdentifier(view))
        lock.unlock()
    }

    func unregister(view: MetalMatrixView) {
        let identifier = ObjectIdentifier(view)
        lock.lock()
        views.remove(identifier)
        activeViews.remove(identifier)
        lock.unlock()
    }

    func setActive(view: MetalMatrixView, active: Bool) {
        let identifier = ObjectIdentifier(view)
        lock.lock()
        if active {
            activeViews.insert(identifier)
        } else {
            activeViews.remove(identifier)
        }
        lock.unlock()
    }

    func register(renderer: MatrixRenderer) {
        lock.lock()
        renderers.insert(ObjectIdentifier(renderer))
        lock.unlock()
    }

    func unregister(renderer: MatrixRenderer) {
        lock.lock()
        renderers.remove(ObjectIdentifier(renderer))
        lock.unlock()
    }

    func snapshot() -> DebugLifetimeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DebugLifetimeSnapshot(views: views.count,
                                     activeViews: activeViews.count,
                                     renderers: renderers.count)
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

private struct DebugViewSnapshot {
    var identifier: String
    var viewSize: CGSize
    var drawableSize: CGSize
    var backingScale: CGFloat
    var animationActive: Bool
    var renderingSuspended: Bool
    var paused: Bool
    var attached: Bool
    var visible: Bool
    var occluded: Bool
    var screenName: String
    var deviceName: String
    var deviceRegistryID: UInt64?
    var preferredDeviceRegistryID: UInt64?
}

private enum DebugOverlay {
    private static let version = versionString()

    static func snapshot(currentDisplayID: CGDirectDisplayID?,
                         device: MTLDevice?,
                         targetFrameRate: Int,
                         view: DebugViewSnapshot,
                         renderer: MatrixRendererDiagnostics?,
                         now: CFTimeInterval) -> String {
        let process = ProcessMetricsSampler.shared.sample()
        let lifetime = DebugLifetimeRegistry.shared.snapshot()
        var lines = ["MetalMatrix \(version) debug  target \(targetFrameRate) fps  view \(view.identifier)"]
        lines.append(contentsOf: DebugDisplayRegistry.shared.lines(currentDisplayID: currentDisplayID))
        lines.append("state active \(flag(view.animationActive)) suspended \(flag(view.renderingSuspended)) paused \(flag(view.paused)) win(a/v/o) \(flag(view.attached))/\(flag(view.visible))/\(flag(view.occluded))")
        lines.append("objects views \(lifetime.views) active \(lifetime.activeViews) renderers \(lifetime.renderers)")
        lines.append(String(format: "size %.0fx%.0f drawable %.0fx%.0f scale %.1f  %@",
                            view.viewSize.width, view.viewSize.height,
                            view.drawableSize.width, view.drawableSize.height,
                            view.backingScale, view.screenName))
        if let renderer {
            lines.append("render inst \(renderer.instanceCount)/\(renderer.instanceCapacity) strips \(renderer.stripCount) submit \(renderer.submittedFrames) slot \(renderer.frameSlot)/\(renderer.simulationSlot) seq \(renderer.simulationSequence)")
            lines.append("metal done \(renderer.completedFrames) present \(renderer.presentedFrames) drop \(renderer.skippedPresentations) err \(renderer.commandErrors)")
            lines.append("miss(d/c/e/r) \(renderer.drawableMisses)/\(renderer.commandBufferMisses)/\(renderer.encoderMisses)/\(renderer.resourceMisses)")
            lines.append("inflight \(renderer.inFlightFrames)/3 peak \(renderer.peakInFlightFrames) skip \(renderer.inFlightSkips)")
            let simulation = renderer.simulation
            lines.append("cpuq ready \(simulation.readyFrames)/\(simulation.ringCapacity) prep \(simulation.preparingFrames) readers \(simulation.gpuReaders) displays \(simulation.activeConsumers) rings \(simulation.liveCoordinators) qos utility")
            lines.append(String(format: "cpuq made %llu take %llu stale %llu starve %llu prep %.3f/%.3f ms",
                                simulation.producedFrames, simulation.consumedFrames,
                                simulation.staleFrames, simulation.starvedFrames,
                                simulation.lastPreparationMilliseconds,
                                simulation.averagePreparationMilliseconds))
            let presentAge = renderer.lastPresentedTime > 0 ? max(0, now - renderer.lastPresentedTime) : -1
            lines.append(String(format: "GPU frame %.3f ms  present age %.3f s", renderer.gpuMilliseconds, presentAge))
            if let error = renderer.lastError {
                lines.append("Metal error: \(error)")
            }
        } else {
            lines.append("renderer unavailable")
        }
        lines.append("device \(view.deviceName) id \(hexID(view.deviceRegistryID)) pref \(hexID(view.preferredDeviceRegistryID))")
        let allCorePercent = process.cpuPercent / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        lines.append(String(format: "CPU %.1f%% (1c=100) all %.1f%%  MEM %@",
                            process.cpuPercent, allCorePercent, formatBytes(process.residentBytes)))
        let gmem = device.map { formatBytes(UInt64($0.currentAllocatedSize)) } ?? "n/a"
        lines.append("GPU global n/a  GMEM self \(gmem)")
        return lines.joined(separator: "\n")
    }

    private static func flag(_ value: Bool) -> Int {
        value ? 1 : 0
    }

    private static func versionString() -> String {
        let bundle = Bundle(identifier: "com.hxsf.MetalMatrix") ?? Bundle(for: MetalMatrixView.self)
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build:
            return "v\(short) (\(build))"
        case let (short?, _):
            return "v\(short)"
        case let (_, build?):
            return "v\(build)"
        default:
            return "unknown"
        }
    }

    private static func hexID(_ value: UInt64?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%llX", value)
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
    private var cachedMetrics: (cpuPercent: Double, residentBytes: UInt64) = (0, 0)
    private let minimumSampleInterval: CFTimeInterval = 0.75
    private let lock = NSLock()

    func sample() -> (cpuPercent: Double, residentBytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        if let lastSampleTime, now - lastSampleTime < minimumSampleInterval {
            return cachedMetrics
        }

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
        cachedMetrics = (cpuPercent, currentResidentBytes())
        return cachedMetrics
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
