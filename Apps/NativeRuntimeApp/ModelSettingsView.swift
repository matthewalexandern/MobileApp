import Foundation
import Darwin
import LlamaCppAdapter
import RuntimeCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ModelSettingsView: View {
    private enum ImportKind { case manifest, weights }

    @ObservedObject var runtime: RuntimeViewModel
    @State private var metadata = ModelMetadataForm()
    @State private var hasReviewedMetadata = false
    @State private var showingImporter = false
    @State private var importKind: ImportKind = .weights
    @State private var isReadingManifest = false
    @State private var manifestNotice: String?
    @State private var manifestReadTask: Task<Void, Never>?
    @State private var manifestReadID: UUID?

    private var importTypes: [UTType] {
        importKind == .manifest ? [.json] : [UTType(filenameExtension: "gguf") ?? .data]
    }

    private var reviewedManifest: ModelManifest? {
        try? metadata.validatedManifest()
    }

    var body: some View {
        Form {
            runtimeSection
            importSection
            metadataSection
            modelCatalogSection
            importedModelSection
            resourceSection
            measurementSection
            privacySection
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: importTypes) { result in
            switch result {
            case let .success(url):
                if importKind == .manifest {
                    beginReadingManifest(from: url)
                } else if let manifest = reviewedManifest, hasReviewedMetadata {
                    runtime.importModel(from: url, manifest: manifest)
                }
            case let .failure(error):
                runtime.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: metadata) { _, _ in
            hasReviewedMetadata = false
        }
        .onDisappear {
            manifestReadTask?.cancel()
            manifestReadID = nil
            isReadingManifest = false
        }
    }

    private var runtimeSection: some View {
        Section {
            Picker("Runtime", selection: Binding(
                get: { runtime.selection },
                set: { selection in Task { await runtime.selectRuntime(selection) } }
            )) {
                ForEach(RuntimeSelection.allCases) { selection in
                    Text(selection.title).tag(selection)
                }
            }
            .disabled(runtime.isBusy || runtime.isGenerating)
            LabeledContent("State", value: runtime.statusDescription)
            if let failure = runtime.failureDescription {
                Text(failure).foregroundStyle(.secondary)
            }
            if runtime.selection == .demonstration {
                Text("The mock produces a fixed response to exercise streaming and cancellation. It does not evaluate your prompt.")
                    .font(.footnote)
                Button("Start demonstration") {
                    Task { await runtime.startDemonstration() }
                }
                .disabled(runtime.isReady || runtime.isBusy || runtime.isGenerating)
            } else {
                Text(LlamaCppInferenceEngine.nativeIntegrationStatus)
                    .font(.footnote)
                Text(LlamaCppInferenceEngine.isNativeBackendLinked
                     ? "This build links the opt-in llama.cpp backend. Model compatibility, Metal execution and memory fit still require a physical iPhone verification run."
                     : "Build with the reviewed llama.cpp XCFramework to enable native loading. Model compatibility and Metal performance require physical iPhone verification.")
                    .font(.footnote)
                if runtime.nativeThermalLimitReached {
                    Text("Native loading is blocked while thermal state is serious or critical. Wait for the device to cool, then retry explicitly.")
                        .font(.footnote)
                }
            }
            Button("Unload runtime") {
                Task { await runtime.unloadModel() }
            }
            .disabled(runtime.isBusy || !runtime.isReady)
            if runtime.isImporting || runtime.isVerifying || runtime.isLoading {
                Button("Cancel model preparation", role: .cancel) {
                    runtime.cancelModelPreparation()
                }
            }
        } header: {
            Text("Inference runtime")
        }
    }

    private var importSection: some View {
        Section {
            Text("Experimental community-pruned GPT-OSS 6B is not an official OpenAI 6B model. Review its source, pruning history, license and exact GGUF file before importing.")
                .font(.footnote)
            Button("Select reviewed JSON manifest", systemImage: "doc.text") {
                importKind = .manifest
                showingImporter = true
            }
            .disabled(runtime.isBusy || isReadingManifest || runtime.isGenerating)
            if isReadingManifest {
                ProgressView("Reading manifest…")
            }
            if let manifestNotice {
                Text(manifestNotice).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Model import")
        } footer: {
            Text("Use a manifest prepared from independently reviewed publisher metadata. This app does not download models or infer their identity from filenames.")
        }
    }

    private var metadataSection: some View {
        Section {
            TextField("Model identifier", text: $metadata.id)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Display name", text: $metadata.displayName)
            Picker("Quantization", selection: $metadata.quantization) {
                Text("Q8_0").tag(ModelQuantization.q8_0)
                Text("Q4_K_M fallback").tag(ModelQuantization.q4_k_m)
            }
            Text("Q8 memory fit is unverified. A Q4 fallback needs its own reviewed file, byte count and checksum; fallback is an explicit selection.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Exact file size in bytes", text: $metadata.byteCount)
                .keyboardType(.numberPad)
            TextField("SHA-256 (64 hexadecimal characters)", text: $metadata.sha256, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            TextField("Reviewed source URL (HTTPS)", text: $metadata.sourceURL, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Source revision", text: $metadata.revision)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Reviewed license", text: $metadata.license)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("I reviewed the source, revision, license and checksum", isOn: $hasReviewedMetadata)
                .disabled(reviewedManifest == nil)
            if reviewedManifest == nil {
                Text(metadata.validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Select and verify GGUF", systemImage: "square.and.arrow.down") {
                importKind = .weights
                showingImporter = true
            }
            .disabled(reviewedManifest == nil || !hasReviewedMetadata || runtime.isBusy || runtime.isGenerating || isReadingManifest)
            if runtime.isImporting {
                ProgressView("Copying and verifying model…")
            }
        } header: {
            Text("Reviewed metadata")
        } footer: {
            Text("Size, checksum and GGUF checks establish file consistency. They do not certify the publisher, model quality or llama.cpp compatibility.")
        }
        .disabled(runtime.isImporting)
    }

    private var modelCatalogSection: some View {
        Section {
            if runtime.installedModels.isEmpty {
                Text("No models in the private catalog. Import a reviewed GGUF and its exact metadata below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(runtime.installedModels, id: \.self) { manifest in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(manifest.displayName)
                        Spacer()
                        Text(manifest.quantization.rawValue)
                            .font(.caption.monospaced())
                    }
                    Text(manifest.provenance.revision)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(isSelected(manifest) ? "Verify selected model again" : "Verify and select \(manifest.quantization.rawValue)") {
                        runtime.selectInstalledModel(manifest)
                    }
                    .disabled(runtime.isBusy || runtime.isGenerating)
                }
            }
            if runtime.isVerifying {
                ProgressView("Checking the stored file and SHA-256…")
            }
            Button("Refresh installed models", systemImage: "arrow.clockwise") {
                Task { await runtime.refreshInstalledModels() }
            }
            .disabled(runtime.isBusy)
        } header: {
            Text("Private model catalog")
        } footer: {
            Text("Reviewed manifests and your selected import survive app restarts. Selection and native loading recheck the file and checksum. Selecting Q4_K_M is explicit and unloads the current native model first; no model loads automatically.")
        }
    }

    private func isSelected(_ manifest: ModelManifest) -> Bool {
        runtime.importedModel?.manifest.id == manifest.id
            && runtime.importedModel?.manifest.quantization == manifest.quantization
    }

    @ViewBuilder
    private var importedModelSection: some View {
        if let model = runtime.importedModel {
            Section("Selected verified import") {
                LabeledContent("Model", value: model.manifest.displayName)
                LabeledContent("Quantization", value: model.manifest.quantization.rawValue)
                LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: model.manifest.expectedByteCount, countStyle: .file))
                Button("Verify and load selected model") {
                    Task { await runtime.loadImportedModel() }
                }
                .disabled(!runtime.canLoadNativeModel)
                if runtime.isLoading { ProgressView("Loading native model…") }
                if let loadTime = runtime.lastLoadDurationSeconds {
                    LabeledContent("Latest native load", value: String(format: "%.2f s", loadTime))
                }
                Text("Choose Native adapter, then load explicitly. Loading hashes the selected file again before native allocation; load time excludes that checksum pass.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resourceSection: some View {
        Section {
            if let resources = runtime.resources {
                LabeledContent("Available app memory", value: memoryDescription(resources.availableMemoryBytes))
                LabeledContent("Resident memory", value: memoryDescription(resources.residentMemoryBytes))
                LabeledContent("Peak resident since launch", value: memoryDescription(resources.peakResidentMemoryBytes))
                LabeledContent("Thermal state", value: resources.thermalState.rawValue.capitalized)
            }
            Button("Refresh memory and thermal readings", systemImage: "arrow.clockwise") {
                runtime.refreshResources()
            }
            Text("Readings describe this process at refresh time. Available memory changes as iOS balances other work; the resident peak includes all app allocations since launch. Missing measurements are shown as unavailable. iOS can terminate an app before it can handle an out-of-memory condition.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Device resources")
        }
    }

    private func memoryDescription(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    @ViewBuilder
    private var measurementSection: some View {
        if let metrics = runtime.snapshot?.metrics {
            let demonstration = runtime.snapshot?.mode == .demonstration
            Section("Latest generation") {
                LabeledContent(demonstration ? "Output chunks" : "Output tokens", value: String(metrics.generatedTokenCount))
                LabeledContent("Request duration", value: String(format: "%.2f s", metrics.durationSeconds))
                if let firstToken = metrics.timeToFirstTokenSeconds {
                    LabeledContent(demonstration ? "Time to first chunk" : "Time to first token", value: String(format: "%.2f s", firstToken))
                }
                if !demonstration, let throughput = metrics.tokensPerSecond {
                    LabeledContent("Generation throughput", value: String(format: "%.2f tokens/s", throughput))
                }
                Text(demonstration
                     ? "Demonstration counts are text chunks and these timings do not measure model performance."
                     : "Timings and token counts come from this generation. Complete the documented physical iPhone benchmark with memory and thermal readings before making device performance claims.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy and lifecycle") {
            Text("Messages stay in memory for this session. Reviewed model files and manifests remain in app-private storage. No account, model upload or network scan is used.")
            Text("Backgrounding or an iOS memory warning cancels generation and model preparation, then unloads the runtime. Serious or critical thermal state also blocks native inference. Start the demonstration or load a selected model explicitly after recovery; iOS background execution is best-effort.")
            Text("Remediation actions and external integrations require explicit approval in future milestones.")
        }
        .font(.footnote)
    }

    private func beginReadingManifest(from url: URL) {
        manifestReadTask?.cancel()
        let operationID = UUID()
        manifestReadID = operationID
        isReadingManifest = true
        manifestNotice = nil
        manifestReadTask = Task {
            await readManifest(from: url, operationID: operationID)
        }
    }

    private func readManifest(from url: URL, operationID: UUID) async {
        defer {
            if manifestReadID == operationID {
                isReadingManifest = false
                manifestReadTask = nil
                manifestReadID = nil
            }
        }
        let readTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if scopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            guard url.isFileURL else {
                throw ManifestInputError("Choose a local JSON manifest.")
            }
            let descriptor = url.path.withCString {
                open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw ManifestInputError("The selected manifest cannot be opened.")
            }
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? input.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  status.st_size > 0, status.st_size <= 65_536 else {
                throw ManifestInputError("Choose a regular JSON manifest no larger than 64 KB.")
            }
            var data = Data()
            while data.count <= 65_536 {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 65_537 - data.count),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= 65_536 else {
                throw ManifestInputError("The manifest exceeds the 64 KB limit.")
            }
            try Task.checkCancellation()
            return try JSONDecoder().decode(ModelManifest.self, from: data)
        }
        do {
            let manifest = try await withTaskCancellationHandler {
                try await readTask.value
            } onCancel: {
                readTask.cancel()
            }
            try Task.checkCancellation()
            guard manifestReadID == operationID else { return }
            metadata = ModelMetadataForm(manifest: manifest)
            hasReviewedMetadata = false
            manifestNotice = "Manifest loaded. Review every value, then acknowledge the source and checksum before selecting a GGUF."
        } catch {
            guard manifestReadID == operationID, !Task.isCancelled, !(error is CancellationError) else { return }
            runtime.errorMessage = error.localizedDescription
        }
    }
}

private struct ManifestInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct ModelMetadataForm: Equatable {
    var id = ""
    var displayName = ""
    var quantization: ModelQuantization = .q8_0
    var byteCount = ""
    var sha256 = ""
    var sourceURL = ""
    var revision = ""
    var license = ""

    init() {}

    init(manifest: ModelManifest) {
        id = manifest.id
        displayName = manifest.displayName
        quantization = manifest.quantization
        byteCount = String(manifest.expectedByteCount)
        sha256 = manifest.sha256
        sourceURL = manifest.provenance.sourceURL.absoluteString
        revision = manifest.provenance.revision
        license = manifest.provenance.license
    }

    var validationMessage: String {
        do {
            _ = try validatedManifest()
            return "Metadata is ready for review."
        } catch {
            return error.localizedDescription
        }
    }

    func validatedManifest() throws -> ModelManifest {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        let license = license.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedID = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ allowedID.contains($0) }) else {
            throw ManifestInputError("Use a model identifier with 1–128 ASCII letters, digits, underscores or hyphens.")
        }
        guard !displayName.isEmpty else {
            throw ManifestInputError("Enter the reviewed display name.")
        }
        guard let byteCount = Int64(byteCount.trimmingCharacters(in: .whitespacesAndNewlines)), byteCount >= 24 else {
            throw ManifestInputError("Enter the exact file size in bytes, including the 24-byte GGUF header.")
        }
        let checksum = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard checksum.utf8.count == 64, checksum.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else {
            throw ManifestInputError("Enter the independently reviewed 64-character SHA-256 checksum.")
        }
        guard let sourceURL = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              sourceURL.scheme?.lowercased() == "https", sourceURL.host?.isEmpty == false,
              sourceURL.user == nil, sourceURL.password == nil else {
            throw ManifestInputError("Enter the reviewed HTTPS source URL without embedded credentials.")
        }
        guard !revision.isEmpty, !license.isEmpty else {
            throw ManifestInputError("Record the reviewed source revision and license.")
        }
        return ModelManifest(
            id: id,
            displayName: displayName,
            quantization: quantization,
            expectedByteCount: byteCount,
            sha256: checksum,
            provenance: ModelProvenance(sourceURL: sourceURL, revision: revision, license: license)
        )
    }
}
