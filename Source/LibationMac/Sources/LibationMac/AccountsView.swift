import SwiftUI

struct AccountsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var showAdd = false
    @State private var selection: Account.ID?

    var body: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Audible accounts", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add the Audible account(s) whose libraries Libation should back up.")
                } actions: {
                    Button("Add Account…") { showAdd = true }
                }
            } else {
                List(store.accounts, selection: $selection) { account in
                    AccountRow(account: account)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                Button {
                    if let id = selection, let a = store.accounts.first(where: { $0.id == id }) { store.delete(a) }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
                Text("Accounts are stored in Libation's AccountsSettings.json and shared with the other front ends.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 560, minHeight: 320)
        .sheet(isPresented: $showAdd) { AddAccountSheet() }
        .alert(signInTitle, isPresented: Binding(get: { !store.signInResults.isEmpty }, set: { if !$0 { store.dismissSignInResult() } }), presenting: store.signInResults.first) { _ in
            Button("OK") { store.dismissSignInResult() }
        } message: { r in
            Text(r.ok ? "\(r.accountId) (\(r.locale ?? "")) is signed in." : (r.error ?? "Sign-in failed."))
        }
        .task { await store.reloadAccounts() }
    }

    private var signInTitle: String {
        guard let r = store.signInResults.first else { return "" }
        return r.ok ? "Signed in" : "Sign-in failed"
    }
}

private struct AccountRow: View {
    let account: Account
    @Environment(LibraryStore.self) private var store
    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.hasTokens ? "checkmark.seal.fill" : "exclamationmark.circle")
                .foregroundStyle(account.hasTokens ? Color.green : Color.orange)
                .help(account.hasTokens ? "Signed in" : "Not signed in — press Sign In")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Nickname", text: $name)
                    .textFieldStyle(.plain).fontWeight(.medium)
                    .onSubmit { if name != account.accountName { store.update(account, accountName: name) } }
                HStack(spacing: 6) {
                    Text(account.accountId)
                    Text("·")
                    Text(account.locale ?? "")
                    if !account.additionalLocales.isEmpty {
                        Text("+ " + account.additionalLocales.joined(separator: ", "))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Scan", isOn: Binding(get: { account.libraryScan }, set: { store.update(account, libraryScan: $0) }))
                .toggleStyle(.checkbox)
                .help("Include this account when scanning")
            Button(store.signingIn.contains(account.id) ? "Signing in…" : (account.hasTokens ? "Re-check" : "Sign In")) {
                store.signIn(account)
            }
            .disabled(store.signingIn.contains(account.id))
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .onAppear { name = account.accountName ?? "" }
        .onChange(of: account.accountName) { _, new in name = new ?? "" }
    }
}

private struct AddAccountSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var accountId = ""
    @State private var locale = "uk"
    @State private var nickname = ""
    @State private var scan = true
    @State private var signInNow = true
    @State private var error: String?
    @State private var busy = false

    private var locales: [LocaleInfo] { store.locales.filter { !$0.withUsername } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Audible Account").font(.title2).fontWeight(.semibold)
            Form {
                TextField("Email", text: $accountId, prompt: Text("you@example.com"))
                    .textContentType(.emailAddress)
                Picker("Marketplace", selection: $locale) {
                    ForEach(locales) { l in
                        Text("\(l.name.capitalized) (\(l.countryCode))").tag(l.name)
                    }
                }
                TextField("Nickname", text: $nickname, prompt: Text("Optional"))
                Toggle("Include in library scans", isOn: $scan)
                Toggle("Sign in now", isOn: $signInNow)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(signInNow ? "Add & Sign In" : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || accountId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if !locales.contains(where: { $0.name == locale }) { locale = locales.first?.name ?? "" } }
    }

    private func add() {
        busy = true; error = nil
        Task {
            do {
                try await store.addAccount(accountId: accountId.trimmingCharacters(in: .whitespaces), locale: locale,
                                           accountName: nickname.isEmpty ? nil : nickname, libraryScan: scan)
                if signInNow, let a = store.accounts.first(where: { $0.accountId.lowercased() == accountId.lowercased() && $0.locale == locale }) {
                    store.signIn(a)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
