import SwiftUI

/// Presentation kept independent from authentication so all account states can
/// be previewed without accessing a real account or its Keychain.
struct WelcomeCard: View {
    let date: Date
    let firstName: String?
    let email: String?
    let activeCount: Int
    var isBusy = false
    var errorMessage: String?
    let signIn: () -> Void
    let signOut: () -> Void
    let disconnect: () -> Void
    @State private var hovering = false
    @State private var language = 0
    @State private var showingAccount = false
    @State private var emblemPulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var period: GreetingPeriod {
        GreetingPeriod(hour: Calendar.autoupdatingCurrent.component(.hour, from: date))
    }
    private var accent: Color {
        switch period {
        case .morning: Color(red: 0.94, green: 0.67, blue: 0.38)
        case .afternoon: Color(red: 0.92, green: 0.73, blue: 0.43)
        case .evening: Color(red: 0.80, green: 0.61, blue: 0.51)
        case .night: Color(red: 0.68, green: 0.67, blue: 0.84)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 18) {
                Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                accountControl
            }
            HStack(alignment: .center, spacing: 24) {
                Button { advance() } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(GreetingText.text(period: period, language: language, name: firstName))
                            .font(.system(size: 32, weight: .medium, design: fontDesign))
                            .tracking(language < 3 ? -0.7 : 0)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2, reservesSpace: false)
                            .id("\(period.rawValue)-\(language)-\(firstName ?? "")")
                            .transition(.opacity)
                        Text("Everything you need, within reach.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                    .contentShape(Rectangle())
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
                timeEmblem
            }
            HStack(spacing: 6) {
                Circle().fill(activeCount > 0 ? Color.green.opacity(0.8) : .secondary)
                    .frame(width: 5, height: 5).accessibilityHidden(true)
                Text("\(activeCount) \(activeCount == 1 ? "utility" : "utilities") running")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "globe").font(.system(size: 10))
                Text(hovering ? GreetingText.languages[language] : "Made for your day")
                    .font(.system(size: 11))
            }.foregroundStyle(.tertiary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(26)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .trailing) {
                    RadialGradient(colors: [accent.opacity(scheme == .dark ? 0.07 : 0.055), .clear],
                                   center: .trailing, startRadius: 0, endRadius: 330)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.primary.opacity(scheme == .dark ? 0.065 : 0.08), lineWidth: 0.5)
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

    private var timeEmblem: some View {
        Button { emblemPulse += 1 } label: {
            Image(systemName: period.symbol)
            .symbolEffect(.bounce, value: reduceMotion ? 0 : emblemPulse)
            .font(.system(size: 30, weight: .ultraLight))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(accent)
            .frame(width: 78, height: 78)
            .background(accent.opacity(scheme == .dark ? 0.045 : 0.07), in: Circle())
            .overlay(Circle().strokeBorder(accent.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(DashboardCardPressStyle())
        .accessibilityLabel("Animate \(period.symbol.contains("moon") ? "night" : "daylight") icon")
        .help("A little moment of play")
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
