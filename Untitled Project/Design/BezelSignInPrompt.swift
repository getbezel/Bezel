import SwiftUI

struct BezelSignInPrompt: View {
    @Bindable var account: GoogleAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Welcome to Bezel").font(.title2.weight(.semibold))
                Text("Sign in with Google for your personal Bezel profile and greeting.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if account.isBusy {
                ProgressView("Connecting…").controlSize(.small)
            } else {
                Button { account.signIn() } label: {
                    Image(scheme == .dark ? "GoogleSignInDark" : "GoogleSignInLight")
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 180, height: 41)
                }.buttonStyle(.plain).accessibilityLabel("Sign in with Google")
            }
            if let error = account.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            Button("Not Now", role: .cancel) { dismiss() }
                .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
        }.padding(32).frame(width: 380)
    }
}
