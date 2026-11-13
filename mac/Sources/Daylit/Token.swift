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
/// added from Terminal), then the item is replaced by one only Daylit can read. Daylit's own items carry a marker
/// in the generic attribute, which can be read without the secret, so telling the two apart never asks.
enum TokenStore {
    static let account = "homeassistant"
    /// Set on items Daylit created itself (kSecAttrGeneric): read in-process, never through `security`.
    private static let marker = Data("daylit-app-only-1".utf8)
    /// One read (and migration) at a time: the REST tick and the push client can ask at once.
    private static let lock = NSLock()

    /// The item's attributes, never its secret: whether it exists, its account, and whether Daylit made it.
    private static func attributes(_ service: String) -> (account: String, ours: Bool)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let a = out as? [String: Any] else { return nil }
        return ((a[kSecAttrAccount as String] as? String) ?? account, (a[kSecAttrGeneric as String] as? Data) == marker)
    }

    /// Whether a token is stored, without reading it (attributes only: never asks, never touches the secret).
    static func stored(_ service: String) -> Bool { attributes(service) != nil }

    /// The token, or nil (none stored, or the read was refused). Migrates an old item on the way.
    static func read(_ service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let item = attributes(service) else { return nil }
        if item.ours {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: item.account, kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return clean(String(data: d, encoding: .utf8))
        }
        guard let token = readWithSecurityTool(service) else { return nil }
        migrate(token, service: service, account: item.account)
        return token
    }

    /// Saves (or replaces) the token. Returns an error message, or nil.
    static func save(_ token: String, service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let data = Data(token.utf8)
        if let item = attributes(service) {
            if item.ours {
                let find: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                           kSecAttrAccount as String: item.account]
                let st = SecItemUpdate(find as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                return st == errSecSuccess ? nil : "Could not update the keychain item (\(st))"
            }
            // An old item trusts /usr/bin/security: replace it rather than keep its access list.
            guard delete(service: service, account: item.account) else { return "Could not replace the old keychain item" }
        }
        let st = add(data, service: service, account: account)
        return st == errSecSuccess ? nil : "Could not save to the keychain (\(st))"
    }

    private static func add(_ data: Data, service: String, account: String) -> OSStatus {
        // No kSecAttrAccess: the item's access list is this app only.
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecAttrLabel as String: service,
                                  kSecAttrGeneric as String: marker, kSecValueData as String: data]
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// Replaces an item that trusts /usr/bin/security with one only Daylit can read. On a failure the old item
    /// stays (it is never deleted before the token is in hand) and the next start tries again.
    private static func migrate(_ token: String, service: String, account: String) {
        guard delete(service: service, account: account) else {
            Log.write("token: could not move it to an app-only keychain item (the old item stays); trying again at the next start")
            return
        }
        let st = add(Data(token.utf8), service: service, account: account)
        if st == errSecSuccess { Log.write("token: moved to an app-only keychain item") }
        else { Log.write("token: could not save the app-only keychain item (\(st)); paste the token again with Home Assistant Token… after a restart") }
    }

    /// Deletes an old item. Its access list trusts /usr/bin/security, so that tool deletes it without a question;
    /// the Security framework is the fallback (it may ask, as the item does not trust this app).
    private static func delete(service: String, account: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", service, "-a", account]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { return true }
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    /// Only for an item made before this version: its access list trusts /usr/bin/security, not this app.
    /// The secret comes back on a pipe; it is never logged or put on a command line.
    private static func readWithSecurityTool(_ service: String) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return clean(String(data: data, encoding: .utf8))
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
                HAClient.clearTokenCache()
                NotificationCenter.default.post(name: .daylitTokenSaved, object: nil)
                Log.write("token: saved to the keychain")
                model.push.tokenChanged()
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
