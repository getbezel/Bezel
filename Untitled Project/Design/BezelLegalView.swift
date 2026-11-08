import SwiftUI

struct BezelLegalView: View {
    @State private var document = Document.terms
    enum Document: String, CaseIterable, Identifiable {
        case terms = "Early Access Terms"
        case notices = "Third-Party Notices"
        case setup = "Installation & Permissions"
        var id: String { rawValue }
        var resource: String {
            switch self {
            case .terms: "EarlyAccessTerms"
            case .notices: "ThirdPartyNotices"
            case .setup: "EarlyAccessSetup"
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 32)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bezel").font(.title.bold())
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") · Early Access")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("© 2026 Bezel authors. All rights reserved in original Bezel contributions.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Document", selection: $document) {
                ForEach(Document.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.menu)
            ScrollView {
                Text(documentText).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            Text("Original work is protected; general ideas and independently written implementations are not reserved by this notice. Third-party rights remain separate.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
    private var documentText: String {
        let url = Bundle.main.url(forResource: document.resource, withExtension: "txt")
            ?? Bundle.main.url(forResource: document.resource, withExtension: "txt", subdirectory: "Legal")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This document is missing from this build. Please obtain a complete Bezel package from its owner before evaluating the app."
        }
        return text
    }
}
