import SwiftUI
import FrontendCore

@MainActor protocol DraftReloading: AnyObject {
    associatedtype Value: Equatable
    var configuration: CLIConfiguration { get }
    var saved: Value { get set }
    var loaded: Bool { get set }
    var loading: Bool { get set }
    var error: String? { get set }
    var pendingReload: Bool? { get set }
    func readDraft() async throws -> Value
    func applyDraft(_ value: Value, baseline: Value, preservingDraft: Bool)
}

extension DraftReloading {
    func reload(app: AppModel, preservingDraft: Bool = false) async {
        guard app.configuration == configuration else { return }
        guard !loading else { pendingReload = (pendingReload ?? true) && preservingDraft; return }
        loading = true
        defer { loading = false; pendingReload = nil }
        var preserve = preservingDraft
        repeat {
            let baseline = saved
            if error != nil { error = nil }
            do {
                let value = try await readDraft()
                guard app.configuration == configuration, !Task.isCancelled else { return }
                applyDraft(value, baseline: baseline, preservingDraft: preserve)
                if saved != value { saved = value }
                if !loaded { loaded = true }
            } catch {
                if app.configuration == configuration, !Task.isCancelled { self.error = error.localizedDescription }
            }
            guard let pending = pendingReload else { return }
            pendingReload = nil; preserve = pending
        } while !Task.isCancelled
    }
}

@MainActor final class PreparationSession: ObservableObject, DraftReloading {
    let instanceID: String
    let configuration: CLIConfiguration
    @Published var files = PreparationFiles()
    @Published var saved = PreparationFiles()
    @Published var loaded = false
    @Published var loading = false
    @Published var error: String?
    var pendingReload: Bool?
    @Published var timeoutText = "3600"
    @Published var verification = VerificationSettings()
    @Published var verificationTimeoutText = "600"
    private var savedVerification = VerificationSettings()
    private var pendingVerification: VerificationSettings?
    var dirty: Bool { files != saved || verification != savedVerification || verificationTimeoutText != String(savedVerification.timeoutSeconds) }
    var verificationTimeout: Double? {
        guard let value = Double(verificationTimeoutText), value.isFinite, value > 0 else { return nil }
        return value
    }
    init(instanceID: String, configuration: CLIConfiguration) {
        self.instanceID = instanceID; self.configuration = configuration
    }
    func readDraft() async throws -> PreparationFiles {
        let client = CLIClient(configuration)
        let files = try await PreparationFiles.read(id: instanceID, client: client)
        guard let settings = try await client.sandbox(["verification", instanceID]).reply().verificationSettings else {
            throw CLIError(ui("未返回自动验收配置", "No automatic verification settings returned"))
        }
        pendingVerification = settings
        return files
    }
    func applyDraft(_ value: PreparationFiles, baseline: PreparationFiles, preservingDraft: Bool) {
        if (!preservingDraft || files == baseline) && files != value { files = value }
        if let settings = pendingVerification {
            if !preservingDraft || verification == savedVerification { verification = settings }
            if !preservingDraft || !loaded || verificationTimeoutText == String(savedVerification.timeoutSeconds) {
                verificationTimeoutText = String(settings.timeoutSeconds)
            }
            savedVerification = settings; pendingVerification = nil
        }
    }
    func save(app: AppModel, runTimeout: Double? = nil) async throws {
        guard app.configuration == configuration else { throw CLIError(ui("连接设置已改变，请重新打开准备页。", "Connection settings changed; reopen the preparation page.")) }
        let value = files
        guard let verificationTimeout else { throw CLIError(ui("验收超时必须是正数秒数", "Verification timeout must be a positive number of seconds")) }
        var settings = verification; settings.timeoutSeconds = verificationTimeout
        _ = try await app.command(settings.arguments(id: instanceID), title: ui("保存自动验收配置", "Save Automatic Verification Settings"), client: CLIClient(configuration))
        savedVerification = settings; verification = settings; verificationTimeoutText = String(settings.timeoutSeconds)
        try await value.save { path, text in
            try await app.writeText(self.instanceID, path: path, text: text, client: CLIClient(self.configuration))
        }
        saved = value
        if let runTimeout {
            guard app.configuration == configuration else { throw CLIError(ui("连接设置已改变，尚未执行脚本。", "Connection settings changed; the script has not been executed.")) }
            try await app.submit(instanceID, argv: ["/bin/sh", "./setup.sh"], timeout: runTimeout, session: true)
        }
    }
}
