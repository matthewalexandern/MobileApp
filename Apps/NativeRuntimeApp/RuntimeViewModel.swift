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
    @Published private(set) var installedModels: [ModelManifest] = []
    @Published private(set) var resources: RuntimeResourceSnapshot?
    @Published private(set) var lastLoadDurationSeconds: Double?
    @Published private(set) var isResponding = false
    @Published private(set) var isChangingRuntime = false
    @Published private(set) var isImporting = false
    @Published private(set) var isVerifying = false
    @Published private(set) var isLoading = false
    @Published private(set) var isHandlingResourcePressure = false
    @Published var errorMessage: String?

    private let registry: ModelRegistry?
    private let registrySetupError: String?
    private let resourceMonitor = SystemRuntimeResourceMonitor()
    private var coordinator: RuntimeCoordinator?
    private var observerTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var generationID: UUID?
    private var modelOperationID: UUID?
    private var coordinatorID: UUID?
    private var isBackgrounded = false
    private var hasStarted = false

    init() {
        do {
            registry = ModelRegistry(modelsDirectory: try ModelRegistry.applicationSupportModelsDirectory())
            registrySetupError = nil
        } catch {
            registry = nil
            registrySetupError = "The private model catalog could not be opened: \(error.localizedDescription)"
        }
    }

    var isReady: Bool {
        guard let snapshot else { return false }
        if case .ready = snapshot.state { return true }
        return false
    }

    var isBusy: Bool {
        isChangingRuntime || isImporting || isVerifying || isLoading || isHandlingResourcePressure
    }

    var isGenerating: Bool {
        isResponding || snapshot?.isGenerating == true
    }

    var nativeThermalLimitReached: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        case .nominal, .fair: false
        @unknown default: false
        }
    }

    var canLoadNativeModel: Bool {
        selection == .native && importedModel != nil && !isBusy && !isGenerating && !isReady
            && !isBackgrounded && !nativeThermalLimitReached
    }

    var statusDescription: String {
        if isHandlingResourcePressure { return "Releasing resources" }
        if isVerifying { return "Verifying stored model" }
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
        return userMessage(for: error)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await selectRuntime(.demonstration)
        refreshResources()
        if let registrySetupError {
            errorMessage = registrySetupError
            return
        }
        await refreshInstalledModels()
        await restoreModelSelection()
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
            catch { errorMessage = userMessage(for: error) }
        }
    }

    func startDemonstration() async {
        guard selection == .demonstration, !isBusy, !isGenerating,
              !isBackgrounded, let coordinator else { return }
        do { try await coordinator.startDemonstration() }
        catch { errorMessage = userMessage(for: error) }
    }

    private func observe(_ coordinator: RuntimeCoordinator) async {
        let identity = UUID()
        coordinatorID = identity
        let updates = await coordinator.stateUpdates()
        snapshot = await coordinator.snapshot()
        observerTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled, self?.coordinatorID == identity else { return }
                self?.snapshot = snapshot
            }
        }
    }

    func send(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, isReady, !isBusy, !isGenerating,
              !isBackgrounded, let coordinator else { return }
        if selection == .native, nativeThermalLimitReached {
            errorMessage = "The device is too warm for native inference. Wait for it to cool, then load your selected model again."
            return
        }
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
                    self.refreshResources()
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
                // A cancelled iterator may finish without throwing. Join native teardown
                // before allowing this UI operation to release its response slot.
                try Task.checkCancellation()
            } catch {
                guard self.generationID == operationID else { return }
                if Task.isCancelled || error is CancellationError || error as? RuntimeError == .cancelled {
                    self.markCancelled(response.id)
                    // This task retains its captured coordinator and keeps isResponding
                    // true while cancellation settles, so a later send cannot be stopped.
                    await coordinator.cancelGeneration()
                } else {
                    if let index = self.messages.firstIndex(where: { $0.id == response.id }) {
                        self.messages[index].failed = true
                    }
                    self.errorMessage = self.userMessage(for: error)
                }
            }
        }
    }

    func cancelGeneration() {
        // Stream termination cancels only this generation's coordinator operation ID.
        generationTask?.cancel()
    }

    private func markCancelled(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].wasCancelled = true
    }

    func clearConversation() {
        guard !isGenerating else { return }
        messages.removeAll()
    }

    func refreshResources() {
        resources = resourceMonitor.snapshot()
    }

    func refreshInstalledModels() async {
        guard !isBusy, let registry else { return }
        do { installedModels = try await registry.installedModels() }
        catch { errorMessage = userMessage(for: error) }
    }

    private func restoreModelSelection() async {
        guard !isBusy, !isBackgrounded, let registry else { return }
        let operationID = UUID()
        modelOperationID = operationID
        isVerifying = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishModelOperation(operationID) }
            do {
                let model = try await registry.restoreSelectedModel()
                try Task.checkCancellation()
                guard self.modelOperationID == operationID else { return }
                self.importedModel = model
            } catch { self.reportModelError(error, operationID: operationID) }
        }
        verificationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func selectInstalledModel(_ manifest: ModelManifest) {
        guard !isBusy, !isGenerating, !isBackgrounded, let registry else { return }
        let operationID = UUID()
        modelOperationID = operationID
        isVerifying = true
        errorMessage = nil
        verificationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishModelOperation(operationID) }
            do {
                // A selection must never imply that a different native context is loaded.
                if self.selection == .native { await self.coordinator?.unload() }
                try Task.checkCancellation()
                let model = try await registry.verifiedModel(id: manifest.id, quantization: manifest.quantization)
                try Task.checkCancellation()
                guard self.modelOperationID == operationID else { return }
                self.importedModel = model
                self.lastLoadDurationSeconds = nil
            } catch { self.reportModelError(error, operationID: operationID) }
        }
    }

    func importModel(from url: URL, manifest: ModelManifest) {
        guard !isBusy, !isGenerating, !isBackgrounded, let registry else { return }
        let operationID = UUID()
        modelOperationID = operationID
        isImporting = true
        errorMessage = nil
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishModelOperation(operationID) }
            do {
                if self.selection == .native { await self.coordinator?.unload() }
                try Task.checkCancellation()
                let model = try await registry.importModel(from: url, manifest: manifest)
                try Task.checkCancellation()
                guard self.modelOperationID == operationID else { return }
                let installed = try await registry.installedModels()
                try Task.checkCancellation()
                guard self.modelOperationID == operationID else { return }
                self.importedModel = model
                self.installedModels = installed
                self.lastLoadDurationSeconds = nil
            } catch { self.reportModelError(error, operationID: operationID) }
        }
    }

    func loadImportedModel() async {
        guard selection == .native, !isBusy, !isGenerating, !isReady,
              !isBackgrounded, let importedModel, let coordinator, let registry else { return }
        refreshResources()
        guard !nativeThermalLimitReached else {
            errorMessage = "The device is too warm to load a native model. Wait for thermal state to recover, then retry explicitly."
            return
        }
        let operationID = UUID()
        modelOperationID = operationID
        isVerifying = true
        lastLoadDurationSeconds = nil
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishModelOperation(operationID) }
            do {
                let model = try await registry.verifiedModel(
                    id: importedModel.manifest.id,
                    quantization: importedModel.manifest.quantization
                )
                try Task.checkCancellation()
                guard self.modelOperationID == operationID else { return }
                self.importedModel = model
                guard !self.isBackgrounded, !self.nativeThermalLimitReached else {
                    throw RuntimeError.resourceLimit(reason: "Native loading stopped because the app backgrounded or the device became too warm.")
                }
                self.isVerifying = false
                self.isLoading = true
                let clock = ContinuousClock()
                let start = clock.now
                try await coordinator.load(model: model)
                try Task.checkCancellation()
                guard self.modelOperationID == operationID else { return }
                let elapsed = start.duration(to: clock.now).components
                self.lastLoadDurationSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
            } catch { self.reportModelError(error, operationID: operationID) }
        }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelModelPreparation() {
        importTask?.cancel()
        verificationTask?.cancel()
        loadTask?.cancel()
    }

    private func finishModelOperation(_ operationID: UUID) {
        guard modelOperationID == operationID else { return }
        modelOperationID = nil
        isImporting = false
        isVerifying = false
        isLoading = false
        importTask = nil
        verificationTask = nil
        loadTask = nil
        refreshResources()
    }

    private func reportModelError(_ error: Error, operationID: UUID) {
        guard modelOperationID == operationID, !Task.isCancelled,
              !(error is CancellationError), error as? RuntimeError != .cancelled else { return }
        errorMessage = userMessage(for: error)
    }

    private func userMessage(for error: Error) -> String {
        if let runtimeError = error as? RuntimeError, case .resourceLimit = runtimeError {
            return "\(error.localizedDescription) Select a separately reviewed Q4_K_M import or a smaller compatible model if memory is insufficient. Quantization never changes automatically."
        }
        return error.localizedDescription
    }

    func unloadModel() async {
        guard !isBusy, let coordinator else { return }
        cancelGeneration()
        await coordinator.unload()
        refreshResources()
    }

    func handleMemoryWarning() async {
        await releaseResources(message: "iOS reported memory pressure. The runtime was unloaded and model preparation was cancelled. Review available memory before explicitly loading again; a reviewed Q4_K_M import may use less memory.")
    }

    func handleThermalStateChange() async {
        refreshResources()
        guard nativeThermalLimitReached else { return }
        await releaseResources(message: "The device reached a serious or critical thermal state. Native inference is blocked until it cools; reload your selected model explicitly after recovery.")
    }

    private func releaseResources(message: String) async {
        guard !isHandlingResourcePressure else { return }
        isHandlingResourcePressure = true
        defer { isHandlingResourcePressure = false }
        cancelGeneration()
        cancelModelPreparation()
        await coordinator?.unload()
        refreshResources()
        errorMessage = message
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            isBackgrounded = true
            cancelGeneration()
            cancelModelPreparation()
            await coordinator?.didEnterBackground()
            refreshResources()
        case .active:
            isBackgrounded = false
            await coordinator?.didBecomeActive()
            refreshResources()
            if nativeThermalLimitReached { await handleThermalStateChange() }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
