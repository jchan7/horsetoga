//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import AppKit
import Foundation
import Observation

/// Where license state lives. Keychain in the app so a reinstall doesn't reset
/// the trial; memory in tests.
nonisolated protocol LicenseStorage: Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String, _ account: String)
    func delete(_ account: String)
}

nonisolated struct KeychainLicenseStorage: LicenseStorage {
    func get(_ account: String) -> String? { KeychainStore.get(account: account) }
    func set(_ value: String, _ account: String) { KeychainStore.set(value, account: account) }
    func delete(_ account: String) { KeychainStore.delete(account: account) }
}

/// Debug builds only: ad-hoc signing makes every rebuild a "new app" to the
/// keychain, so a keychain-backed trial date would prompt on every launch.
nonisolated struct DefaultsLicenseStorage: LicenseStorage {
    private func key(_ account: String) -> String { "horsetoga.license.\(account)" }
    func get(_ account: String) -> String? { UserDefaults.standard.string(forKey: key(account)) }
    func set(_ value: String, _ account: String) { UserDefaults.standard.set(value, forKey: key(account)) }
    func delete(_ account: String) { UserDefaults.standard.removeObject(forKey: key(account)) }
}

extension LicenseManager {
    /// Keychain for shipped builds; UserDefaults while developing (see above).
    static func defaultStorage() -> any LicenseStorage {
        #if DEBUG
        DefaultsLicenseStorage()
        #else
        KeychainLicenseStorage()
        #endif
    }
}

/// Shape of every Lemon Squeezy license endpoint response (activate / validate /
/// deactivate share it; absent fields decode as nil).
nonisolated struct LicenseResponse: Decodable, Sendable {
    struct Key: Decodable, Sendable {
        var status: String
        var key: String
        var activationLimit: Int?
        var activationUsage: Int?
    }
    struct Instance: Decodable, Sendable {
        var id: String
        var name: String?
    }
    struct Meta: Decodable, Sendable {
        var storeId: Int
        var productId: Int
        var customerEmail: String?
    }
    var activated: Bool?
    var valid: Bool?
    var deactivated: Bool?
    var error: String?
    var licenseKey: Key?
    var instance: Instance?
    var meta: Meta?
}

/// Trial + license state machine. Local state resolves synchronously at launch
/// (no network on the critical path); the server is consulted in the background
/// at most once a day, with an offline grace window so a flaky connection never
/// locks a paying user out.
@MainActor
@Observable
final class LicenseManager {
    enum Entitlement: Equatable {
        case trial(daysLeft: Int)
        case licensed(maskedKey: String, email: String?)
        case expired
        case invalid(String)
    }

    enum Account {
        static let key = "license-key"
        static let instance = "license-instance-id"
        static let lastValidated = "license-last-validated"
        static let email = "license-email"
        static let trialStart = "license-trial-start"
    }

    private(set) var entitlement: Entitlement = .trial(daysLeft: LicenseConfig.trialDays)
    private(set) var isBusy = false
    private(set) var lastError: String?

    private let storage: any LicenseStorage
    private let session: URLSession
    private let now: () -> Date

    init(
        storage: any LicenseStorage = LicenseManager.defaultStorage(),
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.session = session
        self.now = now
    }

    var isEntitled: Bool {
        switch entitlement {
        case .trial, .licensed: true
        case .expired, .invalid: false
        }
    }

    var isLicensed: Bool {
        if case .licensed = entitlement { return true }
        return false
    }

    func start() {
        refreshLocal()
        Task { await revalidateIfDue() }
    }

    /// Resolve entitlement from stored state alone.
    func refreshLocal() {
        if let key = storage.get(Account.key) {
            let last = storage.get(Account.lastValidated).flatMap(Self.parseDate)
            let graceSeconds = TimeInterval(LicenseConfig.offlineGraceDays) * 86_400
            if let last, now().timeIntervalSince(last) <= graceSeconds {
                entitlement = .licensed(maskedKey: Self.mask(key), email: storage.get(Account.email))
            } else {
                entitlement = .invalid("license needs to be re-verified — connect to the internet")
            }
        } else {
            entitlement = trialEntitlement()
        }
    }

    private func trialEntitlement() -> Entitlement {
        let start: Date
        if let stored = storage.get(Account.trialStart).flatMap(Self.parseDate) {
            start = stored
        } else {
            start = now()
            storage.set(Self.formatDate(start), Account.trialStart)
        }
        let elapsedDays = Int(now().timeIntervalSince(start) / 86_400)
        let left = LicenseConfig.trialDays - elapsedDays
        return left > 0 ? .trial(daysLeft: left) : .expired
    }

    // MARK: - Server

    func activate(_ rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastError = "enter a license key"; return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        do {
            let instanceName = Host.current().localizedName ?? "Mac"
            let response = try await post("activate", ["license_key": key, "instance_name": instanceName])
            guard response.activated == true, let instance = response.instance else {
                lastError = response.error ?? "that key couldn't be activated"
                return
            }
            if let problem = Self.ownershipProblem(response) {
                lastError = problem
                return
            }
            storage.set(key, Account.key)
            storage.set(instance.id, Account.instance)
            storage.set(Self.formatDate(now()), Account.lastValidated)
            if let email = response.meta?.customerEmail { storage.set(email, Account.email) }
            refreshLocal()
        } catch {
            lastError = "couldn't reach the license server: \(error.localizedDescription)"
        }
    }

    func deactivate() async {
        isBusy = true
        defer { isBusy = false }
        if let key = storage.get(Account.key), let instance = storage.get(Account.instance) {
            _ = try? await post("deactivate", ["license_key": key, "instance_id": instance])
        }
        for account in [Account.key, Account.instance, Account.lastValidated, Account.email] {
            storage.delete(account)
        }
        lastError = nil
        refreshLocal()
    }

    /// Background re-check. A definitive "no" from the server clears the key;
    /// a network failure changes nothing (grace window handles it).
    func revalidateIfDue() async {
        guard let key = storage.get(Account.key), let instance = storage.get(Account.instance) else { return }
        if let last = storage.get(Account.lastValidated).flatMap(Self.parseDate),
           now().timeIntervalSince(last) < LicenseConfig.revalidateInterval {
            return
        }
        guard let response = try? await post("validate", ["license_key": key, "instance_id": instance]) else { return }
        if response.valid == true, Self.ownershipProblem(response) == nil {
            storage.set(Self.formatDate(now()), Account.lastValidated)
            refreshLocal()
        } else {
            for account in [Account.key, Account.instance, Account.lastValidated, Account.email] {
                storage.delete(account)
            }
            entitlement = .invalid(response.error ?? "license is no longer valid")
        }
    }

    private func post(_ endpoint: String, _ fields: [String: String]) async throws -> LicenseResponse {
        var request = URLRequest(url: LicenseConfig.apiBase.appending(path: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LicenseResponse.self, from: data)
    }

    // MARK: - Helpers

    /// Keys from another store/product are someone else's license.
    static func ownershipProblem(_ response: LicenseResponse) -> String? {
        guard let meta = response.meta else { return nil }
        if LicenseConfig.storeID != 0, meta.storeId != LicenseConfig.storeID { return "that key belongs to a different store" }
        if LicenseConfig.productID != 0, meta.productId != LicenseConfig.productID { return "that key is for a different product" }
        return nil
    }

    static func mask(_ key: String) -> String {
        guard key.count > 8 else { return key }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }

    private static let dateFormatter = ISO8601DateFormatter()
    static func formatDate(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func parseDate(_ string: String) -> Date? { dateFormatter.date(from: string) }
}

/// Opens the SwiftUI Settings scene from anywhere (menu-less code paths).
@MainActor
enum SettingsOpener {
    static func open() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
