import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let router = AudioRouter()
    private lazy var viewModel = RouterViewModel(router: router)
    private var mediaKeyMonitor: MediaKeyMonitor?
    private var controlWindow: NSWindow?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        requestAudioPermission()
        enableLaunchAtLogin()

        mediaKeyMonitor = MediaKeyMonitor { [weak self] key in
            guard let self else { return }

            switch key {
            case .volumeUp:
                self.router.adjustVolume(by: 0.05)
            case .volumeDown:
                self.router.adjustVolume(by: -0.05)
            case .mute:
                self.router.toggleMute()
            }
        }
        mediaKeyMonitor?.start()

        router.onStateChange = { [weak self] in
            self?.updateStatusTitle()
            self?.viewModel.refresh()
        }
        updateStatusTitle()
        showControlWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        router.stop(restoreSystemDevices: true)
        mediaKeyMonitor?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Vol")
        button.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let volume = Int((router.isMuted ? 0 : router.volume) * 100)
        button.title = " \(volume)%"
        button.toolTip = router.statusDescription
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: router.statusDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let openControlWindow = NSMenuItem(title: "Open Vol", action: #selector(showControlWindow), keyEquivalent: "")
        openControlWindow.target = self
        menu.addItem(openControlWindow)

        let sourceMenu = NSMenu()
        for device in router.inputDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.name
            item.state = device.name == router.selectedInputName ? .on : .off
            sourceMenu.addItem(item)
        }
        let sourceItem = NSMenuItem(title: "Virtual audio device", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        let outputMenu = NSMenu()
        for device in router.outputDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectOutput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.name
            item.state = device.name == router.selectedOutputName ? .on : .off
            outputMenu.addItem(item)
        }
        let outputItem = NSMenuItem(title: "Play through", action: nil, keyEquivalent: "")
        outputItem.submenu = outputMenu
        menu.addItem(outputItem)
        menu.addItem(.separator())

        let startStop = NSMenuItem(
            title: router.isRunning ? "Stop routing" : "Start routing",
            action: #selector(toggleRouting),
            keyEquivalent: ""
        )
        startStop.target = self
        menu.addItem(startStop)

        let mute = NSMenuItem(
            title: router.isMuted ? "Unmute" : "Mute",
            action: #selector(toggleMute),
            keyEquivalent: "m"
        )
        mute.target = self
        menu.addItem(mute)

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)

        let openSettings = NSMenuItem(
            title: "Open Sound Settings…",
            action: #selector(openSoundSettings),
            keyEquivalent: ","
        )
        openSettings.target = self
        menu.addItem(openSettings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Vol", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        router.selectInput(named: name)
        viewModel.refresh()
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        router.selectOutput(named: name)
        viewModel.refresh()
    }

    @objc private func toggleRouting() {
        if router.isRunning {
            router.stop(restoreSystemDevices: true)
        } else {
            do {
                try router.start()
            } catch {
                showError(error.localizedDescription)
            }
        }
        viewModel.refresh()
    }

    @objc private func toggleMute() {
        router.toggleMute()
        viewModel.refresh()
    }

    @objc private func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Could not update login settings: \(error.localizedDescription)")
        }
        viewModel.refresh()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Vol could not start"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func requestAudioPermission() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard !granted else { return }
            DispatchQueue.main.async {
                self?.showError("Microphone permission is required to receive audio from BlackHole. Enable Vol in Privacy & Security → Microphone, then reopen the app.")
            }
        }
    }

    private func enableLaunchAtLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Vol could not enable launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func showControlWindow() {
        if let controlWindow {
            controlWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: ControlPanel(model: viewModel))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vol"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        controlWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
