import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class RouterViewModel: ObservableObject {
    private let router: AudioRouter

    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var selectedInputName = ""
    @Published private(set) var selectedOutputName = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isMuted = false
    @Published private(set) var status = ""
    @Published private(set) var launchAtLogin = false
    @Published var volume: Double = 0
    @Published var errorMessage: String?

    init(router: AudioRouter) {
        self.router = router
        refresh()
    }

    func refresh() {
        inputDevices = router.inputDevices
        outputDevices = router.outputDevices
        selectedInputName = router.selectedInputName
        selectedOutputName = router.selectedOutputName
        isRunning = router.isRunning
        isMuted = router.isMuted
        volume = Double(router.volume)
        status = router.statusDescription
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func selectInput(_ name: String) {
        router.selectInput(named: name)
        refresh()
    }

    func selectOutput(_ name: String) {
        router.selectOutput(named: name)
        refresh()
    }

    func setVolume(_ value: Double) {
        router.setVolume(Float(value))
        refresh()
    }

    func toggleRouting() {
        if router.isRunning {
            router.stop(restoreSystemDevices: true)
        } else {
            do {
                try router.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refresh()
    }

    func toggleMute() {
        router.toggleMute()
        refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not update login settings: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
}

struct ControlPanel: View {
    @ObservedObject var model: RouterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vol")
                        .font(.system(size: 28, weight: .bold))
                    Text("iD14 keyboard volume bridge")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
            }

            VStack(spacing: 12) {
                Picker("Virtual audio device", selection: inputBinding) {
                    ForEach(model.inputDevices, id: \.name) { device in
                        Text(device.name).tag(device.name)
                    }
                }
                Picker("Play through", selection: outputBinding) {
                    ForEach(model.outputDevices, id: \.name) { device in
                        Text(device.name).tag(device.name)
                    }
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text("\(Int((model.isMuted ? 0 : model.volume) * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: volumeBinding, in: 0 ... 1)
                    .tint(.pink)
                Text("Your keyboard volume knob follows this level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button(model.isRunning ? "Stop Routing" : "Start Routing") {
                    model.toggleRouting()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Button(model.isMuted ? "Unmute" : "Mute") {
                    model.toggleMute()
                }
                .disabled(!model.isRunning)

                Spacer()

                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack {
                Button("Sound Settings…") {
                    model.openSoundSettings()
                }
                .buttonStyle(.link)
                Spacer()
                Text("BlackHole → iD14")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { model.selectedInputName },
            set: { name in model.selectInput(name) }
        )
    }

    private var outputBinding: Binding<String> {
        Binding(
            get: { model.selectedOutputName },
            set: { name in model.selectOutput(name) }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.volume },
            set: { value in model.setVolume(value) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { enabled in model.setLaunchAtLogin(enabled) }
        )
    }
}
