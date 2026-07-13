import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class RouterViewModel: ObservableObject {
    private let router: AudioRouter

    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var selectedOutputName = ""
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var launchAtLogin = false
    @Published var volume: Double = 0
    @Published var errorMessage: String?

    init(router: AudioRouter) {
        self.router = router
        refresh()
    }

    func refresh() {
        outputDevices = router.outputDevices
        selectedOutputName = router.selectedOutputName
        isRunning = router.isRunning
        volume = Double(router.volume)
        status = router.statusDescription
        launchAtLogin = SMAppService.mainApp.status == .enabled
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

}

struct ControlPanel: View {
    @ObservedObject var model: RouterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Volidge")
                        .font(.system(size: 28, weight: .bold))
                    Text("Keyboard volume for your audio interface")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
            }

            Picker("Output", selection: outputBinding) {
                ForEach(model.outputDevices, id: \.name) { device in
                    Text(device.name).tag(device.name)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.isRunning ? "Routing system audio to \(model.selectedOutputName)" : "Routing is paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isRunning {
                Label(
                    "The orange microphone indicator is macOS showing access to Volidge's virtual audio channel. Your Mac's microphone is not recorded.",
                    systemImage: "waveform"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text("\(Int(model.volume * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: volumeBinding, in: 0 ... 1)
                    .tint(.pink)
                Text("Your keyboard volume knob follows this level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(model.isRunning ? "Stop" : "Start") {
                    model.toggleRouting()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Spacer()

                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Coffee donation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("3333063670931 · 카카오뱅크 유준호")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Copy account") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("3333063670931", forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(28)
        .frame(width: 480)
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
