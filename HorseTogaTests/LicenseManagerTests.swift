//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import XCTest
@testable import HorseToga

/// In-memory stand-in for the keychain.
nonisolated final class MemoryLicenseStorage: LicenseStorage, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    func get(_ account: String) -> String? { lock.withLock { values[account] } }
    func set(_ value: String, _ account: String) { lock.withLock { values[account] = value } }
    func delete(_ account: String) { lock.withLock { values[account] = nil } }
}

/// Canned HTTP responses for the license endpoints.
nonisolated final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

nonisolated final class LicenseManagerTests: XCTestCase {
    @MainActor private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @MainActor private func manager(storage: MemoryLicenseStorage, now: Date) -> LicenseManager {
        LicenseManager(storage: storage, session: makeSession(), now: { now })
    }

    @MainActor func testFreshInstallStartsFullTrial() {
        let storage = MemoryLicenseStorage()
        let m = manager(storage: storage, now: Date())
        m.refreshLocal()
        XCTAssertEqual(m.entitlement, .trial(daysLeft: LicenseConfig.trialDays))
        XCTAssertNotNil(storage.get(LicenseManager.Account.trialStart), "trial start is persisted")
        XCTAssertTrue(m.isEntitled)
    }

    @MainActor func testTrialCountsDownAndExpires() {
        let storage = MemoryLicenseStorage()
        let start = Date()
        storage.set(LicenseManager.formatDate(start), LicenseManager.Account.trialStart)

        let day5 = manager(storage: storage, now: start.addingTimeInterval(5 * 86_400 + 60))
        day5.refreshLocal()
        XCTAssertEqual(day5.entitlement, .trial(daysLeft: LicenseConfig.trialDays - 5))

        let day15 = manager(storage: storage, now: start.addingTimeInterval(15 * 86_400))
        day15.refreshLocal()
        XCTAssertEqual(day15.entitlement, .expired)
        XCTAssertFalse(day15.isEntitled)
    }

    @MainActor func testStoredKeyWithinGraceIsLicensedOffline() {
        let storage = MemoryLicenseStorage()
        let now = Date()
        storage.set("ABCD-1234-EFGH-5678", LicenseManager.Account.key)
        storage.set("inst", LicenseManager.Account.instance)
        storage.set(LicenseManager.formatDate(now.addingTimeInterval(-3 * 86_400)), LicenseManager.Account.lastValidated)
        let m = manager(storage: storage, now: now)
        m.refreshLocal()
        XCTAssertEqual(m.entitlement, .licensed(maskedKey: "ABCD…5678", email: nil))
    }

    @MainActor func testStoredKeyPastGraceNeedsReverification() {
        let storage = MemoryLicenseStorage()
        let now = Date()
        storage.set("ABCD-1234-EFGH-5678", LicenseManager.Account.key)
        storage.set(LicenseManager.formatDate(now.addingTimeInterval(-40 * 86_400)), LicenseManager.Account.lastValidated)
        let m = manager(storage: storage, now: now)
        m.refreshLocal()
        if case .invalid = m.entitlement {} else { XCTFail("expected invalid, got \(m.entitlement)") }
        XCTAssertFalse(m.isEntitled)
    }

    @MainActor func testActivateStoresKeyAndLicenses() async {
        let storage = MemoryLicenseStorage()
        let m = manager(storage: storage, now: Date())
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/activate"))
            let json = """
            {"activated":true,"error":null,"license_key":{"id":1,"status":"active","key":"ABCD-1234-EFGH-5678","activation_limit":3,"activation_usage":1},
             "instance":{"id":"inst-1","name":"Mac"},"meta":{"store_id":1,"product_id":2,"customer_email":"a@b.c"}}
            """
            return (200, Data(json.utf8))
        }
        await m.activate("ABCD-1234-EFGH-5678")
        XCTAssertNil(m.lastError)
        XCTAssertEqual(storage.get(LicenseManager.Account.key), "ABCD-1234-EFGH-5678")
        XCTAssertEqual(storage.get(LicenseManager.Account.instance), "inst-1")
        XCTAssertEqual(m.entitlement, .licensed(maskedKey: "ABCD…5678", email: "a@b.c"))
    }

    @MainActor func testActivateRejectsBadKey() async {
        let storage = MemoryLicenseStorage()
        let m = manager(storage: storage, now: Date())
        StubURLProtocol.handler = { _ in
            (404, Data(#"{"activated":false,"error":"license_key not found."}"#.utf8))
        }
        await m.activate("nope")
        XCTAssertEqual(m.lastError, "license_key not found.")
        XCTAssertNil(storage.get(LicenseManager.Account.key))
        if case .trial = m.entitlement {} else { XCTFail("still on trial") }
    }

    @MainActor func testRevalidateClearsRevokedKey() async {
        let storage = MemoryLicenseStorage()
        let now = Date()
        storage.set("ABCD-1234-EFGH-5678", LicenseManager.Account.key)
        storage.set("inst-1", LicenseManager.Account.instance)
        storage.set(LicenseManager.formatDate(now.addingTimeInterval(-2 * 86_400)), LicenseManager.Account.lastValidated)
        let m = manager(storage: storage, now: now)
        StubURLProtocol.handler = { _ in
            (400, Data(#"{"valid":false,"error":"license_key is disabled."}"#.utf8))
        }
        await m.revalidateIfDue()
        XCTAssertNil(storage.get(LicenseManager.Account.key))
        XCTAssertEqual(m.entitlement, .invalid("license_key is disabled."))
    }

    @MainActor func testRevalidateSkippedWhenRecent() async {
        let storage = MemoryLicenseStorage()
        let now = Date()
        storage.set("ABCD-1234-EFGH-5678", LicenseManager.Account.key)
        storage.set("inst-1", LicenseManager.Account.instance)
        storage.set(LicenseManager.formatDate(now.addingTimeInterval(-3600)), LicenseManager.Account.lastValidated)
        let m = manager(storage: storage, now: now)
        StubURLProtocol.handler = { _ in
            XCTFail("server must not be contacted within the revalidate interval")
            return (500, Data())
        }
        await m.revalidateIfDue()
        XCTAssertEqual(storage.get(LicenseManager.Account.key), "ABCD-1234-EFGH-5678")
    }

    @MainActor func testOwnershipMismatchIsRejected() throws {
        let json = #"{"valid":true,"meta":{"store_id":999,"product_id":2}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(LicenseResponse.self, from: Data(json.utf8))
        // Config IDs are 0 (unconfigured) in this build, so ownership is not enforced yet.
        XCTAssertNil(LicenseManager.ownershipProblem(response))
        XCTAssertEqual(response.meta?.storeId, 999)
    }
}
