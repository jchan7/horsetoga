//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Observation

nonisolated enum ProviderSetupRequirement: Equatable, Sendable {
    case claude(executablePath: String)
    case terminal(providerID: ProviderID, providerName: String, command: String)
    case apiKey(providerID: ProviderID)
}

@MainActor
@Observable
final class ProviderRegistry {
    private(set) var providers: [any ChatProvider] = []
    var defaultProviderID: ProviderID = .claudeCLI

    /// Preflight results, refreshed at launch and on demand; drives picker states.
    private(set) var health: [ProviderID: Result<Void, ProviderError>] = [:]

    /// User-editable roster: same shape as the built-ins; an entry with a
    /// built-in id overrides it, a new id adds an agent. Any CLI, no rebuild.
    static var userConfigURL: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/com.jasonchan.horsetoga/providers.json")
    }

    init() {
        var configs = SubprocessProviderConfig.builtIns
        for user in Self.loadUserConfigs() {
            if let index = configs.firstIndex(where: { $0.id == user.id }) {
                configs[index] = user
            } else {
                configs.append(user)
            }
        }
        providers = configs.map { SubprocessProvider(config: $0) } + [
            AnthropicHTTPProvider(),
            OpenAICompatibleProvider.openAI,
            OpenAICompatibleProvider.xAI,
            GeminiHTTPProvider(),
            OpenAICompatibleProvider.mistral,
            OpenAICompatibleProvider.kimi,
            OpenAICompatibleProvider.localLMStudio,
        ]
        Self.writeExampleIfMissing()
    }

    private static func loadUserConfigs() -> [SubprocessProviderConfig] {
        guard let data = try? Data(contentsOf: userConfigURL) else { return [] }
        do {
            return try JSONDecoder().decode([SubprocessProviderConfig].self, from: data)
        } catch {
            NSLog("HorseToga: providers.json ignored: \(error)")
            return []
        }
    }

    /// providers.example.json next to the real file: copy, rename, edit.
    private static func writeExampleIfMissing() {
        let example = userConfigURL.deletingLastPathComponent().appending(path: "providers.example.json")
        guard !FileManager.default.fileExists(atPath: example.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SubprocessProviderConfig.builtIns) else { return }
        try? FileManager.default.createDirectory(at: example.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: example)
    }

    func provider(_ id: ProviderID) -> (any ChatProvider)? {
        providers.first { $0.id == id }
    }

    /// The action needed before a newly selected provider can accept a prompt.
    /// Returning nil means selection can proceed without interrupting the chat.
    /// Pass `probing: false` from view bodies: it answers from cached probe
    /// results instead of launching each CLI's `--version` on the main thread.
    func setupRequirement(for id: ProviderID, force: Bool = false, probing: Bool = true) -> ProviderSetupRequirement? {
        guard let provider = provider(id) else { return nil }

        if let keyed = provider as? any KeyBackedProvider {
            guard keyed.requiresKey else { return nil } // local servers need no key
            let hasKey = KeychainStore.get(account: keyed.keychainAccount)?.isEmpty == false
            return hasKey && !force ? nil : .apiKey(providerID: id)
        }

        guard let subprocess = provider as? SubprocessProvider else { return nil }
        let runnablePath = probing ? subprocess.runnableExecutablePath : subprocess.knownRunnableExecutablePath
        let storedAPIKey = subprocess.config.apiKeyCredential.flatMap {
            KeychainStore.get(account: $0.keychainAccount)
        }
        let hasAPIKey = storedAPIKey?.isEmpty == false
        if !force, (ProviderAccountInfo.isSignedIn(id) || hasAPIKey),
           runnablePath != nil {
            return nil
        }

        if id == .claudeCLI, let path = runnablePath {
            return .claude(executablePath: path)
        }

        let command: String?
        if let path = runnablePath {
            command = subprocess.config.accountSignInCommand(executablePath: path)
        } else if hasAPIKey && !force {
            // The key will be injected from the Keychain when the CLI runs; an
            // installer must never receive the secret through a shell command.
            command = subprocess.config.installCommand
        } else {
            command = subprocess.config.installAndAccountSetupCommand
        }
        guard let command, !command.isEmpty else { return nil }
        return .terminal(
            providerID: id,
            providerName: subprocess.displayName,
            command: command
        )
    }

    /// Selection uses the provider's own status command where available so a
    /// stale credential file/keychain item cannot suppress a required login.
    func verifiedSetupRequirement(
        for id: ProviderID,
        force: Bool = false
    ) async -> ProviderSetupRequirement? {
        if force { return setupRequirement(for: id, force: true) }
        guard let provider = provider(id) else { return nil }
        if let keyed = provider as? any KeyBackedProvider {
            guard keyed.requiresKey else { return nil } // local servers need no key
            let hasKey = KeychainStore.get(account: keyed.keychainAccount)?.isEmpty == false
            return hasKey ? nil : .apiKey(providerID: id)
        }
        guard let subprocess = provider as? SubprocessProvider else { return nil }
        if let credential = subprocess.config.apiKeyCredential,
           let apiKey = KeychainStore.get(account: credential.keychainAccount),
           !apiKey.isEmpty,
           subprocess.runnableExecutablePath != nil {
            return nil
        }
        if await ProviderAccountInfo.isVerifiedSignedIn(subprocess) { return nil }
        return setupRequirement(for: id, force: true)
    }

    var defaultProvider: (any ChatProvider)? {
        provider(defaultProviderID) ?? providers.first
    }

    func refreshHealth() async {
        await warmExecutableProbes()
        for provider in providers {
            do {
                try await provider.preflight()
                health[provider.id] = .success(())
            } catch let error as ProviderError {
                health[provider.id] = .failure(error)
            } catch {
                health[provider.id] = .failure(.notConfigured("\(error)"))
            }
        }
    }

    /// Probe every CLI's `--version` concurrently, off the main actor, so the
    /// shared probe cache is warm within a few seconds of launch. Sequentially
    /// that can take ~3 s per CLI, and anything still unprobed when the agent
    /// picker first opens would otherwise be probed on the main thread.
    private func warmExecutableProbes() async {
        let configs = providers.compactMap { ($0 as? SubprocessProvider)?.config }
        await withTaskGroup(of: Void.self) { group in
            for config in configs {
                group.addTask { _ = SubprocessProvider(config: config).runnableExecutablePath }
            }
        }
    }
}
