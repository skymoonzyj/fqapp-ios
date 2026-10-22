import XCTest
#if os(iOS)
import WebKit
#endif
@testable import Runner

final class FanqieAccountTests: XCTestCase {
    private func cookie(_ name: String = "sessionid", _ value: String = "fixture", domain: String = ".fanqienovel.com", path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"])!
    }

    #if os(iOS)
    func testWKClearWaitsForDeletionAndPreservesUnrelatedAppCookies() {
        let store = AccountCookieStore(dataStore: .nonPersistent())
        let loaded = expectation(description: "fixture cookies set")
        let group = DispatchGroup()
        for value in [cookie(), cookie("verify", "fixture", domain: ".snssdk.com"), cookie("unrelated", "keep", domain: ".other.example")] {
            group.enter()
            store.dataStore.httpCookieStore.setCookie(value) { group.leave() }
        }
        group.notify(queue: .main) { loaded.fulfill() }
        wait(for: [loaded], timeout: 10)
        let session = AccountLoginSession(store: store)
        _ = session.begin { value in XCTAssertNil(value) }
        session.cancel()
        let preserved = expectation(description: "ordinary close preserves session")
        store.cookies { cookies in
            XCTAssertEqual(AccountCookiePolicy.header(cookies), "sessionid=fixture")
            preserved.fulfill()
        }
        wait(for: [preserved], timeout: 10)
        let cleared = expectation(description: "selective deletion fully completed")
        XCTAssertTrue(session.clear {
            store.cookies { cookies in
                XCTAssertNil(AccountCookiePolicy.header(cookies))
                XCTAssertFalse(cookies.contains { AccountCookiePolicy.isAccountDomain($0.domain) })
                XCTAssertEqual(cookies.first { $0.name == "unrelated" }?.value, "keep")
                cleared.fulfill()
            }
        })
        wait(for: [cleared], timeout: 10)
    }
    #endif

    func testOfficialCookieScopeAndRequiredSession() {
        XCTAssertEqual(AccountCookiePolicy.header([cookie(), cookie("csrf", "ok")]), "csrf=ok; sessionid=fixture")
        XCTAssertNil(AccountCookiePolicy.header([cookie(domain: "evilfanqienovel.com")]))
        XCTAssertNil(AccountCookiePolicy.header([cookie(domain: ".snssdk.com")]))
        XCTAssertNil(AccountCookiePolicy.header([cookie(domain: "passport.fanqienovel.com")]))
        XCTAssertNil(AccountCookiePolicy.header([cookie(path: "/account")]))
        XCTAssertNil(AccountCookiePolicy.header([cookie("csrf", "only")]))
        XCTAssertNil(AccountCookiePolicy.header([cookie("sessionid", String(repeating: "x", count: 3072)), cookie("a", String(repeating: "x", count: 3072)), cookie("b", String(repeating: "x", count: 3072)), cookie("c", String(repeating: "x", count: 3072))]))
        XCTAssertEqual(AccountCookiePolicy.header([cookie("sid_tt", "present")]), "sid_tt=present")
    }

    func testClearPolicyIncludesOnlyAccountCookieAndWebsiteDomains() {
        for domain in [".fanqienovel.com", "passport.snssdk.com", "bytedance.com", "verify.zijieapi.com"] {
            XCTAssertTrue(AccountCookiePolicy.isAccountDomain(domain))
        }
        for domain in ["other.example", "evilfanqienovel.com", "fanqienovel.com.evil.test", "", "com"] {
            XCTAssertFalse(AccountCookiePolicy.isAccountDomain(domain))
        }
        XCTAssertEqual(AccountCookiePolicy.header([cookie(), cookie("sessionid", "foreign", domain: ".other.example")]), "sessionid=fixture")
    }

    func testDuplicateLateDismissalDoesNotFinishAnotherWindow() {
        let store = DeferredAccountStore()
        let session = AccountLoginSession(store: store)
        var dismissals: [() -> Void] = []
        session.closeWindow = { _, done in dismissals.append(done) }
        var values: [String?] = []
        _ = session.begin { values.append($0) }
        session.cancel()
        dismissals[0]()
        _ = session.begin { values.append($0) }
        session.cancel()
        dismissals[0]()
        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(session.busy)
        dismissals[1]()
        XCTAssertEqual(values.count, 2)
    }

    func testNavigationRejectsLookalikesCredentialsAndNonHTTPS() {
        for value in ["https://fanqienovel.com/", "https://passport.snssdk.com/", "https://a.bytedance.com/", "https://a.zijieapi.com/"] {
            XCTAssertTrue(AccountCookiePolicy.allows(URL(string: value)!))
        }
        for value in ["https://fanqienovel.com.evil.test/", "https://evilfanqienovel.com/", "http://fanqienovel.com/", "https://user@fanqienovel.com/", "https://fanqienovel.com./", "file:///tmp/page.html", "javascript:alert(1)"] {
            XCTAssertFalse(AccountCookiePolicy.allows(URL(string: value)!))
        }
    }

    func testCancelAndLateCookieCompleteOnceAndKeepSession() {
        let store = DeferredAccountStore()
        let session = AccountLoginSession(store: store)
        var values: [String?] = []
        let id = session.begin { values.append($0) }!
        session.readCookies(for: id)
        session.cancel()
        store.replyCookies([cookie()])
        session.cancel()
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values[0])
        XCTAssertEqual(store.clearCount, 0)
        let next = session.begin { values.append($0) }!
        session.readCookies(for: next)
        store.replyCookies([cookie()])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[1], "sessionid=fixture")
    }

    func testCancelDuringSuccessfulCookieDismissalRevokesPendingCookie() {
        let store = DeferredAccountStore()
        let session = AccountLoginSession(store: store)
        var dismiss: (() -> Void)?
        session.closeWindow = { _, done in dismiss = done }
        var values: [String?] = []
        let id = session.begin { values.append($0) }!
        session.readCookies(for: id)
        store.replyCookies([cookie()])
        XCTAssertTrue(values.isEmpty)
        XCTAssertTrue(session.busy)
        session.cancel()
        dismiss?()
        dismiss?()
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values.first ?? "missing callback")
        XCTAssertFalse(session.busy)
    }

    func testOldWindowCannotPublishIntoNewGeneration() {
        let store = DeferredAccountStore()
        let session = AccountLoginSession(store: store)
        var old: [String?] = [], current: [String?] = []
        let first = session.begin { old.append($0) }!
        session.readCookies(for: first)
        session.cancel()
        let second = session.begin { current.append($0) }!
        session.readCookies(for: second)
        store.replyCookies([cookie("sessionid", "old")])
        XCTAssertTrue(current.isEmpty)
        store.replyCookies([cookie("sessionid", "new")])
        XCTAssertEqual(current.compactMap { $0 }, ["sessionid=new"])
        XCTAssertEqual(old.count, 1)
    }

    func testBusyUntilDismissalAndClearHaveActuallyCompleted() {
        let store = DeferredAccountStore()
        let session = AccountLoginSession(store: store)
        var dismiss: (() -> Void)?
        session.closeWindow = { _, done in dismiss = done }
        var values: [String?] = []
        _ = session.begin { values.append($0) }
        XCTAssertNil(session.begin { _ in XCTFail("busy login") })
        session.cancel()
        XCTAssertTrue(values.isEmpty)
        XCTAssertNil(session.begin { _ in XCTFail("dismissing login") })
        XCTAssertFalse(session.clear { XCTFail("must not clear during dismissal") })
        dismiss?()
        XCTAssertEqual(values.count, 1)
        var cleared = false
        XCTAssertTrue(session.clear { cleared = true })
        XCTAssertNil(session.begin { _ in XCTFail("clearing login") })
        XCTAssertFalse(cleared)
        store.finishClear()
        XCTAssertTrue(cleared)
        let next = session.begin { values.append($0) }!
        session.readCookies(for: next)
        store.replyCookies([])
        XCTAssertEqual(values.count, 1)
        session.cancel()
        dismiss?()
        XCTAssertNil(values.last!)
    }

    func testHostDetachStillCompletesPendingResultAfterDismissal() {
        let store = DeferredAccountStore()
        var session: AccountLoginSession? = AccountLoginSession(store: store)
        var dismiss: (() -> Void)?
        session?.closeWindow = { _, done in dismiss = done }
        var values: [String?] = []
        _ = session?.begin { values.append($0) }
        session?.cancel()
        session = nil
        dismiss?()
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values.first!)
    }

    func testInvalidCookieLeavesWindowOpenForUserVerification() {
        let store = DeferredAccountStore()
        let session = AccountLoginSession(store: store)
        var values: [String?] = []
        var invalid = 0
        session.invalidCookie = { invalid += 1 }
        let id = session.begin { values.append($0) }!
        session.readCookies(for: id)
        session.readCookies(for: id)
        XCTAssertEqual(store.reads.count, 1)
        store.replyCookies([cookie(domain: ".evil.test")])
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(invalid, 1)
        session.readCookies(for: id)
        store.replyCookies([cookie()])
        XCTAssertEqual(values.compactMap { $0 }, ["sessionid=fixture"])
    }
}

private final class DeferredAccountStore: AccountCookieAccess {
    var reads: [([HTTPCookie]) -> Void] = []
    var clearing: (() -> Void)?
    var clearCount = 0
    func cookies(_ completion: @escaping ([HTTPCookie]) -> Void) { reads.append(completion) }
    func clear(_ completion: @escaping () -> Void) { clearCount += 1; clearing = completion }
    func replyCookies(_ values: [HTTPCookie]) { reads.removeFirst()(values) }
    func finishClear() { let done = clearing; clearing = nil; done?() }
}
