# Personal welcome screen

The Overview uses the Mac's current calendar and time zone: morning 05:00–11:59, afternoon 12:00–16:59, evening 17:00–21:59, and night 22:00–04:59. The clock refreshes once a minute. Hovering cycles English, Spanish, French, Japanese and Hindi every 2.2 seconds with native typefaces; clicking advances one language. Reduce Motion disables automatic cycling and transition animation.

Google sign-in is optional. The first name comes from Google's authenticated `given_name`; signed-out greetings contain no account name. The account menu supports local sign-out and Google token revocation. Existing utilities do not require sign-in.

## OAuth configuration

Copy `Configuration/Local.xcconfig.example` to the ignored
`Configuration/Local.xcconfig`. Supply your own `BEZEL_DEVELOPMENT_TEAM`,
`BEZEL_GOOGLE_CLIENT_ID`, and reversed-client-ID `BEZEL_GOOGLE_CALLBACK_SCHEME`.
The native Google OAuth client must use bundle ID `com.bezel.utility`.
The callback URI is `<reversed-client-ID>:/oauth2callback`.
No developer account IDs or client secrets are included in this repository.

Without configuration, the utilities remain available and sign-in explains that
setup is required. If your Google consent screen is in Testing, add test users
before signing in. The only requested scopes are `openid profile email`.

AppAuth 2.1.0 handles authorization-code exchange, random state and nonce, S256 PKCE and token refresh through the system authentication browser. Endpoints and issuer are pinned to Google's HTTPS endpoints. Profile data is read from Google's HTTPS UserInfo endpoint and correlated to the ID-token subject when returned. No client secret is embedded. The header uses Google’s pre-approved dark/light pill PNGs, preserving the original logo and aspect ratio. Assets: https://developers.google.com/static/identity/images/branding_guideline_sample_dk_rd_lg.png and https://developers.google.com/static/identity/images/branding_guideline_sample_lt_rd_lg.png.

The native GoogleSignIn wrapper's Data Protection Keychain storage required a provisioning profile unavailable to this development team. Authentication therefore uses AppAuth directly and stores its securely archived session plus the minimal name/email profile in this signed app's **macOS login Keychain**, avoiding a shared keychain entitlement. Credentials are not written into UserDefaults, the repository, or diagnostic logs. No other application reads this entry. The app's existing bundle identifier and signing requirement are preserved.

## Verification

`Scripts/test-welcome.sh` covers local-time boundaries, time-zone changes, signed-out text, Unicode names and bounded display text. The universal Release build checks the SwiftUI and AppAuth integration. Provider-side client and test-user configuration is specific to each developer. First-time interactive sign-in still requires the account owner to choose their Google account and complete any Google authentication/consent prompts.

References: [Google's macOS configuration guide](https://developers.google.com/identity/sign-in/ios/start-integrating), [AppAuth-iOS](https://github.com/openid/AppAuth-iOS), [native application OAuth guidance](https://www.rfc-editor.org/rfc/rfc8252.html).

The refined header places a compact account control beside the date, removes the former full-width sign-in row, and uses an opaque reading surface with a subtle time-of-day accent. Native offscreen previews were inspected in signed-out dark mode and signed-in dark/light mode with Latin and Japanese names. `Scripts/preview-welcome.swift` renders the production `WelcomeCard` without accessing real credentials.
