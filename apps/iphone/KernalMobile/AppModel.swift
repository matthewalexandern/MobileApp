import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Mode: Equatable { case welcome, local, preview }

    @Published private(set) var mode: Mode = .welcome
    @Published private(set) var status: Status?
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var memories: [MemoryItem] = []
    @Published private(set) var memoryStatus: String?
    @Published private(set) var isWorking = false
    @Published private(set) var operationLabel = ""
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var draftText = ""
    @Published var memoryEnabled = true

    private var runtime: OfflineRuntime?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var restored = false
    private var restoredModel = false
    private var pendingTurn: PendingTurn?

    private struct PendingTurn {
        let session: String
        let text: String
        let memoryEnabled: Bool
        let request: String
    }

    var isWorkspaceOpen: Bool { mode != .welcome }
    var isPreview: Bool { mode == .preview }
    var canAct: Bool { mode == .local && !isWorking }
    var modelLoaded: Bool { !isPreview && supports("chat") }
    var selectedSession: ChatSession? { sessions.first { $0.id == selectedSessionID } }
    func supports(_ capability: String) -> Bool { status?.capabilities.contains(capability) == true }

    func restoreOnce() {
        guard !restored else { return }
        restored = true
        openWorkspace(enter: false)
    }

    func openWorkspace(enter: Bool = true) {
        run("Opening your private workspace…") { [self] id in
            let local = try localRuntime()
            if !restoredModel {
                restoredModel = true
                do { try await local.restoreModel() }
                catch {
                    try ensureCurrent(id)
                    notice = "The saved model could not be loaded. Import a compatible model to chat; your local data is still available."
                }
                try ensureCurrent(id)
            }
            try await loadWorkspace(local, operation: id)
            if enter || supports("chat") { mode = .local }
        }
    }

    func importModel(from url: URL) {
        guard !isPreview else { return }
        run("Importing and loading local model…") { [self] id in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let local = try localRuntime()
            do { try await local.importModel(from: url) }
            catch {
                try ensureCurrent(id)
                // A failed replacement may have released the previous model.
                // Keep capability controls aligned with the runtime's real state.
                let current = await local.status()
                try ensureCurrent(id)
                status = current
                throw error
            }
            try ensureCurrent(id)
            try await loadWorkspace(local, operation: id)
            mode = .local
            notice = "Model loaded on this iPhone. Chats and memory stay on this device."
        }
    }

    func unloadModel() {
        guard let runtime, canAct else { return }
        run("Unloading local model…") { [self] id in
            try await runtime.unloadModel()
            try ensureCurrent(id)
            let current = try await runtime.status()
            try ensureCurrent(id)
            status = current
            notice = "Model unloaded. Your local chats and memories remain available."
        }
    }

    func reloadModel() {
        guard let runtime, canAct, !modelLoaded else { return }
        run("Loading imported model…") { [self] id in
            try await runtime.restoreModel()
            try ensureCurrent(id)
            try await loadWorkspace(runtime, operation: id)
            notice = modelLoaded ? "Your imported model is loaded locally." : "Import a compatible GGUF model first."
        }
    }

    private func localRuntime() throws -> OfflineRuntime {
        if let runtime { return runtime }
        let local = try OfflineRuntime()
        runtime = local
        return local
    }

    private func loadWorkspace(_ local: OfflineRuntime, operation id: UUID) async throws {
        let current = try await local.status()
        try ensureCurrent(id)
        let existing = try await local.listSessions()
        try ensureCurrent(id)
        let initialID = selectedSessionID.flatMap { selected in existing.contains(where: { $0.id == selected }) ? selected : nil } ?? existing.first?.id
        let existingMessages: [ChatMessage]
        if let initialID {
            existingMessages = try await local.messages(sessionID: initialID)
            try ensureCurrent(id)
        } else { existingMessages = [] }
        status = current
        sessions = existing
        selectedSessionID = initialID
        messages = existingMessages
    }

    func refreshSessions() {
        guard let runtime, canAct else { return }
        run("Loading local chats…") { [self] id in
            let result = try await runtime.listSessions()
            try ensureCurrent(id)
            sessions = result
            if let selectedSessionID, !result.contains(where: { $0.id == selectedSessionID }) {
                clearSessionState()
                self.selectedSessionID = nil
            }
        }
    }

    func createSession(title: String) {
        guard let runtime, canAct else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 256 else {
            errorMessage = "Use a chat title between 1 and 256 UTF-8 bytes."
            return
        }
        run("Creating local chat…") { [self] id in
            let session = try await runtime.createSession(title: title)
            try ensureCurrent(id)
            clearSessionState()
            sessions.append(session)
            selectedSessionID = session.id
        }
    }

    func selectSession(_ session: ChatSession) {
        guard session.id != selectedSessionID else { return }
        invalidateOperation()
        clearSessionState()
        selectedSessionID = session.id
        guard mode == .local else { return }
        refreshMessages()
    }

    func refreshMessages() {
        guard let runtime, let session = selectedSessionID, canAct else { return }
        run("Loading local chat…") { [self] id in
            let result = try await runtime.messages(sessionID: session)
            try ensureCurrent(id)
            messages = result
        }
    }

    func sendMessage() {
        guard let runtime, let session = selectedSessionID, canAct, modelLoaded else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 65_536 else {
            errorMessage = "Write a message up to 65,536 UTF-8 bytes."
            return
        }
        let pending: PendingTurn
        if let prior = pendingTurn, prior.session == session, prior.text == text, prior.memoryEnabled == memoryEnabled {
            pending = prior
        } else {
            pending = PendingTurn(session: session, text: text, memoryEnabled: memoryEnabled, request: UUID().uuidString)
            pendingTurn = pending
        }
        run("Thinking on this iPhone…") { [self] id in
            let turn = try await runtime.sendMessage(sessionID: session, requestID: pending.request,
                text: pending.text, memoryEnabled: pending.memoryEnabled)
            try ensureCurrent(id)
            for message in [turn.user, turn.assistant] {
                if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
                else { messages.append(message) }
            }
            memoryStatus = turn.memoryStatus
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text { draftText = "" }
            pendingTurn = nil
        }
    }

    func searchMemory(_ query: String) {
        guard let runtime, let session = selectedSessionID, canAct, supports("memory") else { return }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 512 else {
            errorMessage = "Enter a memory search up to 512 UTF-8 bytes."
            return
        }
        run("Searching device memory…") { [self] id in
            let result = try await runtime.searchMemory(sessionID: session, query: query)
            try ensureCurrent(id)
            memories = result
        }
    }

    func forget(_ memory: MemoryItem) {
        guard let runtime, let session = selectedSessionID, canAct, supports("memory"), memory.canForget else { return }
        run("Forgetting memory…") { [self] id in
            try await runtime.forgetMemory(sessionID: session, memoryID: memory.id)
            try ensureCurrent(id)
            memories.removeAll { $0.id == memory.id }
            notice = "Forgotten for future recall on this device. Existing backups may still contain this memory."
        }
    }

    func cancel() {
        guard isWorking else { return }
        invalidateOperation()
        notice = "Request canceled. Refresh the chat to check whether a turn was saved."
    }

    func enterPreview() {
        invalidateOperation()
        clearSessionState()
        status = PreviewData.status
        sessions = PreviewData.sessions
        selectedSessionID = sessions.first?.id
        messages = PreviewData.messages
        memories = PreviewData.memories
        memoryStatus = "complete"
        mode = .preview
    }

    func exitPreview() {
        invalidateOperation()
        clearSessionState()
        status = nil
        sessions = []
        selectedSessionID = nil
        mode = .welcome
        openWorkspace()
    }

    private func run(_ label: String, action: @escaping @MainActor (UUID) async throws -> Void) {
        invalidateOperation()
        let id = operationID
        isWorking = true
        operationLabel = label
        errorMessage = nil
        notice = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await action(id) }
            catch {
                guard self.operationID == id else { return }
                if !(error is CancellationError) { self.errorMessage = self.safeDescription(error) }
            }
            guard self.operationID == id else { return }
            self.isWorking = false
            self.operationLabel = ""
            self.operation = nil
        }
    }

    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }

    private func invalidateOperation() {
        operation?.cancel()
        operation = nil
        operationID = UUID()
        isWorking = false
        operationLabel = ""
    }

    private func clearSessionState() {
        messages = []
        memories = []
        memoryStatus = nil
        pendingTurn = nil
        draftText = ""
        notice = nil
    }

    private func safeDescription(_ error: Error) -> String {
        if let local = error as? OfflineError, let description = local.errorDescription { return description }
        if let storage = error as? LocalStoreError, let description = storage.errorDescription { return description }
        return "The local operation could not be completed. Try a smaller compatible model or reopen your workspace."
    }
}

private enum PreviewData {
    // Fixed fixtures only. No model generation or networking takes place in Preview.
    static let status: Status? = decode("""
    {"api_version":"1","user_display_name":"This iPhone","model_name":"Preview model","native_context_target":2048,"capabilities":["chat","memory"]}
    """)
    static let sessions: [ChatSession] = decode("""
    [{"id":"preview-chat","title":"Your private coding assistant","created_at":"2026-10-16T12:00:00Z"}]
    """) ?? []
    static let messages: [ChatMessage] = decode("""
    [{"id":"preview-user","role":"user","text":"I prefer Go for server projects.","created_at":"2026-10-16T12:00:00Z"},{"id":"preview-assistant","role":"assistant","text":"This is a fixed preview conversation. Import a compatible GGUF model for real generation on this iPhone.","created_at":"2026-10-16T12:00:01Z"}]
    """) ?? []
    static let memories: [MemoryItem] = decode("""
    [{"id":"chat:preview","kind":"semantic","title":"Server language preference","body":"Sample private memory: the owner prefers Go for server projects.","origin":"private","source_url":"","updated_at":"2026-10-16T12:00:01Z","can_forget":true}]
    """) ?? []
    private static func decode<T: Decodable>(_ text: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: Data(text.utf8))
    }
}
