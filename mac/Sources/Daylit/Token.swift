// The Home Assistant token dialog and its keychain item. The token goes straight from the field into
// the keychain; it is never logged, printed or passed on a command line.
import SwiftUI
import AppKit
import Security
import DaylitCore

/// The token's keychain item. Daylit reads and writes it with the Security framework, and an item Daylit creates
/// trusts only Daylit (the default access list of a file-keychain item is the app that made it): no other program
/// can read it without the keychain asking. That needs a stable signature, so an update does not ask again
/// (release builds; an ad-hoc dev build asks after every rebuild).
///
/// Older Daylit versions, and `security add-generic-password` from Terminal, made items that trust
/// /usr/bin/security instead. Reading one from here would ask the user, so the first read of such an item goes
/// through `security` once (no question for an item an older Daylit saved; one, naming `security`, for an item
/// added from Terminal), then the item is replaced by one only Daylit can read: the new item is saved first, the old
/// one deleted after (DaylitCore.TokenItems.replace), so the token is always in the keychain. Daylit's own items
/// carry a marker in the generic attribute, which can be read without the secret, so telling the two apart never asks.
enum TokenStore {
    static let account = "homeassistant"
    /// One read, save or migration at a time: the REST tick and the push client can ask at once.
    private static let lock = NSLock()
    /// Once per launch: the move away from /usr/bin/security, and a token that could not be moved (DaylitCore.TokenReads).
    nonisolated(unsafe) private static var reads = TokenReads()
    private static let keychain = SystemKeychain()

    /// Whether a token is stored, without reading it (attributes only: never asks, never touches the secret).
    static func stored(_ service: String) -> Bool { !keychain.items(service: service).isEmpty }

    /// The token, or nil (none stored, or the read was refused). Moves an old item on the first read of a launch.
    static func read(_ service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return reads.read(service: service, in: keychain) { Log.write($0) }
    }

    /// Saves (or replaces) the token. Returns an error message, or nil.
    static func save(_ token: String, service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { reads.saved(service: service) }
        guard let item = TokenItems.pick(keychain.items(service: service)) else {
            return keychain.addOwn(service: service, account: account, token: token) ? nil : "Could not save to the keychain"
        }
        if item.ours {
            let st = keychain.updateOwn(service: service, account: item.account, token: token)
            return st == errSecSuccess ? nil : "Could not update the keychain item (\(st))"
        }
        // An old item trusts /usr/bin/security: replace it rather than keep its access list. The old one goes
        // only once the new one is saved.
        switch TokenItems.replace(item, with: token, service: service, in: keychain) {
        case .replaced, .replacedUnderTemporaryAccount: Log.write(TokenReads.movedLine); return nil
        case .keptOld(let why): return "Could not replace the old keychain item (\(why))"
        }
    }
}

/// TokenKeychain on the login keychain. Daylit's items have no custom access list (so only Daylit can read them)
/// and carry a marker in the generic attribute; old items are read and deleted through /usr/bin/security, which
/// they trust, so moving them asks no question for an item an older Daylit saved.
struct SystemKeychain: TokenKeychain {
    private static let marker = Data("daylit-app-only-1".utf8)

    private func base(_ service: String, _ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    func items(service: String) -> [TokenItem] {
        var q = base(service)
        q[kSecMatchLimit as String] = kSecMatchLimitAll; q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return [] }
        let list = (out as? [[String: Any]]) ?? ((out as? [String: Any]).map { [$0] } ?? [])
        return list.map { a in
            TokenItem(account: (a[kSecAttrAccount as String] as? String) ?? TokenStore.account,
                      ours: (a[kSecAttrGeneric as String] as? Data) == Self.marker)
        }
    }

    func readOwn(service: String, account: String) -> String? {
        var q = base(service, account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return Self.clean(String(data: d, encoding: .utf8))
    }

    /// Only for an item made before this version. The secret comes back on a pipe; it is never logged or put on a command line.
    func readLegacy(service: String, account: String) -> String? {
        let (ok, data) = Self.security(["find-generic-password", "-s", service, "-a", account, "-w"])
        return ok ? Self.clean(String(data: data, encoding: .utf8)) : nil
    }

    func addOwn(service: String, account: String, token: String) -> Bool {
        // No kSecAttrAccess: the item's access list is this app only.
        var q = base(service, account)
        q[kSecAttrLabel as String] = service; q[kSecAttrGeneric as String] = Self.marker; q[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    func updateOwn(service: String, account: String, token: String) -> OSStatus {
        SecItemUpdate(base(service, account) as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
    }

    func deleteOwn(service: String, account: String) -> Bool {
        let st = SecItemDelete(base(service, account) as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    /// The old item trusts /usr/bin/security, so that tool deletes it without a question; the Security framework is
    /// the fallback (it may ask, as the item does not trust this app).
    func deleteLegacy(service: String, account: String) -> Bool {
        if Self.security(["delete-generic-password", "-s", service, "-a", account]).0 { return true }
        let st = SecItemDelete(base(service, account) as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    func renameOwn(service: String, from: String, to: String) -> Bool {
        SecItemUpdate(base(service, from) as CFDictionary, [kSecAttrAccount as String: to] as CFDictionary) == errSecSuccess
    }

    private static func security(_ args: [String]) -> (Bool, Data) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (false, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, data)
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

struct TokenView: View {
    let service: String
    let done: (Bool) -> Void
    @State private var token = ""
    @State private var error: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a Home Assistant long-lived access token.")
            Text("In Home Assistant: your profile → Security → Long-lived access tokens → Create token. Daylit keeps it in your keychain as “\(service)”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Token", text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Home Assistant token")
                .onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel")
                Button("Save", action: save).keyboardShortcut(.defaultAction).accessibilityLabel("Save")
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).frame(width: 420)
    }

    func save() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let e = TokenStore.save(t, service: service) { error = e; return }
        token = ""
        done(true)
    }
}

@MainActor enum TokenWindow {
    static var window: NSWindow?
    static var askedAtStart = false

    static func show(_ model: Daylit) {
        StatusController.shared?.close()
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let service = model.config.homeAssistant?.tokenName ?? "daylit-home-assistant"
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Daylit — Home Assistant Token"; w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: TokenView(service: service) { saved in
            window?.close()
            if saved {
                // A token pasted here is for the address in the config now: approved on this Mac.
                TokenGate.trust(model.config.homeAssistant)
                model.tokenQuestion = nil
                HAClient.clearTokenCache()
                NotificationCenter.default.post(name: .daylitTokenSaved, object: nil)
                Log.write("token: saved to the keychain")
                model.syncPush(force: true)   // a fresh try, also after auth_invalid or a socket that waited for approval
                model.refresh()
            }
        })
        w.center(); window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in window = nil }
        }
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }

    /// Once per launch: Home Assistant is the source but no token is stored yet.
    static func askIfMissing(_ model: Daylit) {
        guard !askedAtStart, model.source == .homeAssistant else { return }
        askedAtStart = true
        let service = model.config.homeAssistant?.tokenName ?? "daylit-home-assistant"
        if !HAClient.tokenStored(service) { show(model) }
    }
}

extension Notification.Name {
    /// Posted after a token is stored, so an open Settings window shows it.
    static let daylitTokenSaved = Notification.Name("daylit.tokenSaved")
}
