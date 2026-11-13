// The order of the keychain steps that move the Home Assistant token to an item only Daylit can read, kept
// away from the Security framework so it can be tested with a fake keychain. The app's TokenStore implements
// `TokenKeychain` with SecItem calls and /usr/bin/security. The token is never logged.
import Foundation

/// One keychain item for the token's service, by its attributes only (never the secret).
public struct TokenItem: Equatable, Sendable {
    public let account: String
    /// Made by Daylit (carries its marker): readable in-process, trusts only Daylit.
    public let ours: Bool
    public init(account: String, ours: Bool) { self.account = account; self.ours = ours }
}

public protocol TokenKeychain {
    /// Every item for `service`, attributes only (never asks, never reads the secret).
    func items(service: String) -> [TokenItem]
    /// Daylit's own item, read in-process.
    func readOwn(service: String, account: String) -> String?
    /// An old item that trusts /usr/bin/security, read through that tool.
    func readLegacy(service: String, account: String) -> String?
    /// Adds an item only Daylit can read, with the marker.
    func addOwn(service: String, account: String, token: String) -> Bool
    func deleteOwn(service: String, account: String) -> Bool
    /// Deletes an old item (through /usr/bin/security, which it trusts).
    func deleteLegacy(service: String, account: String) -> Bool
    /// Changes the account of Daylit's own item.
    func renameOwn(service: String, from: String, to: String) -> Bool
}

public enum TokenItems {
    /// The account the new item gets until the old one is gone (the two cannot share service and account).
    public static let temporarySuffix = ".daylit"

    /// The item to use when more than one exists (a migration cut short): Daylit's own first.
    public static func pick(_ items: [TokenItem]) -> TokenItem? { items.first(where: \.ours) ?? items.first }

    public enum Replaced: Equatable {
        /// The old item is gone and the new one has its account.
        case replaced
        /// The old item is gone; the new one kept the temporary account (lookups are by service, so it still works).
        case replacedUnderTemporaryAccount
        /// Nothing changed: the old item stays and holds the token it held.
        case keptOld(String)
    }

    /// Replaces `old` (an item that trusts /usr/bin/security) with one only Daylit can read, holding `token`.
    /// The token is in a keychain item at every step: the new item is added first, under a temporary account,
    /// and the old one is deleted only after that worked. If the old one cannot be deleted, the new one is
    /// removed again, so exactly one item remains.
    public static func replace(_ old: TokenItem, with token: String, service: String, in kc: TokenKeychain) -> Replaced {
        let temp = old.account + temporarySuffix
        guard kc.addOwn(service: service, account: temp, token: token) else { return .keptOld("could not add the app-only item") }
        guard kc.deleteLegacy(service: service, account: old.account) else {
            _ = kc.deleteOwn(service: service, account: temp)
            return .keptOld("could not delete the old item")
        }
        return kc.renameOwn(service: service, from: temp, to: old.account) ? .replaced : .replacedUnderTemporaryAccount
    }
}

/// What this launch has learned about the token's items: the move away from /usr/bin/security is tried once per
/// launch per service, and a token read from an old item that could not be moved is kept for the session, so a
/// failure does not run /usr/bin/security (and maybe ask) on every read.
public struct TokenReads: Sendable {
    private var tried: Set<String> = []
    private var cleaned: Set<String> = []
    private var session: [String: String] = [:]

    public init() {}

    public static let movedLine = "token: moved to an app-only keychain item"

    public mutating func read(service: String, in kc: TokenKeychain, log: (String) -> Void) -> String? {
        if let t = session[service] { return t }
        let all = kc.items(service: service)
        guard var item = TokenItems.pick(all) else { return nil }
        if item.ours {
            if let token = kc.readOwn(service: service, account: item.account) {
                // An old item left beside ours (a move cut short): it still trusts /usr/bin/security, so remove
                // it, once, but only after ours gave the token back, so the old one is never the last copy lost.
                if all.contains(where: { !$0.ours }), !cleaned.contains(service) {
                    cleaned.insert(service)
                    for old in all where !old.ours { _ = kc.deleteLegacy(service: service, account: old.account) }
                }
                return token
            }
            // Ours can't be read: fall back to an old item beside it, if there is one.
            guard let old = all.first(where: { !$0.ours }) else { return nil }
            item = old
        }
        guard !tried.contains(service) else { return nil }   // this launch already tried and could not read it
        tried.insert(service)
        guard let token = kc.readLegacy(service: service, account: item.account) else {
            log("token: could not read the keychain item; paste the token again with Home Assistant Token… or restart Daylit")
            return nil
        }
        switch TokenItems.replace(item, with: token, service: service, in: kc) {
        case .replaced, .replacedUnderTemporaryAccount: log(Self.movedLine)
        case .keptOld(let why):
            log("token: \(why), so it stays in the old keychain item for now; trying again at the next start")
            session[service] = token
        }
        return token
    }

    /// A token was saved: forget what this launch knew, so the next read uses the keychain again.
    public mutating func saved(service: String) {
        session[service] = nil; tried.remove(service); cleaned.remove(service)
    }
}
