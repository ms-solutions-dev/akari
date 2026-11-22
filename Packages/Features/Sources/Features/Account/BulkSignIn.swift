import AccountsKit
import DesignSystem
import SwiftUI

/// One password for all open accounts whose names came with the setup code.
///
/// Scan the code, enter one password, done. Accounts that fail (a different password on
/// one server) stay as open rows with their message; the single sheet then asks only there.
struct BulkSignIn: View {

    @Environment(AccountRegistry.self) private var accounts
    @State private var password = ""
    @State private var running = false

    var body: some View {
        if !accounts.collectible.isEmpty {
            Section {
                SecureField(text: $password) {
                    Text(app: "account.password")
                }
                .onSubmit(signIn)
                Button(action: signIn) {
                    HStack {
                        Text(app: "setUp.all.signIn")
                        if running {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(running || password.isEmpty)
            } header: {
                Text(app: "setUp.all.title")
            } footer: {
                Text(app: "setUp.all.text")
            }
        }
    }

    private func signIn() {
        guard !password.isEmpty, !running else { return }
        running = true
        Task {
            await accounts.signInAll(password: password)
            // If everything succeeded the password is consumed; otherwise it is kept for a
            // second attempt, since usually only one server differs.
            if accounts.collectible.isEmpty { password = "" }
            running = false
        }
    }
}
