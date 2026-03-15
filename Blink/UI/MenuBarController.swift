import AppKit

protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidSelectRecording(at url: URL)
    func menuBarDidSelectQuit()
}

final class MenuBarController {
    weak var delegate: MenuBarControllerDelegate?

    private var statusItem: NSStatusItem?
    private let storage: StorageManager
    private let settings = Settings.shared

    init(storage: StorageManager) {
        self.storage = storage
    }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Blink")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        item.menu = buildMenu()
        statusItem = item
    }

    func showRecordingState(_ isRecording: Bool) {
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: isRecording ? "record.circle.fill" : "record.circle",
                accessibilityDescription: "Blink"
            )
            button.contentTintColor = isRecording ? .systemRed : nil
        }
    }

    func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    func setTooltip(_ text: String) {
        statusItem?.button?.toolTip = text
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let recents = storage.recentArchives(limit: 5)
        if !recents.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(withTitle: "Recent Recordings"))
            for url in recents {
                let item = NSMenuItem(
                    title: url.lastPathComponent,
                    action: #selector(openRecording(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = url
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem.sectionHeader(withTitle: "Settings"))

        let audioItem = NSMenuItem(
            title: "Capture System Audio",
            action: #selector(toggleAudio(_:)),
            keyEquivalent: ""
        )
        audioItem.target = self
        audioItem.state = settings.captureAudio ? .on : .off
        menu.addItem(audioItem)

        let micItem = NSMenuItem(
            title: "Capture Microphone",
            action: #selector(toggleMic(_:)),
            keyEquivalent: ""
        )
        micItem.target = self
        micItem.state = settings.captureMicrophone ? .on : .off
        menu.addItem(micItem)

        let autoStartItem = NSMenuItem(
            title: "Start on Login",
            action: #selector(toggleAutoStart(_:)),
            keyEquivalent: ""
        )
        autoStartItem.target = self
        autoStartItem.state = settings.autoStart ? .on : .off
        menu.addItem(autoStartItem)

        menu.addItem(.separator())

        let openFolder = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openFolder(_:)),
            keyEquivalent: ""
        )
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Blink",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.menuBarDidSelectRecording(at: url)
    }

    @objc private func toggleAudio(_ sender: NSMenuItem) {
        settings.captureAudio.toggle()
        refreshMenu()
    }

    @objc private func toggleMic(_ sender: NSMenuItem) {
        settings.captureMicrophone.toggle()
        refreshMenu()
    }

    @objc private func toggleAutoStart(_ sender: NSMenuItem) {
        settings.autoStart.toggle()
        (NSApp.delegate as? AppDelegate)?.updateLoginItem()
        refreshMenu()
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Recordings/Blink")
        NSWorkspace.shared.open(folder)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        delegate?.menuBarDidSelectQuit()
    }
}
