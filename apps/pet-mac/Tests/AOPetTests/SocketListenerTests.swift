import XCTest
@testable import AOPet

/// End-to-end test for SocketListener: bind, connect, write, read.
final class SocketListenerTests: XCTestCase {
    func testRoundTrip() throws {
        if let err = SocketTestSupport.roundTrip() {
            XCTFail("socket round-trip: \(err)")
        }
    }
}
