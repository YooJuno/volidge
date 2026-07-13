import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let router = AudioRouter()
    private lazy var viewModel = RouterViewModel(router: router)
    private var controlWindow: NSWindow?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        enableLaunchAtLogin()

        router.onStateChange = { [weak self] in
            self?.updateStatusTitle()
            self?.viewModel.refresh()
        }
        updateStatusTitle()
        showControlWindow()
        if router.requiresMicrophonePermission {
            requestAudioPermission()
        } else {
            startRoutingIfPossible()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        router.stop(restoreSystemDevices: true)
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
        button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volidge")
        button.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let volume = Int(router.volume * 100)
        button.title = " \(volume)%"
        button.toolTip = router.statusDescription
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let openControlWindow = NSMenuItem(title: "Open Volidge", action: #selector(showControlWindow), keyEquivalent: "")
        openControlWindow.target = self
        menu.addItem(openControlWindow)

        let outputMenu = NSMenu()
        for device in router.outputDevices {
            let item = NSMenuItem(title: device.name, action: #selector(selectOutput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.name
            item.state = device.name == router.selectedOutputName ? .on : .off
            outputMenu.addItem(item)
        }
        let outputItem = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
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

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Volidge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
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
        alert.messageText = "Volidge could not start"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func requestAudioPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRoutingIfPossible()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startRoutingIfPossible()
                    } else {
                        self?.showError("Microphone permission is required to receive audio from Volidge. Enable Volidge in Privacy & Security → Microphone, then reopen the app.")
                    }
                }
            }
        default:
            showError("Microphone permission is required to receive audio from Volidge. Enable Volidge in Privacy & Security → Microphone, then reopen the app.")
        }
    }

    private func startRoutingIfPossible() {
        guard !router.isRunning else { return }
        do {
            try router.start()
        } catch AudioRouterError.missingInputDevice {
            viewModel.refresh()
        } catch {
            showError(error.localizedDescription)
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 445),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Volidge"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        controlWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
