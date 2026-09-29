import AVFoundation
import SwiftUI

/// First-run setup: camera, Accessibility, calibration, go.
struct WelcomeView: View {
    @ObservedObject var c: Coordinator
    var calibrate: () -> Void
    var close: () -> Void

    private var calibrated: Bool { !c.calibratedKeys.isEmpty && c.uncalibratedScreens.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headway").font(.system(size: 26, weight: .bold))
                    Text("Keyboard focus that follows your head.").foregroundStyle(.secondary)
                }
            }

            step(1, "Allow camera access",
                 "Headway reads which way your head is turned. Video is analysed in memory and discarded straight away — nothing is recorded or uploaded.",
                 done: c.cameraAuthorized) {
                if CameraService.authorization == .denied || CameraService.authorization == .restricted {
                    Button("Open Camera Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                } else {
                    Button("Allow Camera") {
                        CameraService.requestAccess { _ in c.previewRequested = true }
                    }
                }
            }

            step(2, "Allow Accessibility",
                 "This is how Headway moves keyboard focus between windows without clicking. In the list, switch Headway on.",
                 done: c.axTrusted) {
                Button("Open Accessibility Settings") {
                    AX.requestTrust()
                    AX.openAccessibilitySettings()
                }
            }

            step(3, "Calibrate your screens",
                 "A dot visits 9 spots on each screen (about 20 seconds per screen) while Headway learns what each one looks like from your chair.",
                 done: calibrated) {
                Button(c.calibratedKeys.isEmpty ? "Calibrate" : "Calibrate Again", action: calibrate)
                    .disabled(!c.cameraAuthorized)
            }

            step(4, "Start using it",
                 "Turn to the screen you want and type — no click needed. Pause any time with \(HotkeyChoice.saved == .off ? "the menu" : HotkeyChoice.saved.label) or from the eye in the menu bar.",
                 done: c.cameraAuthorized && c.axTrusted && calibrated) { EmptyView() }

            Divider()

            HStack {
                Circle()
                    .fill(c.faceVisible ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(c.cameraAuthorized
                     ? (c.faceVisible ? "The camera can see your face." : "The camera can't see your face yet.")
                     : "Camera not allowed yet.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    private func step<Accessory: View>(_ n: Int, _ title: String, _ detail: String, done: Bool,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !done { accessory() }
            }
        }
    }
}
