import Foundation
import Testing
@testable import RuntimeCore

struct ResourcePolicyTests {
    private let configuration = InferenceConfiguration()
    private let policy = RuntimeResourcePolicy(
        estimatedRuntimeOverheadBytes: 100, estimatedBytesPerContextToken: 2, reserveBytes: 200
    )

    @Test func loadEstimateIncludesFileContextOverheadAndUntouchedReserve() throws {
        let estimate = try policy.preflightLoad(
            model: model(bytes: 1_000), configuration: configuration,
            snapshot: .init(availableMemoryBytes: 5_396, residentMemoryBytes: 999_999)
        )
        #expect(estimate.modelFileBytes == 1_000)
        #expect(estimate.runtimeOverheadBytes == 100)
        #expect(estimate.contextOverheadBytes == 4_096)
        #expect(estimate.reserveBytes == 200)
        #expect(estimate.requiredAvailableBytes == 5_396)
        // Current resident bytes are already deducted from the available app budget.
    }

    @Test func q8FailureSuggestsExplicitVerifiedQ4ButDoesNotSelectIt() throws {
        let snapshot = RuntimeResourceSnapshot(availableMemoryBytes: 5_000, thermalState: .nominal)
        let q8 = model(bytes: 1_000, quantization: .q8_0)
        do {
            _ = try policy.preflightLoad(model: q8, configuration: configuration, snapshot: snapshot)
            Issue.record("Q8 should exceed the injected app budget.")
        } catch let error as RuntimeResourcePolicyError {
            #expect(error == .insufficientMemory(requiredBytes: 5_396, availableBytes: 5_000, quantization: .q8_0))
            #expect(error.errorDescription?.contains("Explicitly select") == true)
            #expect(error.errorDescription?.contains("separately imported and verified Q4_K_M") == true)
        }
        let q4 = model(bytes: 400, quantization: .q4_k_m)
        let estimate = try policy.preflightLoad(model: q4, configuration: configuration, snapshot: snapshot)
        #expect(estimate.requiredAvailableBytes == 4_796)
        #expect(q8.manifest.quantization == .q8_0)
        #expect(q4.manifest.quantization == .q4_k_m)
    }

    @Test func q4AlsoFailsWhenItsSeparatelyCheckedBudgetIsInsufficient() {
        #expect(throws: RuntimeResourcePolicyError.insufficientMemory(
            requiredBytes: 4_796, availableBytes: 4_795, quantization: .q4_k_m
        )) {
            try policy.preflightLoad(
                model: model(bytes: 400, quantization: .q4_k_m), configuration: configuration,
                snapshot: .init(availableMemoryBytes: 4_795)
            )
        }
    }

    @Test func unknownAvailableBudgetFailsClosedDespiteResidentMeasurements() {
        let snapshot = RuntimeResourceSnapshot(
            availableMemoryBytes: nil, residentMemoryBytes: 1, peakResidentMemoryBytes: 2,
            thermalState: .nominal
        )
        #expect(throws: RuntimeResourcePolicyError.availableMemoryUnavailable) {
            try policy.preflightLoad(model: model(), configuration: configuration, snapshot: snapshot)
        }
        #expect(throws: RuntimeResourcePolicyError.availableMemoryUnavailable) {
            try policy.preflightGeneration(configuration: configuration, snapshot: snapshot)
        }
    }

    @Test func exhaustedBudgetRemainsZeroRatherThanBecomingUnknown() {
        #expect(throws: RuntimeResourcePolicyError.insufficientMemory(
            requiredBytes: 200, availableBytes: 0, quantization: nil
        )) {
            try policy.preflightGeneration(configuration: configuration, snapshot: .init(availableMemoryBytes: 0))
        }
    }

    @Test func unsupportedHostNeverSubstitutesTotalDeviceRAM() {
        #if !canImport(Darwin)
        let snapshot = SystemRuntimeResourceMonitor().snapshot()
        #expect(snapshot.availableMemoryBytes == nil)
        #expect(snapshot.residentMemoryBytes == nil)
        #expect(snapshot.peakResidentMemoryBytes == nil)
        #expect(snapshot.thermalState == .unknown)
        #elseif os(macOS)
        #expect(SystemRuntimeResourceMonitor().snapshot().availableMemoryBytes == nil)
        #endif
    }

    @Test(arguments: [RuntimeThermalState.serious, .critical])
    func highThermalStateRejectsLoadAndGeneration(_ thermalState: RuntimeThermalState) {
        let snapshot = RuntimeResourceSnapshot(availableMemoryBytes: UInt64.max, thermalState: thermalState)
        #expect(throws: RuntimeResourcePolicyError.thermalStateProhibitsStart(thermalState)) {
            try policy.preflightLoad(model: model(), configuration: configuration, snapshot: snapshot)
        }
        #expect(throws: RuntimeResourcePolicyError.thermalStateProhibitsStart(thermalState)) {
            try policy.preflightGeneration(configuration: configuration, snapshot: snapshot)
        }
    }

    @Test(arguments: [RuntimeThermalState.nominal, .fair, .unknown])
    func acceptedThermalStatesStillRequireMemory(_ thermalState: RuntimeThermalState) throws {
        try policy.preflightGeneration(
            configuration: configuration,
            snapshot: .init(availableMemoryBytes: 200, thermalState: thermalState)
        )
    }

    @Test(arguments: [-1, 0, 127, 2_049, 32_768, Int.max])
    func nativeContextCannotExceedBenchmarkedPolicyLimit(_ contextSize: Int) {
        let configuration = InferenceConfiguration(contextSize: contextSize, maximumOutputTokens: 1)
        let snapshot = RuntimeResourceSnapshot(availableMemoryBytes: UInt64.max)
        let error = RuntimeResourcePolicyError.unsupportedContextSize(requested: contextSize, maximum: 2_048)
        #expect(throws: error) {
            try policy.preflightLoad(model: model(), configuration: configuration, snapshot: snapshot)
        }
        #expect(throws: error) {
            try policy.preflightGeneration(configuration: configuration, snapshot: snapshot)
        }
    }

    @Test func smallestSupportedContextAndConfigurationValidationAreEnforced() throws {
        let snapshot = RuntimeResourceSnapshot(availableMemoryBytes: UInt64.max)
        let estimate = try policy.preflightLoad(
            model: model(), configuration: .init(contextSize: 128, maximumOutputTokens: 1), snapshot: snapshot
        )
        #expect(estimate.contextOverheadBytes == 256)
        #expect(throws: RuntimeError.self) {
            try policy.preflightLoad(
                model: model(), configuration: .init(sampling: .init(temperature: .nan)), snapshot: snapshot
            )
        }
    }

    @Test(arguments: [Int64.min, -1, 0, 23])
    func invalidManifestSizeCannotBecomeUnsignedOrReduceBudget(_ byteCount: Int64) {
        #expect(throws: RuntimeResourcePolicyError.invalidModelByteCount(byteCount)) {
            try policy.preflightLoad(
                model: model(bytes: byteCount), configuration: configuration,
                snapshot: .init(availableMemoryBytes: UInt64.max)
            )
        }
    }

    @Test func contextMemoryMultiplicationOverflowFailsClosed() {
        let policy = RuntimeResourcePolicy(
            estimatedRuntimeOverheadBytes: 0, estimatedBytesPerContextToken: UInt64.max, reserveBytes: 1
        )
        #expect(throws: RuntimeResourcePolicyError.arithmeticOverflow) {
            try policy.preflightLoad(
                model: model(), configuration: configuration, snapshot: .init(availableMemoryBytes: UInt64.max)
            )
        }
    }

    @Test func overheadAndReserveAdditionOverflowFailClosed() {
        for policy in [
            RuntimeResourcePolicy(estimatedRuntimeOverheadBytes: UInt64.max, estimatedBytesPerContextToken: 0, reserveBytes: 0),
            RuntimeResourcePolicy(estimatedRuntimeOverheadBytes: 0, estimatedBytesPerContextToken: 0, reserveBytes: UInt64.max)
        ] {
            #expect(throws: RuntimeResourcePolicyError.arithmeticOverflow) {
                try policy.preflightLoad(
                    model: model(bytes: Int64.max), configuration: configuration,
                    snapshot: .init(availableMemoryBytes: UInt64.max)
                )
            }
        }
    }

    @Test func generationRechecksOnlyRemainingReserveAndDoesNotDoubleChargeLoadedModel() throws {
        try policy.preflightGeneration(configuration: configuration, snapshot: .init(availableMemoryBytes: 200))
        #expect(throws: RuntimeResourcePolicyError.insufficientMemory(
            requiredBytes: 200, availableBytes: 199, quantization: nil
        )) {
            try policy.preflightGeneration(configuration: configuration, snapshot: .init(availableMemoryBytes: 199))
        }
    }

    @Test func resourceSnapshotEncodingContainsMeasurementsWithoutUserContent() throws {
        let snapshot = RuntimeResourceSnapshot(
            availableMemoryBytes: 1_000, residentMemoryBytes: 2_000,
            peakResidentMemoryBytes: 3_000, thermalState: .fair
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(RuntimeResourceSnapshot.self, from: data) == snapshot)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["availableMemoryBytes", "residentMemoryBytes", "peakResidentMemoryBytes", "thermalState"])
    }

    private func model(bytes: Int64 = 1_000, quantization: ModelQuantization = .q8_0) -> ValidatedModel {
        ValidatedModel(
            fileURL: URL(fileURLWithPath: "/test-fixtures/explicit-model.gguf"),
            manifest: ModelManifest(
                id: "resource-fixture", displayName: "Resource policy fixture", quantization: quantization,
                expectedByteCount: bytes, sha256: String(repeating: "a", count: 64),
                provenance: .init(
                    sourceURL: URL(string: "https://example.invalid/model")!, revision: "fixture", license: "Test only"
                )
            )
        )
    }
}
