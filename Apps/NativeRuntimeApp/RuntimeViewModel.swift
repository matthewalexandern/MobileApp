import Foundation
import LlamaCppAdapter
import RuntimeCore
import SwiftUI

enum RuntimeSelection: String, CaseIterable, Identifiable {
    case demonstration
    case native

    var id: Self { self }

    var title: String {
        switch self {
        case .demonstration: "Demonstration"
        case .native: "Native adapter"
        }
    }
}

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var origin: RuntimeSelection = .demonstration
    var wasCancelled = false
    var failed = false
}

@MainActor
final class RuntimeViewModel: ObservableObject {
    @Published private(set) var selection: RuntimeSelection = .demonstration
    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var importedModel: ValidatedModel?
    @Published private(set) var isResponding = false
    @Published private(set) var isChangingRuntime = false
    @Published private(set) var isImporting = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var coordinator: RuntimeCoordinator?
    private var observerTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var generationID: UUID?
    private var isBackgrounded = false

    var isReady: Bool {
        guard let snapshot else { return false }
        if case .ready = snapshot.state { return true }
        return false
    }

    var isBusy: Bool { isChangingRuntime || isImporting || isLoading }

    var statusDescription: String {
        guard let snapshot else { return "Starting" }
        if snapshot.isGenerating { return "Generating" }
        switch snapshot.state {
        case .uninstalled: return "No model loaded"
        case .downloading: return "Downloading"
        case .validating: return "Validating model"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .unloading: return "Unloading"
        case .failed: return "Unavailable"
        }
    }

    var failureDescription: String? {
        guard let snapshot, case let .failed(error) = snapshot.state else { return nil }
        return error.localizedDescription
    }

    func start() async {
        guard coordinator == nil else { return }
        await selectRuntime(.demonstration)
    }

    func selectRuntime(_ selection: RuntimeSelection) async {
        guard !isBusy else { return }
        isChangingRuntime = true
        defer { isChangingRuntime = false }
        cancelGeneration()
        if let coordinator { await coordinator.unload() }
        observerTask?.cancel()

        self.selection = selection
        errorMessage = nil
        let newCoordinator: RuntimeCoordinator
        switch selection {
        case .demonstration:
            newCoordinator = RuntimeCoordinator(engine: MockInferenceEngine())
        case .native:
            newCoordinator = RuntimeCoordinator(engine: LlamaCppInferenceEngine())
        }
        coordinator = newCoordinator
        await observe(newCoordinator)
        if isBackgrounded {
            await newCoordinator.didEnterBackground()
        } else if selection == .demonstration {
            do { try await newCoordinator.startDemonstration() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func startDemonstration() async {
        guard selection == .demonstration, !isBusy, !isResponding,
              !isBackgrounded, let coordinator else { return }
        do { try await coordinator.startDemonstration() }
        catch { errorMessage = error.localizedDescription }
    }

    private func observe(_ coordinator: RuntimeCoordinator) async {
        let updates = await coordinator.stateUpdates()
        snapshot = await coordinator.snapshot()
        observerTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
            }
        }
    }

    func send(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, isReady, !isBusy, !isResponding,
              !isBackgrounded, let coordinator else { return }
        guard prompt.utf8.count <= 16_384 else {
            errorMessage = "Keep the message below 16 KB for this initial runtime."
            return
        }

        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: prompt, origin: selection))
        let response = ChatMessage(role: .assistant, text: "", origin: selection)
        messages.append(response)
        let operationID = UUID()
        generationID = operationID
        isResponding = true
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generationID == operationID {
                    if Task.isCancelled { self.markCancelled(response.id) }
                    self.isResponding = false
                    self.generationTask = nil
                    self.generationID = nil
                }
            }
            do {
                let stream = try await coordinator.generate(request: InferenceRequest(prompt: prompt))
                for try await event in stream {
                    try Task.checkCancellation()
                    guard self.generationID == operationID else { return }
                    if case let .token(token) = event,
                       let index = self.messages.firstIndex(where: { $0.id == response.id }) {
                        self.messages[index].text.append(token)
                    }
                }
            } catch {
                guard self.generationID == operationID else { return }
                if Task.isCancelled || error is CancellationError {
                    self.markCancelled(response.id)
                } else {
                    if let index = self.messages.firstIndex(where: { $0.id == response.id }) {
                        self.messages[index].failed = true
                    }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelGeneration() {
        // Stream termination cancels only this generation's coordinator operation ID.
        // An unstructured actor-wide cancellation could race a subsequent request.
        generationTask?.cancel()
    }

    private func markCancelled(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].wasCancelled = true
    }

    func clearConversation() {
        guard !isResponding else { return }
        messages.removeAll()
    }

    func importModel(from url: URL, manifest: ModelManifest) {
        guard !isBusy, !isResponding else { return }
        isImporting = true
        errorMessage = nil
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isImporting = false
                self.importTask = nil
            }
            do {
                let applicationSupport = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let importer = ModelImporter(
                    modelsDirectory: applicationSupport.appendingPathComponent("Models", isDirectory: true)
                )
                let model = try await importer.importModel(from: url, manifest: manifest)
                try Task.checkCancellation()
                self.importedModel = model
            } catch {
                if !(error is CancellationError), !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func loadImportedModel() async {
        guard selection == .native, !isBusy, !isResponding,
              !isBackgrounded, let importedModel, let coordinator else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { try await coordinator.load(model: importedModel) }
        catch { errorMessage = error.localizedDescription }
    }

    func unloadModel() async {
        guard !isBusy, let coordinator else { return }
        cancelGeneration()
        await coordinator.unload()
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        guard let coordinator else {
            isBackgrounded = phase == .background
            return
        }
        switch phase {
        case .background:
            isBackgrounded = true
            cancelGeneration()
            importTask?.cancel()
            await coordinator.didEnterBackground()
        case .active:
            isBackgrounded = false
            await coordinator.didBecomeActive()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
