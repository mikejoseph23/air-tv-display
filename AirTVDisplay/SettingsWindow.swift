import AppKit

/// Small fixed-size settings window; one instance, reused and brought to front.
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    private let settings: AppSettings
    private let onNameChange: () -> Void
    private let onAudioChange: (Bool) -> Void
    private var window: NSWindow?
    private let nameField = NSTextField()
    private let audioBox = NSButton(checkboxWithTitle: "Play audio on this display", target: nil, action: nil)
    private let hudBox = NSButton(checkboxWithTitle: "Show diagnostics HUD at launch", target: nil, action: nil)
    private let escBox = NSButton(checkboxWithTitle: "Esc quits the app", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let loginNote = NSTextField(wrappingLabelWithString: "")

    init(settings: AppSettings, onNameChange: @escaping () -> Void, onAudioChange: @escaping (Bool) -> Void) {
        self.settings = settings
        self.onNameChange = onNameChange
        self.onAudioChange = onAudioChange
        super.init()
    }

    func show() {
        if window == nil { build() }
        loadValues()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 270),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Air TV Display Settings"
        w.isReleasedWhenClosed = false
        // Above the fullscreen receiver window (.mainMenu + 1).
        w.level = .mainMenu + 2

        let nameLabel = NSTextField(labelWithString: "Name")
        nameField.placeholderString = AppSettings.defaultName
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commitName)

        let audioNote = NSTextField(wrappingLabelWithString:
            "To keep sound on the sending Mac, choose its speakers in Control Center \u{2192} Sound on that Mac.")
        audioNote.font = .systemFont(ofSize: 11)
        audioNote.textColor = .secondaryLabelColor
        loginNote.font = .systemFont(ofSize: 11)
        loginNote.textColor = .systemOrange

        for (box, sel) in [(audioBox, #selector(audioToggled)), (hudBox, #selector(hudToggled)),
                           (escBox, #selector(escToggled)), (loginBox, #selector(loginToggled))] {
            box.target = self
            box.action = sel
        }

        let nameRow = NSStackView(views: [nameLabel, nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let stack = NSStackView(views: [nameRow, audioBox, audioNote, hudBox, escBox, loginBox, loginNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: audioBox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            audioNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        w.contentView = content
        w.center()
        window = w
    }

    private func loadValues() {
        nameField.stringValue = settings.storedName
        audioBox.state = settings.storedPlayAudio ? .on : .off
        hudBox.state = settings.showHUDAtLaunchStored ? .on : .off
        escBox.state = settings.escQuits ? .on : .off
        loginBox.state = LoginItem.isEnabled ? .on : (settings.launchAtLogin ? .on : .off)
        loginNote.stringValue = LoginItem.statusMessage() ?? ""
    }

    // Commit on Return / end editing, not per keystroke.
    func controlTextDidEndEditing(_ obj: Notification) { commitName() }

    @objc private func commitName() {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != settings.storedName else { return }
        settings.storedName = typed
        onNameChange()
    }

    @objc private func audioToggled() {
        let on = audioBox.state == .on
        settings.storedPlayAudio = on
        onAudioChange(settings.playAudio)
    }

    @objc private func hudToggled() { settings.showHUDAtLaunchStored = hudBox.state == .on }

    @objc private func escToggled() { settings.escQuits = escBox.state == .on }

    @objc private func loginToggled() {
        let on = loginBox.state == .on
        settings.launchAtLogin = on
        loginNote.stringValue = LoginItem.apply(on) ?? ""
    }
}
