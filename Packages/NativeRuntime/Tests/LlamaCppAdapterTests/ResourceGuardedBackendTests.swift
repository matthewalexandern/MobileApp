import Foundation
import Testing
import RuntimeCore
@testable import LlamaCppAdapter

struct ResourceGuardedBackendTests {
    @Test func insufficientAppBudgetNeverCallsNativeLoaderAndRetainsQ4Guidance() async throws {
        let backend = ResourceFixtureBackend()
        let guarded = ResourceGuardedLlamaCppBackend(backend: backend, monitor: FixedResourceMonitor(snapshotValue: .init(availableMemoryBytes: 1)))
        let runtime = RuntimeCoordinator(engine: LlamaCppInferenceEngine(backend: guarded))
        do {
            try await runtime.load(model: fixture())
            Issue.record("Load must refuse the insufficient app budget")
        } catch let RuntimeError.resourceLimit(reason) {
            #expect(reason.contains("Q4_K_M"))
        }
        #expect(await backend.loads == 0)
        if case .failed(.resourceLimit) = (await runtime.snapshot()).state {} else {
            Issue.record("Admission failure must remain a structured resource error")
        }
    }

    @Test func missingBudgetFailsClosedAndHealthyBudgetForwardsLoad() async throws {
        let refused = ResourceFixtureBackend()
        let unavailable = ResourceGuardedLlamaCppBackend(backend: refused, monitor: FixedResourceMonitor(snapshotValue: .init(availableMemoryBytes: nil)))
        await #expect(throws: RuntimeError.self) {
            try await unavailable.load(model: fixture(), configuration: .init(), acceleration: .metal)
        }
        #expect(await refused.loads == 0)
        let accepted = ResourceFixtureBackend()
        let healthy = ResourceGuardedLlamaCppBackend(backend: accepted, monitor: FixedResourceMonitor(snapshotValue: .init(availableMemoryBytes: UInt64.max, thermalState: .nominal)))
        try await healthy.load(model: fixture(), configuration: .init(), acceleration: .metal)
        #expect(await accepted.loads == 1)
        await healthy.unload()
        await #expect(throws: RuntimeError.self) {
            _ = try await healthy.generate(request: .init(prompt: "fixture"), generationID: UUID())
        }
    }

    @Test func freshThermalObservationRefusesGenerationBeforeDecode() async throws {
        let backend = ResourceFixtureBackend()
        let monitor = ChangingResourceMonitor()
        let guarded = ResourceGuardedLlamaCppBackend(backend: backend, monitor: monitor)
        try await guarded.load(model: fixture(), configuration: .init(), acceleration: .metal)
        await #expect(throws: RuntimeError.self) {
            _ = try await guarded.generate(request: .init(prompt: "fixture"), generationID: UUID())
        }
        #expect(await backend.generations == 0)
        let id = UUID()
        await guarded.cancelGeneration(generationID: id)
        #expect(await backend.cancelledID == id)
        await guarded.unload()
    }

    private func fixture() -> ValidatedModel {
        .init(fileURL: URL(fileURLWithPath: "/fixtures/reviewed.gguf"), manifest: .init(
            id: "fixture", displayName: "Synthetic fixture", quantization: .q8_0,
            expectedByteCount: 96, sha256: String(repeating: "a", count: 64),
            provenance: .init(sourceURL: URL(string: "https://example.invalid/fixture")!, revision: "fixture", license: "Test only")
        ))
    }
}

private struct FixedResourceMonitor: RuntimeResourceMonitor {
    let snapshotValue: RuntimeResourceSnapshot
    func snapshot() -> RuntimeResourceSnapshot { snapshotValue }
}

private final class ChangingResourceMonitor: RuntimeResourceMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var sampled = false
    func snapshot() -> RuntimeResourceSnapshot {
        lock.withLock {
            defer { sampled = true }
            return .init(availableMemoryBytes: UInt64.max, thermalState: sampled ? .serious : .nominal)
        }
    }
}

private actor ResourceFixtureBackend: LlamaCppBackend {
    private(set) var loads = 0
    private(set) var generations = 0
    private(set) var cancelledID: UUID?
    func load(model: ValidatedModel, configuration: InferenceConfiguration, acceleration: LlamaCppAcceleration) async throws { loads += 1 }
    func unload() async {}
    func generate(request: InferenceRequest, generationID: UUID) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        generations += 1
        return AsyncThrowingStream { $0.finish() }
    }
    func cancelGeneration(generationID: UUID) async { cancelledID = generationID }
}
