import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum RuntimeThermalState: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// Resource observations contain process measurements only, never prompts, output, or file paths.
/// Available memory is the current app's remaining budget; total device RAM is not a substitute.
/// Resident values are bytes of resident process memory, not a claim about dirty-memory footprint.
public struct RuntimeResourceSnapshot: Codable, Sendable, Equatable {
    public let availableMemoryBytes: UInt64?
    public let residentMemoryBytes: UInt64?
    public let peakResidentMemoryBytes: UInt64?
    public let thermalState: RuntimeThermalState

    public init(
        availableMemoryBytes: UInt64?,
        residentMemoryBytes: UInt64? = nil,
        peakResidentMemoryBytes: UInt64? = nil,
        thermalState: RuntimeThermalState = .unknown
    ) {
        self.availableMemoryBytes = availableMemoryBytes
        self.residentMemoryBytes = residentMemoryBytes
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.thermalState = thermalState
    }
}

/// Take a fresh synchronous snapshot immediately before admission; budgets can change at any time.
public protocol RuntimeResourceMonitor: Sendable {
    func snapshot() -> RuntimeResourceSnapshot
}

public struct SystemRuntimeResourceMonitor: RuntimeResourceMonitor {
    public init() {}

    public func snapshot() -> RuntimeResourceSnapshot {
        #if canImport(Darwin)
        let resident = residentMemory()
        let thermalState: RuntimeThermalState
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = .nominal
        case .fair: thermalState = .fair
        case .serious: thermalState = .serious
        case .critical: thermalState = .critical
        @unknown default: thermalState = .unknown
        }
        #if os(iOS)
        // Darwin.os.proc: iOS 13+. Returns remaining dirty-memory budget for this process.
        // Zero represents an exhausted budget and must not be replaced with physicalMemory.
        let availableMemoryBytes: UInt64? = UInt64(os_proc_available_memory())
        #else
        // os_proc_available_memory is unavailable on macOS. Do not substitute system free RAM.
        let availableMemoryBytes: UInt64? = nil
        #endif
        return RuntimeResourceSnapshot(
            availableMemoryBytes: availableMemoryBytes,
            residentMemoryBytes: resident.current,
            peakResidentMemoryBytes: resident.peak,
            thermalState: thermalState
        )
        #else
        // Portable tests inject a snapshot. Unsupported hosts provide no invented app budget.
        return RuntimeResourceSnapshot(availableMemoryBytes: nil)
        #endif
    }

    #if canImport(Darwin)
    private func residentMemory() -> (current: UInt64?, peak: UInt64?) {
        // MACH_TASK_BASIC_INFO explicitly reports resident_size and resident_size_max in bytes.
        var information = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { words in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, nil) }
        return (UInt64(information.resident_size), UInt64(information.resident_size_max))
    }
    #endif
}

/// Estimated incremental memory needed before model load, including an untouched reserve.
/// A passing estimate neither guarantees allocation success nor prevents iOS jetsam termination.
public struct RuntimeMemoryEstimate: Sendable, Equatable {
    public let modelFileBytes: UInt64
    public let runtimeOverheadBytes: UInt64
    public let contextOverheadBytes: UInt64
    public let reserveBytes: UInt64
    public let requiredAvailableBytes: UInt64
}

public enum RuntimeResourcePolicyError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedContextSize(requested: Int, maximum: Int)
    case invalidModelByteCount(Int64)
    case arithmeticOverflow
    case availableMemoryUnavailable
    case insufficientMemory(requiredBytes: UInt64, availableBytes: UInt64, quantization: ModelQuantization?)
    case thermalStateProhibitsStart(RuntimeThermalState)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContextSize(let requested, let maximum):
            return "Context size \(requested) is unsupported for native inference. Choose 128–\(maximum) tokens until longer contexts are benchmarked on a physical iPhone."
        case .invalidModelByteCount:
            return "The verified model manifest must declare a positive GGUF byte count of at least 24 bytes."
        case .arithmeticOverflow:
            return "The estimated native memory requirement exceeds the supported byte-count range."
        case .availableMemoryUnavailable:
            return "The app's available memory budget could not be measured. Native inference cannot start safely; total device RAM does not establish an app budget."
        case .insufficientMemory(let requiredBytes, let availableBytes, let quantization):
            let base = "Native inference needs an estimated \(requiredBytes) available bytes including its safety reserve, but the app currently has \(availableBytes) bytes."
            if quantization == .q8_0 {
                return base + " Explicitly select a separately imported and verified Q4_K_M model, or retry after freeing memory. Q4 is also subject to admission checks."
            }
            return base + " Free memory before retrying; a smaller model must be separately imported and verified."
        case .thermalStateProhibitsStart(let state):
            return "Native inference cannot start while the device thermal state is \(state.rawValue). Let the device cool before retrying."
        }
    }
}

/// Conservative admission estimates, not measurements of a particular model or device.
/// The defaults are provisional: 512 MiB runtime overhead, 128 KiB per context token,
/// and a 512 MiB reserve. Replace overhead estimates with conservative measured bounds
/// for the selected artifact/device before claiming fit; retain a reserve for transient work.
/// Model-file bytes alone omit Metal buffers, KV cache, graph workspace and app allocations.
public struct RuntimeResourcePolicy: Sendable, Equatable {
    public static let maximumContextSize = 2_048
    public let estimatedRuntimeOverheadBytes: UInt64
    public let estimatedBytesPerContextToken: UInt64
    public let reserveBytes: UInt64

    public init(
        estimatedRuntimeOverheadBytes: UInt64 = 512 * 1_024 * 1_024,
        estimatedBytesPerContextToken: UInt64 = 128 * 1_024,
        reserveBytes: UInt64 = 512 * 1_024 * 1_024
    ) {
        self.estimatedRuntimeOverheadBytes = estimatedRuntimeOverheadBytes
        self.estimatedBytesPerContextToken = estimatedBytesPerContextToken
        self.reserveBytes = reserveBytes
    }

    public func preflightLoad(
        model: ValidatedModel,
        configuration: InferenceConfiguration,
        snapshot: RuntimeResourceSnapshot
    ) throws -> RuntimeMemoryEstimate {
        try validateConfigurationAndThermal(configuration, snapshot: snapshot)
        guard model.manifest.expectedByteCount >= 24,
              let modelBytes = UInt64(exactly: model.manifest.expectedByteCount) else {
            throw RuntimeResourcePolicyError.invalidModelByteCount(model.manifest.expectedByteCount)
        }
        let (contextBytes, overflow) = estimatedBytesPerContextToken.multipliedReportingOverflow(
            by: UInt64(configuration.contextSize)
        )
        guard !overflow else { throw RuntimeResourcePolicyError.arithmeticOverflow }
        let requiredBytes = try checkedSum([modelBytes, estimatedRuntimeOverheadBytes, contextBytes, reserveBytes])
        try requireAvailableMemory(requiredBytes, snapshot: snapshot, quantization: model.manifest.quantization)
        return RuntimeMemoryEstimate(
            modelFileBytes: modelBytes,
            runtimeOverheadBytes: estimatedRuntimeOverheadBytes,
            contextOverheadBytes: contextBytes,
            reserveBytes: reserveBytes,
            requiredAvailableBytes: requiredBytes
        )
    }

    /// The loaded model/context are already charged to the app's current budget.
    /// Recheck its remaining reserve and thermal state without charging those allocations twice.
    public func preflightGeneration(
        configuration: InferenceConfiguration,
        snapshot: RuntimeResourceSnapshot
    ) throws {
        try validateConfigurationAndThermal(configuration, snapshot: snapshot)
        try requireAvailableMemory(reserveBytes, snapshot: snapshot, quantization: nil)
    }

    private func validateConfigurationAndThermal(
        _ configuration: InferenceConfiguration,
        snapshot: RuntimeResourceSnapshot
    ) throws {
        guard (128...Self.maximumContextSize).contains(configuration.contextSize) else {
            throw RuntimeResourcePolicyError.unsupportedContextSize(
                requested: configuration.contextSize, maximum: Self.maximumContextSize
            )
        }
        try configuration.validate()
        if snapshot.thermalState == .serious || snapshot.thermalState == .critical {
            throw RuntimeResourcePolicyError.thermalStateProhibitsStart(snapshot.thermalState)
        }
    }

    private func checkedSum(_ values: [UInt64]) throws -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw RuntimeResourcePolicyError.arithmeticOverflow }
            total = sum
        }
        return total
    }

    private func requireAvailableMemory(
        _ requiredBytes: UInt64,
        snapshot: RuntimeResourceSnapshot,
        quantization: ModelQuantization?
    ) throws {
        guard let availableBytes = snapshot.availableMemoryBytes else {
            throw RuntimeResourcePolicyError.availableMemoryUnavailable
        }
        guard availableBytes >= requiredBytes else {
            throw RuntimeResourcePolicyError.insufficientMemory(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes,
                quantization: quantization
            )
        }
    }
}
