import AppKit
import Observation
import Security
@preconcurrency import AppAuth

/// Optional local profile. Authentication uses AppAuth's state/nonce/PKCE checks;
/// credentials stay in this signed app's macOS login Keychain.
@MainActor @Observable
final class GoogleAccount {
    private(set) var firstName: String?
    private(set) var email: String?
    private(set) var isBusy = false
    var errorMessage: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var authState: OIDAuthState?
    @ObservationIgnored private var flow: (any OIDExternalUserAgentSession)?
    @ObservationIgnored private var profileTask: Task<Void, Never>?

    private struct SavedAccount: Codable {
        let clientID: String
        let state: Data
        let firstName: String?
        let email: String
    }
    private struct Profile: Decodable {
        let sub: String
        let given_name: String?
        let email: String
        let email_verified: Bool?
    }
    private var clientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              value.hasSuffix(".apps.googleusercontent.com"), !value.contains("$") else { return nil }
        return value
    }
    private var callbackScheme: String? {
        clientID.map { $0.components(separatedBy: ".").reversed().joined(separator: ".") }
    }
    var isSignedIn: Bool { email != nil }
    var isConfigured: Bool {
        guard let callbackScheme else { return false }
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(callbackScheme) == true }
    }

    func start() {
        guard !started, isConfigured else { return }
        started = true
        do {
            guard let data = try AccountKeychain.read() else { return }
            let saved = try JSONDecoder().decode(SavedAccount.self, from: data)
            guard saved.clientID == clientID,
                  let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: saved.state),
                  state.isAuthorized else { try AccountKeychain.remove(); return }
            authState = state
            firstName = saved.firstName.flatMap(GreetingText.cleanName)
            email = saved.email
            refreshProfile()
        } catch {
            errorMessage = "Your saved Google session couldn’t be opened. Sign in again when you’re ready."
        }
    }

    func signIn() {
        guard !isBusy else { return }
        guard isConfigured, let clientID, let callbackScheme,
              let redirect = URL(string: "\(callbackScheme):/oauth2callback") else {
            errorMessage = "Google sign-in is not configured in this build yet. All Bezel utilities remain available."
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            errorMessage = "Open the Bezel window to sign in."
            return
        }
        errorMessage = nil; isBusy = true
        let token = generation
        let config = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            issuer: URL(string: "https://accounts.google.com")!)
        // This initializer generates a cryptographically random state, nonce,
        // and S256 PKCE verifier/challenge through AppAuth.
        let request = OIDAuthorizationRequest(configuration: config, clientId: clientID, clientSecret: nil,
            scopes: ["openid", "profile", "email"], redirectURL: redirect, responseType: OIDResponseTypeCode,
            additionalParameters: ["prompt": "select_account"])
        let agent = OIDExternalUserAgentMac(presenting: window)
        flow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { [weak self] state, error in
            MainActor.assumeIsolated { [self] in
                guard let self, self.generation == token else { return }
                flow = nil
                guard let state, state.isAuthorized else {
                    isBusy = false
                    // A cancelled browser sheet is an ordinary exit from sign-in.
                    let nativeError = error as NSError?
                    if nativeError?.domain != OIDGeneralErrorDomain || nativeError?.code != OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
                        errorMessage = "Google sign-in couldn’t finish. Please try again."
                    }
                    return
                }
                authState = state
                refreshProfile()
            }
        }
    }

    func signOut() {
        // Do not pretend credentials were erased if Keychain is locked.
        do { try AccountKeychain.remove() }
        catch { errorMessage = "Unlock your login Keychain and try signing out again."; return }
        generation = UUID()
        profileTask?.cancel(); profileTask = nil
        flow?.cancel(); flow = nil; authState = nil
        firstName = nil; email = nil; errorMessage = nil; isBusy = false
    }

    func disconnect() {
        guard !isBusy, let state = authState,
              let token = state.refreshToken ?? state.lastTokenResponse?.accessToken else { signOut(); return }
        isBusy = true
        let epoch = generation
        profileTask = Task { [weak self] in
            do {
                var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.form(["token": token]).data(using: .utf8)
                request.timeoutInterval = 15
                let (_, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let self, self.generation == epoch else { return }
                isBusy = false
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    errorMessage = "Google couldn’t disconnect the account. Please try again."; return
                }
                signOut()
            } catch {
                guard let self, self.generation == epoch else { return }
                isBusy = false
                if !(error is CancellationError) { errorMessage = "Couldn’t reach Google. Check your connection and try disconnecting again." }
            }
        }
    }

    func handle(_ url: URL) -> Bool {
        guard url.scheme == callbackScheme else { return false }
        return flow?.resumeExternalUserAgentFlow(with: url) ?? false
    }

    private func refreshProfile() {
        guard let state = authState else { isBusy = false; return }
        isBusy = true
        let epoch = generation
        state.performAction { [weak self] accessToken, _, error in
            MainActor.assumeIsolated { [self] in
                guard let self, self.generation == epoch else { return }
                guard let accessToken, error == nil else {
                    isBusy = false
                    if !state.isAuthorized { signOut(); errorMessage = "Your Google session expired. Sign in again." }
                    else { errorMessage = "Google is unavailable. Your saved greeting is still here." }
                    return
                }
                profileTask = Task { [weak self] in
                    do {
                        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
                        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                        request.timeoutInterval = 15
                        let (data, response) = try await URLSession.shared.data(for: request)
                        try Task.checkCancellation()
                        guard let self, self.generation == epoch else { return }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 64 * 1024 else {
                            throw AccountError.profile
                        }
                        let profile = try JSONDecoder().decode(Profile.self, from: data)
                        guard !profile.sub.isEmpty, profile.email_verified == true, !profile.email.isEmpty else { throw AccountError.profile }
                        if let token = state.lastTokenResponse?.idToken,
                           let identity = OIDIDToken(idTokenString: token), identity.subject != profile.sub {
                            throw AccountError.profile
                        }
                        let name = profile.given_name.flatMap(GreetingText.cleanName)
                        let archived = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
                        let saved = SavedAccount(clientID: clientID ?? "", state: archived, firstName: name, email: profile.email)
                        try AccountKeychain.save(JSONEncoder().encode(saved))
                        firstName = name; email = profile.email; errorMessage = nil; isBusy = false
                    } catch {
                        guard let self, self.generation == epoch else { return }
                        isBusy = false
                        if !(error is CancellationError) { errorMessage = "Couldn’t load or securely save your Google profile. Check your connection and login Keychain, then try again." }
                    }
                }
            }
        }
    }

    private static func form(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

private enum AccountError: Error { case profile, keychain(OSStatus) }

/// The login Keychain uses this app's code-signing requirement for access.
/// No tokens or identity data are stored in UserDefaults or diagnostics.
private enum AccountKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.bezel.utility.google-account",
         kSecAttrAccount as String: "primary"]
    }
    static func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
        return result as? Data
    }
    static func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            let add = SecItemAdd(item as CFDictionary, nil)
            guard add == errSecSuccess else { throw AccountError.keychain(add) }
        } else if status != errSecSuccess { throw AccountError.keychain(status) }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain(status) }
    }
}
