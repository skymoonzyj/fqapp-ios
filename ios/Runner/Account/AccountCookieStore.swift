import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Mirrors Android navigation origins. Cookie export is narrower: only cookies
/// that would be sent to https://fanqienovel.com/ may cross the Flutter boundary.
enum AccountCookiePolicy {
    private static let domains = ["fanqienovel.com", "snssdk.com", "bytedance.com", "zijieapi.com"]

    static func isAccountDomain(_ value: String) -> Bool {
        let host = String(value.lowercased().drop(while: { $0 == "." }))
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
            isAccountDomain(url.host ?? "")
    }

    static func header(_ cookies: [HTTPCookie], now: Date = Date()) -> String? {
        let selected = cookies.filter {
            String($0.domain.lowercased().drop(while: { $0 == "." })) == "fanqienovel.com" &&
                $0.path == "/" && ($0.expiresDate == nil || $0.expiresDate! > now)
        }.sorted { ($0.name, $0.value) < ($1.name, $1.value) }
        guard selected.contains(where: {
            ["sessionid", "sessionid_ss", "sid_tt"].contains($0.name) && !$0.value.isEmpty
        }) else { return nil }
        // Reject malformed header fields rather than letting delimiters create
        // additional credentials in the existing read-only request adapter.
        guard selected.allSatisfy({ cookie in
            !cookie.name.isEmpty && cookie.name.utf8.allSatisfy {
                $0 > 32 && $0 < 127 && !Array("()<>@,;:\\\"/[]?={}=".utf8).contains($0)
            } && cookie.value.utf8.allSatisfy { $0 >= 32 && $0 < 127 && $0 != 59 }
        }) else { return nil }
        let header = selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header.utf8.count <= 12 * 1024 ? header : nil
    }
}

protocol AccountCookieAccess: AnyObject {
    func cookies(_ completion: @escaping ([HTTPCookie]) -> Void)
    func clear(_ completion: @escaping () -> Void)
}

/// One login owns one result, including the dismissal interval. Store callbacks
/// are generation checked so cancelling can never publish a delayed Cookie.
final class AccountLoginSession {
    private let store: AccountCookieAccess
    private var active: UUID?
    private var result: ((String?) -> Void)?
    private var reading = false
    private var closing: UUID?
    private var closingCookie: String?
    private var clearing: UUID?
    var closeWindow: (UUID, @escaping () -> Void) -> Void = { _, done in done() }
    var invalidCookie: () -> Void = {}

    init(store: AccountCookieAccess) { self.store = store }
    var busy: Bool { active != nil || closing != nil || clearing != nil }

    func begin(_ completion: @escaping (String?) -> Void) -> UUID? {
        precondition(Thread.isMainThread)
        guard !busy else { return nil }
        let id = UUID()
        active = id
        result = completion
        return id
    }

    func readCookies(for id: UUID) {
        precondition(Thread.isMainThread)
        guard active == id, !reading else { return }
        reading = true
        store.cookies { [weak self] cookies in
            accountOnMain {
                guard let self, self.active == id else { return }
                self.reading = false
                guard let header = AccountCookiePolicy.header(cookies) else {
                    self.invalidCookie()
                    return
                }
                self.finish(header)
            }
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        if closing != nil {
            closingCookie = nil
            return
        }
        finish(nil)
    }

    private func finish(_ cookie: String?) {
        guard let id = active else { return }
        let completion = result
        active = nil
        result = nil
        reading = false
        closing = id
        closingCookie = cookie
        closeWindow(id) { [self] in
            accountOnMain {
                guard self.closing == id else { return }
                let value = self.closingCookie
                self.closingCookie = nil
                self.closing = nil
                completion?(value)
            }
        }
    }

    @discardableResult
    func clear(_ completion: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard !busy else { return false }
        let id = UUID()
        clearing = id
        store.clear { [self] in
            accountOnMain {
                guard self.clearing == id else { return }
                self.clearing = nil
                completion()
            }
        }
        return true
    }
}

func accountOnMain(_ action: @escaping () -> Void) {
    if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
}

#if canImport(WebKit) && os(iOS)
final class AccountCookieStore: AccountCookieAccess {
    // iOS16 has no public named persistent data-store API. Its default store is
    // still app-private (not Safari's); selective cleanup preserves other pages.
    let dataStore: WKWebsiteDataStore
    init(dataStore: WKWebsiteDataStore? = nil) {
        if let dataStore {
            self.dataStore = dataStore
        } else if #available(iOS 17.0, *) {
            self.dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "D9F387AD-681E-48DC-96DA-7A3128A1BCB9")!)
        } else {
            self.dataStore = .default()
        }
    }

    func cookies(_ completion: @escaping ([HTTPCookie]) -> Void) {
        precondition(Thread.isMainThread)
        dataStore.httpCookieStore.getAllCookies(completion)
    }

    func clear(_ completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        let store = dataStore
        store.httpCookieStore.getAllCookies { cookies in
            accountOnMain {
                let group = DispatchGroup()
                for cookie in cookies where AccountCookiePolicy.isAccountDomain(cookie.domain) {
                    group.enter()
                    store.httpCookieStore.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) {
                    let types = WKWebsiteDataStore.allWebsiteDataTypes()
                    store.fetchDataRecords(ofTypes: types) { records in
                        accountOnMain {
                            let selected = records.filter { AccountCookiePolicy.isAccountDomain($0.displayName) }
                            guard !selected.isEmpty else { completion(); return }
                            store.removeData(ofTypes: types, for: selected) { accountOnMain(completion) }
                        }
                    }
                }
            }
        }
    }
}
#endif
