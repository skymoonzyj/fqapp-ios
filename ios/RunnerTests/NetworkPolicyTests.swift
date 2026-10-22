import Foundation
import Network
import XCTest

final class NetworkPolicyTests: XCTestCase {
    func testURLSessionPermitsOnlyConfiguredLoopbackHTTP() throws {
        let ready = expectation(description: "loopback listener ready")
        let received = expectation(description: "URLSession loopback response")
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "fqapp.test.loopback")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/fixture"))
        let task = URLSession.shared.dataTask(with: url) { bytes, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(bytes, Data("ok".utf8))
            received.fulfill()
        }
        task.resume()
        defer { task.cancel() }
        wait(for: [received], timeout: 10)
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertNil(ats["NSAllowsArbitraryLoads"])
        XCTAssertNil(ats["NSAllowsArbitraryLoadsForMedia"])
        let exceptions = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: Any])
        XCTAssertEqual(Set(exceptions.keys), ["127.0.0.1"])
    }
}
