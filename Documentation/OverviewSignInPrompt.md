# Overview sign-in prompt

The footer no longer says “On your Mac. No account required.” Opening the main
window signed out now presents a native sheet with the existing Google sign-in
flow and approved dark/light Google button artwork. The prompt stays open for
progress/errors, closes after sign-in succeeds, and can be dismissed with Not Now
or Escape. It is shown once per main-window session, without interrupting every
module change. Signing out makes it eligible again. Restored signed-in accounts
are checked before prompting. Existing tools remain available when dismissed;
this change adds a prompt rather than a new authentication gate.

Google OAuth remains in testing mode, so invited/test accounts are required for
sign-in until the OAuth configuration is published. The popup does not grant
macOS permissions, sync utility data, or bypass Google's account restrictions.
