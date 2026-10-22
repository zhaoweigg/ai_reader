import SwiftUI

struct ChatGPTConnectionView: View {
    @ObservedObject var accounts: ChatGPTAccountStore
    @Binding var model: String

    var body: some View {
        Section {
            if !accounts.accounts.isEmpty {
                Picker("ChatGPT account", selection: Binding(get: { accounts.selectedID ?? "" }, set: { id in
                    do { try accounts.select(id); model = ""; Task { await accounts.loadModels() } }
                    catch { accounts.error = ChatGPTAccountStore.message(error) }
                })) {
                    ForEach(accounts.accounts) { account in Text(account.label).tag(account.id) }
                }.disabled(accounts.isBusy).accessibilityIdentifier("chatGPTAccountPicker")
            }
            if let account = accounts.selected, account.tokens != nil {
                Label(account.canUsePlan ? "ChatGPT connected" : "Plan permission needed", systemImage: account.canUsePlan ? "checkmark.shield" : "exclamationmark.shield")
                    .accessibilityIdentifier("chatGPTConnectionState")
                if account.canUsePlan {
                    Picker("Model", selection: $model) {
                        if !accounts.models.contains(where: { $0.slug == model }) { Text(model.isEmpty ? "Choose a model" : model).tag(model) }
                        ForEach(accounts.models) { item in Text(item.displayName).tag(item.slug) }
                    }.accessibilityIdentifier("chatGPTModelPicker")
                    Button { Task { await accounts.loadModels() } } label: {
                        if accounts.isLoadingModels { Label("Loading models…", systemImage: "arrow.trianglehead.2.clockwise") }
                        else { Label("Refresh available models", systemImage: "arrow.clockwise") }
                    }.disabled(accounts.isLoadingModels || accounts.isBusy)
                }
                Button(account.canUsePlan ? "Sign in again" : "Enable ChatGPT plan access") {
                    accounts.signIn(existing: account, reconsent: !account.canUsePlan)
                }.disabled(accounts.isBusy)
                Button("Sign out of this account", role: .destructive) { Task { await accounts.signOut() } }
                    .disabled(accounts.isBusy).accessibilityIdentifier("signOutChatGPT")
            }
            Button { accounts.signIn(existing: accounts.selected?.tokens == nil ? accounts.selected : nil) } label: {
                HStack {
                    Image(systemName: "person.crop.circle")
                    Text("Continue with ChatGPT").fontWeight(.semibold)
                    Spacer()
                    if accounts.isBusy { ProgressView() }
                }.frame(minHeight: 32)
            }.disabled(accounts.isBusy).accessibilityIdentifier("continueWithChatGPT")
            if accounts.selected != nil, accounts.selected?.tokens == nil {
                Button("Use another ChatGPT account") { accounts.signIn() }.disabled(accounts.isBusy)
            }
            if accounts.isBusy { Button("Cancel sign-in") { accounts.cancelSignIn() } }
            Link("ChatGPT Settings → Usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            if let error = accounts.error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("chatGPTConnectionError") }
            if let notice = accounts.notice { Text(notice).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("chatGPTConnectionNotice") }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.environment["LEAF_UI_CHATGPT_BROWSER"] == "1" {
                Button("Verify native browser callback") { Task { await accounts.testBrowserLoopback() } }
                    .accessibilityIdentifier("testChatGPTBrowser")
            }
            #endif
        } header: { Text("ChatGPT subscription") } footer: {
            Text("Sign in on OpenAI’s secure page. Leaf never sees your password. Eligible requests use your ChatGPT plan and its limits, including any credit settings you approve there. This connection does not fall back to API-key billing.")
        }
        .task { if accounts.selected?.canUsePlan == true { await accounts.loadModels() } }
        .onChange(of: accounts.models) { _, models in
            if !models.contains(where: { $0.slug == model }) { model = models.first?.slug ?? "" }
        }
    }
}
