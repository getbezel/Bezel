import SwiftUI

struct WelcomeHeader: View {
    @Bindable var account: GoogleAccount

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            WelcomeCard(date: context.date, firstName: account.firstName, email: account.email,
                        isBusy: account.isBusy, errorMessage: account.errorMessage,
                        signIn: account.signIn, signOut: account.signOut, disconnect: account.disconnect)
        }
    }
}
