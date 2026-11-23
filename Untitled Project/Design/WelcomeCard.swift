import SwiftUI

/// Presentation kept independent from authentication so all account states can
/// be previewed without accessing a real account or its Keychain.
struct WelcomeCard: View {
    let date: Date
    let firstName: String?
    let email: String?
    var isBusy = false
    var errorMessage: String?
    let signIn: () -> Void
    let signOut: () -> Void
    let disconnect: () -> Void
    @State private var hovering = false
    @State private var language = 0
    @State private var showingAccount = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var period: GreetingPeriod {
        GreetingPeriod(hour: Calendar.autoupdatingCurrent.component(.hour, from: date))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1).foregroundStyle(.secondary)
            HStack {
                Button { advance() } label: {
                    Text(GreetingText.text(period: period, language: language, name: firstName))
                        .font(.system(size: 32, weight: .medium, design: fontDesign))
                        .tracking(-1).lineLimit(2).multilineTextAlignment(.leading)
                        .id(language)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel(GreetingText.text(period: period, language: 0, name: firstName))
                .accessibilityHint("Show this greeting in another language")
                .help("Hover or click for another language")
                .task(id: hovering && !reduceMotion) {
                    guard hovering && !reduceMotion else { setLanguage(0); return }
                    do {
                        try await Task.sleep(for: .milliseconds(550))
                        while !Task.isCancelled {
                            advance()
                            try await Task.sleep(for: .seconds(2.2))
                        }
                    } catch { }
                }
                Spacer()
                accountControl
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var accountControl: some View {
        if isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }.frame(height: 32)
        } else if email != nil {
            Button { showingAccount.toggle() } label: {
                HStack(spacing: 7) {
                    Text(String((firstName ?? "You").prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.06), in: Circle())
                    Text(firstName ?? "Account").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }.foregroundStyle(.secondary).padding(.trailing, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Google account for \(firstName ?? "you")")
            .popover(isPresented: $showingAccount, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(firstName ?? "Your account").font(.headline)
                    Text(email ?? "").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Divider()
                    Button("Sign Out") { showingAccount = false; signOut() }
                    Button("Disconnect Google Account", role: .destructive) {
                        showingAccount = false; disconnect()
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .padding(18).frame(minWidth: 230, alignment: .leading)
            }
        } else {
            // Google's pre-approved pill artwork preserves its logo, font and
            // spacing, with an actual dark theme rather than the old blue SDK button.
            Button(action: signIn) {
                Image(scheme == .dark ? "GoogleSignInDark" : "GoogleSignInLight")
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 150, height: 34)
            }
            .buttonStyle(.plain).accessibilityLabel("Sign in with Google")
            .help("Sign in for a personal greeting")
        }
    }

    private var fontDesign: Font.Design {
        switch language {
        case 1: .serif
        case 2: .rounded
        default: .default
        }
    }
    private func setLanguage(_ value: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { language = value }
    }
    private func advance() { setLanguage((language + 1) % GreetingText.languages.count) }
}
