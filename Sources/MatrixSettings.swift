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
    private static let currentSettingsVersion = 3

    var density: Float
    var speed: Float
    var mode: MatrixMode
    var fog: Bool
    var waves: Bool
    var rotate: Bool
    var showFPS: Bool

    static let standard = MatrixSettings(
        density: 100,
        speed: 1,
        mode: .matrix,
        fog: true,
        waves: true,
        rotate: true,
        showFPS: false
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
            Keys.settingsVersion: NSNumber(value: 0)
        ])
        return defaults
    }

    static func load() -> MatrixSettings {
        let defaults = MatrixSettings.defaults
        if defaults.integer(forKey: Keys.settingsVersion) < currentSettingsVersion {
            standard.save()
            return standard
        }
        let mode = MatrixMode(rawValue: defaults.integer(forKey: Keys.mode)) ?? .matrix
        return MatrixSettings(
            density: min(max(defaults.float(forKey: Keys.density), 0), 100),
            speed: min(max(defaults.float(forKey: Keys.speed), 0.1), 8),
            mode: mode,
            fog: defaults.bool(forKey: Keys.fog),
            waves: defaults.bool(forKey: Keys.waves),
            rotate: defaults.bool(forKey: Keys.rotate),
            showFPS: defaults.bool(forKey: Keys.showFPS)
        )
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
        defaults.set(MatrixSettings.currentSettingsVersion, forKey: Keys.settingsVersion)
        defaults.synchronize()
    }

    private enum Keys {
        static let density = "density"
        static let speed = "speed"
        static let mode = "mode"
        static let fog = "fog"
        static let waves = "waves"
        static let rotate = "rotate"
        static let showFPS = "showFPS"
        static let settingsVersion = "settingsVersion"
    }
}

final class MatrixSettingsWindowController: NSWindowController {
    private let densitySlider = NSSlider(value: Double(MatrixSettings.standard.density), minValue: 0, maxValue: 100, target: nil, action: nil)
    private let speedSlider = NSSlider(value: Double(MatrixSettings.standard.speed), minValue: 0.1, maxValue: 8, target: nil, action: nil)
    private let modePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fogButton = NSButton(checkboxWithTitle: MMString("option.fog"), target: nil, action: nil)
    private let wavesButton = NSButton(checkboxWithTitle: MMString("option.waves"), target: nil, action: nil)
    private let rotateButton = NSButton(checkboxWithTitle: MMString("option.panning"), target: nil, action: nil)
    private let fpsButton = NSButton(checkboxWithTitle: MMString("option.fps"), target: nil, action: nil)
    private let densityValue = NSTextField(labelWithString: "")
    private let speedValue = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 290),
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

        densitySlider.target = self
        densitySlider.action = #selector(sliderChanged(_:))
        speedSlider.target = self
        speedSlider.action = #selector(sliderChanged(_:))

        stack.addArrangedSubview(row(label: MMString("label.density"), control: densitySlider, valueLabel: densityValue))
        stack.addArrangedSubview(row(label: MMString("label.speed"), control: speedSlider, valueLabel: speedValue))
        stack.addArrangedSubview(row(label: MMString("label.encoding"), control: modePopUp, valueLabel: nil))

        let checks = NSStackView(views: [fogButton, wavesButton, rotateButton, fpsButton])
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
        let defaultsButton = NSButton(title: MMString("button.defaults"), target: self, action: #selector(defaultsClicked(_:)))
        let cancelButton = NSButton(title: MMString("button.cancel"), target: self, action: #selector(cancelClicked(_:)))
        let okButton = NSButton(title: MMString("button.ok"), target: self, action: #selector(okClicked(_:)))
        okButton.keyEquivalent = "\r"
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
        fogButton.state = settings.fog ? .on : .off
        wavesButton.state = settings.waves ? .on : .off
        rotateButton.state = settings.rotate ? .on : .off
        fpsButton.state = settings.showFPS ? .on : .off
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
            showFPS: fpsButton.state == .on
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

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: returnCode)
        } else {
            window.close()
        }
    }
}
