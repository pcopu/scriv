import SwiftUI
import AppKit
import ScrivCore

enum ScrivAuthenticationPresentation { case compact, focused }

/// The focused presentation follows the approved sign-in design. Both layouts
/// use the same owner-fenced flow; codes exist only in this view's transient state.
struct ScrivEmailSignInForm: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var cloud: CloudClient
    var presentation: ScrivAuthenticationPresentation = .compact
    var onKeepWriting: (() -> Void)? = nil
    @State private var email = ""
    @State private var code = ""
    @State private var operationTask: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var browserError: String?
    @State private var ownerID = UUID()
    @State private var legacyAccountExpanded = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case email, code }
    private var focused: Bool { presentation == .focused }
    private var busy: Bool { cloud.emailSignIn.isBusy || operationID != nil }
    private var ownedElsewhere: Bool { cloud.signInOwnerID != nil && cloud.signInOwnerID != ownerID }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let flow = cloud.emailSignIn
            VStack(alignment: .leading, spacing: focused ? 20 : 13) {
                if ownedElsewhere {
                    heading(symbol: "person.crop.circle", title: "Sign in to Scriv", subtitle: "Sign-in is already open in another Scriv window.")
                    Button("Start sign-in here") {
                        cloud.cancelSignIn(); email = ""; code = ""; focusedField = .email
                    }.buttonStyle(AccountPrimaryButtonStyle(height: focused ? 46 : 36))
                    if onKeepWriting != nil { localExit }
                } else if flow.challengeID != nil {
                    codeEntry(flow: flow, now: timeline.date)
                } else {
                    emailEntry(flow: flow, now: timeline.date)
                }
                if !ownedElsewhere, let error = browserError ?? flow.errorMessage {
                    AccountInlineMessage(text: error, color: .red)
                        .accessibilityLabel("Sign-in error: \(error)")
                }
            }
            .font(.system(size: focused ? 15 : 13))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            email = cloud.emailSignIn.email
            if !ownedElsewhere { focusedField = cloud.emailSignIn.challengeID == nil ? .email : .code }
        }
        .onDisappear {
            // Publishing the account removes the form before account refresh
            // finishes. Never cancel that already-successful refresh request.
            if cloud.account == nil { cancel() }
            code = ""; email = ""
        }
        .onChange(of: store.cloudBaseURL) { _, _ in cancel(); email = "" }
        .onChange(of: store.navigationContext) { _, _ in cancel() }
        .onChange(of: cloud.emailSignIn.challengeID) { _, id in
            code = ""
            if !ownedElsewhere { focusedField = id == nil ? .email : .code }
        }
        .onChange(of: cloud.signInOwnerID) { _, next in
            if next != ownerID, operationID != nil, cloud.account == nil { cancel() }
        }
    }

    private func emailEntry(flow: EmailSignInFlow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: focused ? 22 : 13) {
            if focused {
                heading(symbol: "person.fill", title: "Sign in to Scriv", subtitle: "Save scripts to the cloud and join your team.")
                    .padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Email address").font(.system(size: focused ? 14 : 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.plain).textContentType(.emailAddress)
                    .font(.system(size: focused ? 17 : 14))
                    .focused($focusedField, equals: .email)
                    .padding(.horizontal, 14).frame(height: focused ? 46 : 38)
                    .background(ScrivTheme.inset.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focusedField == .email ? ScrivTheme.accent : ScrivTheme.hairline, lineWidth: focusedField == .email ? 2 : 1))
                    .disabled(busy || !flow.email.isEmpty)
                    .accessibilityLabel("Scriv account email address")
                    .onChange(of: email) { _, value in
                        if value.utf8.count > 254 {
                            var limited = value
                            while limited.utf8.count > 254 { limited.removeLast() }
                            email = limited
                        }
                    }
                    .onSubmit { requestCode() }
            }
            VStack(spacing: 12) {
                Button(action: requestCode) {
                    HStack(spacing: 8) {
                        if flow.phase == .requesting { ProgressView().controlSize(.small).tint(.white) }
                        Text(flow.phase == .requesting ? "Sending code…" : flow.resendSeconds(at: now) > 0 ? "Try again in \(flow.resendSeconds(at: now))s" : "Continue with email")
                    }
                }
                .buttonStyle(AccountPrimaryButtonStyle(height: focused ? 46 : 36))
                .disabled(busy || flow.resendSeconds(at: now) > 0 || (try? EmailSignInFlow.normalizedEmail(email)) == nil)
                Text("We'll email a one-time code. No password needed.")
                    .font(.system(size: focused ? 13 : 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            if onKeepWriting != nil { localExit }
            else if busy || !flow.email.isEmpty {
                Button("Cancel sign-in") { cancel(); email = ""; focusedField = .email }.buttonStyle(.borderless)
            }
            if flow.phase == .idle, flow.email.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    DisclosureGroup("Already used GitHub?", isExpanded: $legacyAccountExpanded) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Use your existing GitHub-linked Scriv account.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Continue with GitHub…", action: signInWithGitHub)
                                .buttonStyle(.bordered).disabled(busy)
                        }.padding(.top, 8)
                    }.font(.system(size: focused ? 14 : 12))
                }
            }
            if focused { identityFooter("ChatGPT sign-in is separate in Codex on this Mac.") }
        }
    }

    private func codeEntry(flow: EmailSignInFlow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: focused ? 23 : 13) {
            Button {
                cancel(); email = ""; focusedField = .email
            } label: { Label("Change email", systemImage: "chevron.left") }
                .buttonStyle(.borderless).disabled(busy)
            heading(symbol: "envelope", title: "Check your email", subtitle: "Enter the 6-digit code sent to \(flow.email)")
            TextField("—  —  —  —  —  —", text: $code)
                .textFieldStyle(.plain).textContentType(.oneTimeCode)
                .font(.system(size: focused ? 26 : 20, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center).tracking(focused ? 8 : 4)
                .focused($focusedField, equals: .code)
                .padding(.horizontal, 14).frame(height: focused ? 58 : 46)
                .background(ScrivTheme.inset.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focusedField == .code ? ScrivTheme.accent : ScrivTheme.hairline, lineWidth: focusedField == .code ? 2 : 1))
                .disabled(busy || flow.isExpired(at: now))
                .accessibilityLabel("Email sign-in code")
                .onChange(of: code) { _, value in
                    let clean = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if clean != value { code = clean }
                }
                .onSubmit { verifyCode() }
            VStack(spacing: 13) {
                Button(action: verifyCode) {
                    HStack(spacing: 8) {
                        if flow.phase == .verifying { ProgressView().controlSize(.small).tint(.white) }
                        Text(flow.phase == .verifying ? "Signing in…" : "Sign in with code")
                    }
                }.buttonStyle(AccountPrimaryButtonStyle(height: focused ? 46 : 36))
                    .disabled(busy || (try? EmailSignInFlow.normalizedCode(code)) == nil || flow.isExpired(at: now))
                VStack(spacing: 9) {
                    Text(flow.isExpired(at: now) ? "This code has expired. Request a new code." : "Code expires in \(countdown(flow.expirySeconds(at: now)))")
                        .foregroundStyle(flow.isExpired(at: now) ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(flow.resendSeconds(at: now) > 0 ? "Resend in \(flow.resendSeconds(at: now))s" : "Resend code", action: requestCode)
                        .buttonStyle(.borderless).disabled(busy || !flow.canResend(at: now))
                }.font(.system(size: focused ? 13 : 12)).frame(maxWidth: .infinity)
            }
            Button("Cancel sign-in") {
                cancel(); email = ""
                if let onKeepWriting { onKeepWriting() } else { focusedField = .email }
            }.buttonStyle(.borderless).frame(maxWidth: .infinity).padding(.vertical, focused ? 6 : 0)
            if focused { identityFooter("You can keep editing locally while signing in.") }
        }
    }

    private func heading(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: focused ? 15 : 8) {
            if focused {
                Image(systemName: symbol).font(.system(size: 29, weight: .regular))
                    .foregroundStyle(ScrivTheme.secondary)
                    .frame(width: 68, height: 68).background(ScrivTheme.inset, in: Circle())
                    .padding(.bottom, 4).accessibilityHidden(true)
            }
            Text(title).font(.system(size: focused ? 29 : 17, weight: .semibold))
            Text(subtitle).font(.system(size: focused ? 16 : 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(focused ? .center : .leading)
        }.frame(maxWidth: .infinity, alignment: focused ? .center : .leading)
    }
    private var localExit: some View {
        Button("Keep writing locally") { cancel(); onKeepWriting?() }
            .buttonStyle(.borderless).font(.system(size: focused ? 15 : 13, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, focused ? 3 : 0)
    }
    private func identityFooter(_ text: String) -> some View {
        VStack(spacing: 18) {
            Divider()
            Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "laptopcomputer").font(.system(size: 22, weight: .light))
            }.font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func countdown(_ seconds: Int) -> String { "\(seconds / 60):" + String(format: "%02d", seconds % 60) }
    private func requestCode() {
        guard !ownedElsewhere, !busy, (try? EmailSignInFlow.normalizedEmail(email)) != nil,
              cloud.emailSignIn.resendSeconds(at: Date()) == 0 else { return }
        let address = email; code = ""; browserError = nil
        let id = UUID(); operationID = id
        operationTask = Task {
            await store.requestEmailCode(address, ownerID: ownerID)
            guard operationID == id else { return }
            operationID = nil; operationTask = nil
            if cloud.emailSignIn.challengeID != nil { focusedField = .code }
        }
    }
    private func verifyCode() {
        guard !ownedElsewhere, !busy, (try? EmailSignInFlow.normalizedCode(code)) != nil,
              !cloud.emailSignIn.isExpired(at: Date()) else { return }
        let enteredCode = code, id = UUID(); operationID = id; browserError = nil
        operationTask = Task {
            await store.verifyEmailCode(enteredCode, ownerID: ownerID)
            guard operationID == id else { return }
            operationID = nil; operationTask = nil; code = ""
            if cloud.account == nil { focusedField = .code }
        }
    }
    private func signInWithGitHub() {
        guard !ownedElsewhere, !busy else { return }
        let id = UUID(); operationID = id; browserError = nil
        operationTask = Task {
            do { try await store.signInWithGitHub(ownerID: ownerID) }
            catch is CancellationError { }
            catch { if operationID == id { browserError = error.localizedDescription } }
            guard operationID == id else { return }
            operationID = nil; operationTask = nil
        }
    }
    private func cancel() {
        operationID = nil; operationTask?.cancel(); operationTask = nil
        cloud.cancelSignIn(ownerID: ownerID); code = ""; browserError = nil
    }
}

struct ScrivSignInSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close sign-in")
                        .keyboardShortcut(.cancelAction)
                }
                ScrivEmailSignInForm(cloud: store.cloud, presentation: .focused, onKeepWriting: { dismiss() })
                    .padding(.horizontal, 12).padding(.bottom, 24)
            }.padding(24)
        }.frame(width: 540, height: 660).background(ScrivTheme.panel)
            .onChange(of: store.account?.id) { _, id in if id != nil { dismiss() } }
    }
}

/// Shared only by the account/settings/job surfaces, preserving native focus,
/// disabled semantics and hit targets while matching the approved wide actions.
struct AccountPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: height > 40 ? 16 : 13, weight: .medium))
            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(minHeight: height)
            .padding(.horizontal, 13)
            .background(ScrivTheme.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct AccountInlineMessage: View {
    let text: String
    var color: Color = .orange
    var body: some View {
        Label { Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }.font(.system(size: 12)).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
}
