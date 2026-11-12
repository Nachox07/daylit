// The Home Assistant token dialog and keychain write. The token goes straight from the field into
// the keychain; it is never logged, printed or passed on a command line.
import SwiftUI
import AppKit
import Security
import DaylitCore

enum TokenStore {
    /// Saves (or replaces) the token under `service`. The item trusts this app and /usr/bin/security,
    /// which is how Daylit reads it, so reading never prompts. Returns an error message, or nil.
    static func save(_ token: String, service: String) -> String? {
        let data = Data(token.utf8)
        let find: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if SecItemCopyMatching(find as CFDictionary, nil) == errSecSuccess {
            let st = SecItemUpdate(find as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            return st == errSecSuccess ? nil : "Could not update the keychain item (\(st))"
        }
        var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "homeassistant", kSecAttrLabel as String: service,
                                  kSecValueData as String: data]
        if let access = access(service) { add[kSecAttrAccess as String] = access }
        let st = SecItemAdd(add as CFDictionary, nil)
        return st == errSecSuccess ? nil : "Could not save to the keychain (\(st))"
    }

    // SecTrustedApplicationCreateFromPath and SecAccessCreate are the only way to give a file-keychain
    // item a list of trusted apps. They are deprecated, so they are looked up at run time rather than
    // called directly (a direct call is a compiler warning).
    private typealias AppCreate = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Unmanaged<AnyObject>?>) -> OSStatus
    private typealias AccessCreate = @convention(c) (CFString, CFArray, UnsafeMutablePointer<Unmanaged<AnyObject>?>) -> OSStatus

    private static func access(_ label: String) -> AnyObject? {
        guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let a = dlsym(h, "SecTrustedApplicationCreateFromPath"), let b = dlsym(h, "SecAccessCreate") else { return nil }
        let appCreate = unsafeBitCast(a, to: AppCreate.self), accessCreate = unsafeBitCast(b, to: AccessCreate.self)
        var me: Unmanaged<AnyObject>?, tool: Unmanaged<AnyObject>?
        guard appCreate(nil, &me) == errSecSuccess, let me = me?.takeRetainedValue(),
              appCreate("/usr/bin/security", &tool) == errSecSuccess, let tool = tool?.takeRetainedValue() else { return nil }
        var acc: Unmanaged<AnyObject>?
        guard accessCreate(label as CFString, [me, tool] as CFArray, &acc) == errSecSuccess else { return nil }
        return acc?.takeRetainedValue()
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
