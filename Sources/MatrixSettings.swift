import AppKit
import ScreenSaver

private func MMString(_ key: String) -> String {
    let bundle = Bundle(identifier: "com.hxsf.MetalMatrix") ?? Bundle(for: MatrixSettingsWindowController.self)
    let languages = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]) ?? Locale.preferredLanguages
    let language = languages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    guard let path = bundle.path(forResource: language, ofType: "lproj"),
          let localizedBundle = Bundle(path: path) else {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    return localizedBundle.localizedString(forKey: key, value: key, table: nil)
}

public enum MatrixMode: Int, CaseIterable {
    case matrix = 0
    case binary = 1
    case hexadecimal = 2
    case dna = 3

    var title: String {
        switch self {
        case .matrix: return MMString("mode.matrix")
        case .binary: return MMString("mode.binary")
        case .hexadecimal: return MMString("mode.hexadecimal")
        case .dna: return MMString("mode.dna")
        }
    }
}

public struct MatrixSettings: Equatable {
    static let moduleName = "com.hxsf.MetalMatrix"
    static let didChangeNotification = Notification.Name("MetalMatrixSettingsDidChange")
    private static let currentSettingsVersion = 6

    var density: Float
    var speed: Float
    var mode: MatrixMode
    var fog: Bool
    var waves: Bool
    var rotate: Bool
    var showFPS: Bool
    var showDebugInfo: Bool
    var frameRate: Int
    var pauseWhenDisplaysSleep: Bool

    static let standard = MatrixSettings(
        density: 50,
        speed: 1,
        mode: .matrix,
        fog: true,
        waves: true,
        rotate: true,
        showFPS: false,
        showDebugInfo: false,
        frameRate: 30,
        pauseWhenDisplaysSleep: true
    )

    static var defaults: ScreenSaverDefaults {
        let defaults = ScreenSaverDefaults(forModuleWithName: moduleName)!
        defaults.register(defaults: [
            Keys.density: NSNumber(value: standard.density),
            Keys.speed: NSNumber(value: standard.speed),
            Keys.mode: NSNumber(value: standard.mode.rawValue),
            Keys.fog: NSNumber(value: standard.fog),
            Keys.waves: NSNumber(value: standard.waves),
            Keys.rotate: NSNumber(value: standard.rotate),
            Keys.showFPS: NSNumber(value: standard.showFPS),
            Keys.showDebugInfo: NSNumber(value: standard.showDebugInfo),
            Keys.frameRate: NSNumber(value: standard.frameRate),
            Keys.pauseWhenDisplaysSleep: NSNumber(value: standard.pauseWhenDisplaysSleep),
            Keys.settingsVersion: NSNumber(value: 0)
        ])
        return defaults
    }

    static func load() -> MatrixSettings {
        let defaults = MatrixSettings.defaults
        migrateDefaultsIfNeeded(defaults)
        let mode = MatrixMode(rawValue: defaults.integer(forKey: Keys.mode)) ?? .matrix
        return MatrixSettings(
            density: min(max(defaults.float(forKey: Keys.density), 0), 100),
            speed: min(max(defaults.float(forKey: Keys.speed), 0.1), 8),
            mode: mode,
            fog: defaults.bool(forKey: Keys.fog),
            waves: defaults.bool(forKey: Keys.waves),
            rotate: defaults.bool(forKey: Keys.rotate),
            showFPS: defaults.bool(forKey: Keys.showFPS),
            showDebugInfo: defaults.bool(forKey: Keys.showDebugInfo),
            frameRate: nearestFrameRate(defaults.integer(forKey: Keys.frameRate)),
            pauseWhenDisplaysSleep: defaults.bool(forKey: Keys.pauseWhenDisplaysSleep)
        )
    }

    private static func migrateDefaultsIfNeeded(_ defaults: ScreenSaverDefaults) {
        guard defaults.integer(forKey: Keys.settingsVersion) < currentSettingsVersion else { return }
        setDefaultIfMissing(defaults, key: Keys.density, value: standard.density)
        setDefaultIfMissing(defaults, key: Keys.speed, value: standard.speed)
        setDefaultIfMissing(defaults, key: Keys.mode, value: standard.mode.rawValue)
        setDefaultIfMissing(defaults, key: Keys.fog, value: standard.fog)
        setDefaultIfMissing(defaults, key: Keys.waves, value: standard.waves)
        setDefaultIfMissing(defaults, key: Keys.rotate, value: standard.rotate)
        setDefaultIfMissing(defaults, key: Keys.showFPS, value: standard.showFPS)
        setDefaultIfMissing(defaults, key: Keys.showDebugInfo, value: standard.showDebugInfo)
        setDefaultIfMissing(defaults, key: Keys.frameRate, value: standard.frameRate)
        setDefaultIfMissing(defaults, key: Keys.pauseWhenDisplaysSleep, value: standard.pauseWhenDisplaysSleep)
        defaults.set(currentSettingsVersion, forKey: Keys.settingsVersion)
        defaults.synchronize()
    }

    private static func setDefaultIfMissing(_ defaults: ScreenSaverDefaults, key: String, value: Any) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(value, forKey: key)
    }

    static let frameRateOptions = [15, 30, 60]

    static func nearestFrameRate(_ value: Int) -> Int {
        frameRateOptions.min { abs($0 - value) < abs($1 - value) } ?? standard.frameRate
    }

    func save() {
        let defaults = MatrixSettings.defaults
        defaults.set(density, forKey: Keys.density)
        defaults.set(speed, forKey: Keys.speed)
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(fog, forKey: Keys.fog)
        defaults.set(waves, forKey: Keys.waves)
        defaults.set(rotate, forKey: Keys.rotate)
        defaults.set(showFPS, forKey: Keys.showFPS)
        defaults.set(showDebugInfo, forKey: Keys.showDebugInfo)
        defaults.set(MatrixSettings.nearestFrameRate(frameRate), forKey: Keys.frameRate)
        defaults.set(pauseWhenDisplaysSleep, forKey: Keys.pauseWhenDisplaysSleep)
        defaults.set(MatrixSettings.currentSettingsVersion, forKey: Keys.settingsVersion)
        defaults.synchronize()
        NotificationCenter.default.post(name: MatrixSettings.didChangeNotification, object: nil)
    }

    private enum Keys {
        static let density = "density"
        static let speed = "speed"
        static let mode = "mode"
        static let fog = "fog"
        static let waves = "waves"
        static let rotate = "rotate"
        static let showFPS = "showFPS"
        static let showDebugInfo = "showDebugInfo"
        static let frameRate = "frameRate"
        static let pauseWhenDisplaysSleep = "pauseWhenDisplaysSleep"
        static let settingsVersion = "settingsVersion"
    }
}

final class MatrixSettingsWindowController: NSWindowController {
    private let densitySlider = NSSlider(value: Double(MatrixSettings.standard.density), minValue: 0, maxValue: 100, target: nil, action: nil)
    private let speedSlider = NSSlider(value: Double(MatrixSettings.standard.speed), minValue: 0.1, maxValue: 8, target: nil, action: nil)
    private let modePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let frameRatePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fogButton = NSButton(checkboxWithTitle: MMString("option.fog"), target: nil, action: nil)
    private let wavesButton = NSButton(checkboxWithTitle: MMString("option.waves"), target: nil, action: nil)
    private let rotateButton = NSButton(checkboxWithTitle: MMString("option.panning"), target: nil, action: nil)
    private let fpsButton = NSButton(checkboxWithTitle: MMString("option.fps"), target: nil, action: nil)
    private let debugButton = NSButton(checkboxWithTitle: MMString("option.debug"), target: nil, action: nil)
    private let pauseDisplaysButton = NSButton(checkboxWithTitle: MMString("option.pauseDisplays"), target: nil, action: nil)
    private let densityValue = NSTextField(labelWithString: "")
    private let speedValue = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 370),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = MMString("window.title")
        super.init(window: window)
        buildContent()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        MatrixMode.allCases.forEach { modePopUp.addItem(withTitle: $0.title) }
        MatrixSettings.frameRateOptions.forEach { frameRatePopUp.addItem(withTitle: String(format: MMString("value.fps"), $0)) }

        densitySlider.target = self
        densitySlider.action = #selector(sliderChanged(_:))
        speedSlider.target = self
        speedSlider.action = #selector(sliderChanged(_:))

        stack.addArrangedSubview(row(label: MMString("label.density"), control: densitySlider, valueLabel: densityValue))
        stack.addArrangedSubview(row(label: MMString("label.speed"), control: speedSlider, valueLabel: speedValue))
        stack.addArrangedSubview(row(label: MMString("label.encoding"), control: modePopUp, valueLabel: nil))
        stack.addArrangedSubview(row(label: MMString("label.frameRate"), control: frameRatePopUp, valueLabel: nil))

        let checks = NSStackView(views: [fogButton, wavesButton, rotateButton, pauseDisplaysButton, fpsButton, debugButton])
        checks.orientation = .vertical
        checks.spacing = 8
        stack.addArrangedSubview(checks)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        let versionLabel = NSTextField(labelWithString: bundleVersionString())
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        let defaultsButton = NSButton(title: MMString("button.defaults"), target: self, action: #selector(defaultsClicked(_:)))
        let cancelButton = NSButton(title: MMString("button.cancel"), target: self, action: #selector(cancelClicked(_:)))
        let okButton = NSButton(title: MMString("button.ok"), target: self, action: #selector(okClicked(_:)))
        okButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(versionLabel)
        buttons.addArrangedSubview(defaultsButton)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(okButton)
        stack.addArrangedSubview(buttons)
    }

    private func row(label: String, control: NSView, valueLabel: NSTextField?) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 104).isActive = true
        if let valueLabel {
            valueLabel.alignment = .right
            valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(control)
        if let valueLabel {
            row.addArrangedSubview(valueLabel)
        }
        return row
    }

    private func load() {
        apply(MatrixSettings.load())
    }

    private func apply(_ settings: MatrixSettings) {
        densitySlider.doubleValue = Double(settings.density)
        speedSlider.doubleValue = Double(settings.speed)
        modePopUp.selectItem(at: settings.mode.rawValue)
        if let frameRateIndex = MatrixSettings.frameRateOptions.firstIndex(of: MatrixSettings.nearestFrameRate(settings.frameRate)) {
            frameRatePopUp.selectItem(at: frameRateIndex)
        }
        fogButton.state = settings.fog ? .on : .off
        wavesButton.state = settings.waves ? .on : .off
        rotateButton.state = settings.rotate ? .on : .off
        fpsButton.state = settings.showFPS ? .on : .off
        debugButton.state = settings.showDebugInfo ? .on : .off
        pauseDisplaysButton.state = settings.pauseWhenDisplaysSleep ? .on : .off
        updateValueLabels()
    }

    private func currentSettings() -> MatrixSettings {
        MatrixSettings(
            density: Float(densitySlider.doubleValue),
            speed: Float(speedSlider.doubleValue),
            mode: MatrixMode(rawValue: modePopUp.indexOfSelectedItem) ?? .matrix,
            fog: fogButton.state == .on,
            waves: wavesButton.state == .on,
            rotate: rotateButton.state == .on,
            showFPS: fpsButton.state == .on,
            showDebugInfo: debugButton.state == .on,
            frameRate: MatrixSettings.frameRateOptions[max(0, min(MatrixSettings.frameRateOptions.count - 1, frameRatePopUp.indexOfSelectedItem))],
            pauseWhenDisplaysSleep: pauseDisplaysButton.state == .on
        )
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        updateValueLabels()
    }

    @objc private func defaultsClicked(_ sender: NSButton) {
        apply(.standard)
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        load()
        endSheet(returnCode: .cancel)
    }

    @objc private func okClicked(_ sender: NSButton) {
        currentSettings().save()
        endSheet(returnCode: .OK)
    }

    private func updateValueLabels() {
        densityValue.stringValue = "\(Int(round(densitySlider.doubleValue)))%"
        speedValue.stringValue = String(format: "%.1fx", speedSlider.doubleValue)
    }

    private func bundleVersionString() -> String {
        let bundle = Bundle(identifier: "com.hxsf.MetalMatrix") ?? Bundle(for: MatrixSettingsWindowController.self)
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
            return ""
        }
    }

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: returnCode)
        } else {
            window.close()
        }
    }
}
