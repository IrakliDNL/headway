import AVFoundation
import HeadwayCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var c: Coordinator
    var recalibrate: () -> Void

    @State private var hotkey = HotkeyChoice.saved
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cameras: [(id: String, name: String)] = CameraService.devices().map { ($0.uniqueID, $0.localizedName) }

    private func bind<T>(_ kp: WritableKeyPath<HeadwaySettings, T>) -> Binding<T> {
        Binding(get: { c.settings[keyPath: kp] }, set: { v in c.update { $0[keyPath: kp] = v } })
    }

    var body: some View {
        Form {
            Section("Switching screens") {
                slider("Switch delay", bind(\.switchDelay), 0.1...1.5, 0.05, ms,
                       "Looks at the other screen shorter than this don't count.")
                slider("Turn threshold", bind(\.headTurn), 0.2...0.8, 0.05, percent,
                       "How far towards the other screen your head must point. 50% = the gap between the screens.")
                Toggle("Bring the pointer to the screen I turn to", isOn: bind(\.movePointer))
            }

            Section("Within the same screen") {
                Toggle("Focus the window or pane you're looking at", isOn: bind(\.focusWithinScreen))
                slider("Delay for windows and panes", bind(\.paneDelay), 0.1...1.5, 0.05, ms,
                       "Dwell time before the window or pane you look at takes focus.")
                    .disabled(!c.settings.focusWithinScreen)
                Toggle("Click to focus panes in terminals and editors", isOn: bind(\.clickToFocusPanes))
                    .disabled(!c.settings.focusWithinScreen)
                Text("Fallback for terminals and editors that ignore Accessibility focus: Headway clicks the middle of the pane. Other apps are never clicked.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Cursor and VS Code: to see split panes Headway switches on their accessibility tree. If they offer Screen Reader mode, choose No — or set \"editor.accessibilitySupport\": \"off\" in their settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("While typing") {
                Toggle("Hold focus while typing", isOn: bind(\.waitWhileTyping))
                Text("While you type, looking at another window or screen switches only after about a second, so quick glances don't steal your keystrokes. Split panes inside one app stay put until you stop typing.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Typing hold", bind(\.typingPause), 0.5...10, 0.5, seconds,
                       "Counted from your last keystroke.")
                    .disabled(!c.settings.waitWhileTyping)
            }

            Section("Learning") {
                Toggle("Learn from clicks", isOn: bind(\.learnFromClicks))
                Text("Each click tells Headway where you were looking, so accuracy improves as you work.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(c.learnedClicks) clicks learned").foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget Clicks") { c.forgetClicks() }.disabled(c.learnedClicks == 0)
                    Button("Recalibrate…", action: recalibrate)
                }
            }

            Section("Camera") {
                Picker("Camera", selection: bind(\.cameraID)) {
                    Text("Built-in (default)").tag(String?.none)
                    ForEach(cameras, id: \.id) { cam in Text(cam.name).tag(String?.some(cam.id)) }
                }
                Text("Pick the camera that's straight in front of you. Video is analysed in memory only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Extras") {
                Toggle("Show where Headway thinks you're looking", isOn: bind(\.showGazeDot))
                Picker("Pause/resume shortcut", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: hotkey) { _, new in
                    HotkeyChoice.saved = new
                    Hotkey.shared.register(new)
                }
                if hotkey == .shiftCmdG {
                    Text("⇧⌘G is also “Go to Folder” in Finder and “Find Previous” in many apps; Headway takes it over everywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double,
                        _ format: @escaping (Double) -> String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func ms(_ v: Double) -> String { "\(Int((v * 1000).rounded())) ms" }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func seconds(_ v: Double) -> String { String(format: v == v.rounded() ? "%.0f s" : "%.1f s", v) }
}
