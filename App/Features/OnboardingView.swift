import SwiftUI

/// Short first run (spec §66). The spoken diagnostic arrives in M2; until then the difficulty model
/// starts at a sensible default for a rusty former resident and adapts from the first session.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = false
    @State private var step = 0
    @State private var name = ""
    @State private var permissionDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LineStripe().frame(width: 36).padding(.top, 40)
            switch step {
            case 0: welcome
            case 1: permissions
            default: ready
            }
            Spacer()
        }
        .padding(Metrics.padding)
        .background(Palette.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("話せる").font(.subheadline).foregroundStyle(Palette.inkSecondary)
            Text("A Japanese speaking coach for your working day.")
                .font(.largeTitle.weight(.semibold)).foregroundStyle(Palette.ink)
            Text("Short, spoken sessions built around high-speed rail work and everyday conversation. Listen, answer out loud, get feedback — phone in your pocket.")
                .foregroundStyle(Palette.inkSecondary)
            TextField("What should I call you?", text: $name)
                .textContentType(.givenName)
                .padding(14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            PrimaryButton(title: "Continue") {
                app.repository.setName(name)
                step = 1
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your voice").font(.largeTitle.weight(.semibold)).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 12) {
                Label("Hanaseru listens only during your turn, and shows when it is listening.", systemImage: "mic")
                Label("Your speech is turned into text on this iPhone when possible, otherwise by Apple's speech service.", systemImage: "iphone")
                Label("Audio is never recorded or stored.", systemImage: "waveform.slash")
            }
            .foregroundStyle(Palette.ink)
            if permissionDenied {
                Text("Microphone or speech recognition was declined. You can allow them later in iOS Settings › Hanaseru.")
                    .font(.footnote).foregroundStyle(Palette.caution)
            }
            PrimaryButton(title: "Allow microphone & speech", systemImage: "mic.fill") {
                Task {
                    let granted = await VoicePermissions.request()
                    permissionDenied = !granted
                    if granted { step = 2 }
                }
            }
            Button("Not now") { step = 2 }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Put your earphones in").font(.largeTitle.weight(.semibold)).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 12) {
                Label("You'll hear 「聞いてください」 — listen.", systemImage: "ear")
                Label("A chime and 「あなたの番です」 — your turn to speak.", systemImage: "bell")
                Label("Stop talking and it moves on. Say 「もう一度」 to hear it again.", systemImage: "arrow.clockwise")
                Label("Press your AirPods to pause.", systemImage: "airpodspro")
            }
            .foregroundStyle(Palette.ink)
            Text("Your first sessions calibrate the difficulty. A full spoken assessment is coming in the next update.")
                .font(.footnote).foregroundStyle(Palette.inkSecondary)
            PrimaryButton(title: "Start practising") { onboardingDone = true }
        }
    }
}
