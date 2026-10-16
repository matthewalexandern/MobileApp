#include "KMLlama.h"

#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#else
#include "llama.h" // Host syntax/smoke checks against the exact pinned source.
#endif

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <sys/sysctl.h>
#if __has_include(<os/proc.h>)
#include <os/proc.h>
#define KM_HAS_PROC_AVAILABLE_MEMORY 1
#endif
#endif

namespace {
constexpr uint64_t max_model_bytes = UINT64_C(2) << 30;
constexpr uint64_t minimum_headroom = UINT64_C(512) << 20;
constexpr size_t maximum_prompt_bytes = 1 << 20;
constexpr size_t maximum_output_bytes = 1 << 20;
constexpr int32_t batch_capacity = 128;

struct close_file {
    void operator()(FILE * file) const noexcept { if (file) { fclose(file); } }
};

void error_text(char * destination, size_t capacity, const char * message) noexcept {
    if (destination && capacity) {
        const size_t count = std::min(capacity - 1, std::strlen(message));
        std::memcpy(destination, message, count);
        destination[count] = '\0';
    }
}

bool add(uint64_t a, uint64_t b, uint64_t & result) noexcept {
    if (b > std::numeric_limits<uint64_t>::max() - a) { return false; }
    result = a + b;
    return true;
}

bool multiply(uint64_t a, uint64_t b, uint64_t & result) noexcept {
    if (a && b > std::numeric_limits<uint64_t>::max() / a) { return false; }
    result = a * b;
    return true;
}

uint64_t physical_memory() noexcept {
#if defined(__APPLE__)
    uint64_t bytes = 0;
    size_t length = sizeof(bytes);
    if (sysctlbyname("hw.memsize", &bytes, &length, nullptr, 0) == 0 && length == sizeof(bytes)) { return bytes; }
    return 0;
#else
    const long pages = sysconf(_SC_PHYS_PAGES);
    const long page_size = sysconf(_SC_PAGESIZE);
    uint64_t bytes = 0;
    return pages > 0 && page_size > 0 && multiply(static_cast<uint64_t>(pages), static_cast<uint64_t>(page_size), bytes) ? bytes : 0;
#endif
}

void quiet_log(ggml_log_level, const char *, void *) noexcept {}

void initialize_backend() {
    // No runtime prompt, model path or vocabulary output enters device logs.
    // These callbacks and the backend live for the app process, across unloads.
    static std::once_flag once;
    std::call_once(once, [] {
        llama_log_set(quiet_log, nullptr);
        llama_backend_init();
    });
}

bool scalar(const llama_model * model, const std::string & key, std::string & output) {
    char buffer[256] = {};
    const int32_t length = llama_model_meta_val_str(model, key.c_str(), buffer, sizeof(buffer));
    if (length < 0 || static_cast<size_t>(length) >= sizeof(buffer)) { return false; }
    output.assign(buffer, static_cast<size_t>(length));
    return true;
}

bool number(const llama_model * model, const std::string & key, uint64_t & output) {
    std::string text;
    if (!scalar(model, key, text) || text.empty() || text.size() > 20) { return false; }
    output = 0;
    for (unsigned char digit : text) {
        if (digit < '0' || digit > '9' || output > (std::numeric_limits<uint64_t>::max() - (digit - '0')) / 10) { return false; }
        output = output * 10 + (digit - '0');
    }
    return output != 0;
}

struct estimate {
    uint32_t context = 0;
    uint64_t required = 0;
    uint64_t weights = 0;
    std::string architecture;
    std::string chat_template;
};

bool supported_standard_attention(const std::string & name) {
    // A deliberately narrow set whose full F16 K/V cache can be bounded using
    // scalar per-layer GQA metadata. Recurrent/MLA/hybrid cache layouts require a
    // separate verified estimator rather than an optimistic approximation.
    static const char * const names[] = {"llama", "qwen2", "qwen3", "gemma", "gemma2", "gemma3", "phi3", "gpt-oss"};
    for (const char * candidate : names) { if (name == candidate) { return true; } }
    return false;
}

bool memory_estimate(const llama_model * model, uint64_t file_bytes, estimate & output, bool loaded_weights = false) {
    if (!scalar(model, "general.architecture", output.architecture) || !supported_standard_attention(output.architecture)) { return false; }
    std::string split_count;
    if (scalar(model, "split.count", split_count) && split_count != "1" && split_count != "0") { return false; }
    const std::string prefix = output.architecture + ".";
    uint64_t layers = 0, heads = 0, kv_heads = 0, embedding = 0, key = 0, value = 0, context = 0;
    if (!number(model, prefix + "block_count", layers) || !number(model, prefix + "attention.head_count", heads) || !number(model, prefix + "embedding_length", embedding) || !number(model, prefix + "context_length", context)) { return false; }
    if (layers > 512 || heads > 1024 || embedding > 131072 || context > (UINT64_C(1) << 24) || embedding % heads != 0) { return false; }
    // Missing or array-valued KV counts use all query heads: a conservative
    // upper bound for the supported grouped-query attention architectures.
    if (!number(model, prefix + "attention.head_count_kv", kv_heads)) { kv_heads = heads; }
    if (!kv_heads || kv_heads > heads) { return false; }
    if (!number(model, prefix + "attention.key_length", key)) { key = embedding / heads; }
    if (!number(model, prefix + "attention.value_length", value)) { value = embedding / heads; }
    uint64_t swa_key = 0, swa_value = 0;
    if (number(model, prefix + "attention.key_length_swa", swa_key)) { key = std::max(key, swa_key); }
    if (number(model, prefix + "attention.value_length_swa", swa_value)) { value = std::max(value, swa_value); }
    // Vocab-only loading intentionally skips model hparams in this pin. Read
    // scalar metadata first; compare the instantiated hparams after full load.
    if (!key || !value || key > 65536 || value > 65536 || (loaded_weights && (llama_model_n_ctx_train(model) <= 0 || context != static_cast<uint64_t>(llama_model_n_ctx_train(model))))) { return false; }
    uint64_t cache = context;
    uint64_t widths = 0;
    if (!add(key, value, widths) || !multiply(cache, layers, cache) || !multiply(cache, kv_heads, cache) || !multiply(cache, widths, cache) || !multiply(cache, 2, cache)) { return false; }
    output.weights = std::max(file_bytes, llama_model_size(model));
    // Keep full F16 caches, graph/activation headroom and weight repacking
    // allowance. This is an admission bound, not measured iOS peak-RSS proof.
    uint64_t headroom = 0;
    if (!add(minimum_headroom, output.weights / 4, headroom) || !add(output.weights, cache, output.required) || !add(output.required, headroom, output.required)) { return false; }
    if (llama_model_meta_val_str(model, "tokenizer.chat_template", nullptr, 0) <= 0) { return false; }
    const char * chat = llama_model_chat_template(model, nullptr);
    if (!chat || !*chat || strnlen(chat, 65537) > 65536) { return false; }
    output.chat_template = chat;
    const llama_chat_message probe = {"user", "Hello"};
    if (llama_chat_apply_template(chat, &probe, 1, true, nullptr, 0) <= 0) { return false; }
    output.context = static_cast<uint32_t>(context);
    return true;
}

bool valid_utf8(const std::string & text) noexcept {
    for (size_t i = 0; i < text.size();) {
        const unsigned char first = static_cast<unsigned char>(text[i]);
        if (first < 0x80) { if (first == 0) { return false; } ++i; continue; }
        unsigned length = first >= 0xc2 && first <= 0xdf ? 2 : first >= 0xe0 && first <= 0xef ? 3 : first >= 0xf0 && first <= 0xf4 ? 4 : 0;
        if (!length || i + length > text.size()) { return false; }
        for (unsigned j = 1; j < length; ++j) { if ((static_cast<unsigned char>(text[i+j]) & 0xc0) != 0x80) { return false; } }
        const unsigned char second = static_cast<unsigned char>(text[i+1]);
        if ((first == 0xe0 && second < 0xa0) || (first == 0xed && second >= 0xa0) || (first == 0xf0 && second < 0x90) || (first == 0xf4 && second >= 0x90)) { return false; }
        i += length;
    }
    return true;
}

bool tokenize(const llama_vocab * vocab, const std::string & text, bool add_special, std::vector<llama_token> & output) {
    if (text.size() > static_cast<size_t>(INT32_MAX)) { return false; }
    const int32_t need = llama_tokenize(vocab, text.data(), static_cast<int32_t>(text.size()), nullptr, 0, add_special, true);
    if (need == INT32_MIN) { return false; }
    const int32_t capacity = need < 0 ? -need : need;
    if (capacity < 0 || static_cast<uint64_t>(capacity) > maximum_prompt_bytes + 16) { return false; }
    output.resize(static_cast<size_t>(capacity));
    if (!capacity) { return true; }
    const int32_t count = llama_tokenize(vocab, text.data(), static_cast<int32_t>(text.size()), output.data(), capacity, add_special, true);
    if (count < 0 || count > capacity) { return false; }
    output.resize(static_cast<size_t>(count));
    return true;
}

bool safe_content(const llama_vocab * vocab, const std::string & content) {
    std::vector<llama_token> tokens;
    if (!valid_utf8(content) || !tokenize(vocab, content, false, tokens)) { return false; }
    // Template delimiters must originate from the model's trusted template,
    // never from literal model control tokens embedded in user/history data.
    for (llama_token token : tokens) {
        const auto attributes = llama_vocab_get_attr(vocab, token);
        if (attributes & (LLAMA_TOKEN_ATTR_CONTROL | LLAMA_TOKEN_ATTR_USER_DEFINED)) { return false; }
    }
    return true;
}

bool piece(const llama_vocab * vocab, llama_token token, std::string & output) {
    char local[256] = {};
    int32_t length = llama_token_to_piece(vocab, token, local, sizeof(local), 0, false);
    if (length == INT32_MIN) { return false; }
    if (length >= 0) { output.assign(local, static_cast<size_t>(length)); return true; }
    const size_t required = static_cast<size_t>(-length);
    if (required > maximum_output_bytes) { return false; }
    std::vector<char> bytes(required);
    length = llama_token_to_piece(vocab, token, bytes.data(), static_cast<int32_t>(bytes.size()), 0, false);
    if (length < 0 || static_cast<size_t>(length) > bytes.size()) { return false; }
    output.assign(bytes.data(), static_cast<size_t>(length));
    return true;
}
} // namespace

struct km_engine {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    const llama_vocab * vocab = nullptr;
    llama_sampler * sampler = nullptr;
    FILE * model_file = nullptr;
    llama_batch batch = {};
    bool owns_batch = false;
    uint32_t native_context = 0;
    uint64_t model_bytes = 0;
    std::string chat_template;
    std::atomic<bool> cancelled{false};
    std::mutex generation;

    ~km_engine() {
        if (sampler) { llama_sampler_free(sampler); }
        if (owns_batch) { llama_batch_free(batch); }
        if (context) { llama_free(context); }
        if (model) { llama_model_free(model); }
        if (model_file) { fclose(model_file); }
    }
};

extern "C" uint64_t km_available_memory_bytes(void) {
    const uint64_t physical = physical_memory();
    if (!physical) { return 0; }
#if defined(KM_HAS_PROC_AVAILABLE_MEMORY) && TARGET_OS_IOS
    return std::min<uint64_t>(physical, static_cast<uint64_t>(os_proc_available_memory()));
#elif !defined(__APPLE__)
    const long pages = sysconf(_SC_AVPHYS_PAGES);
    const long page_size = sysconf(_SC_PAGESIZE);
    uint64_t available = 0;
    return pages > 0 && page_size > 0 && multiply(static_cast<uint64_t>(pages), static_cast<uint64_t>(page_size), available) ? std::min(physical, available) : 0;
#else
    // Desktop-only build helpers do not claim iOS process availability.
    return 0;
#endif
}

extern "C" km_engine * km_engine_create(const char * path, int32_t threads, uint64_t memory_budget_bytes, char * error, size_t error_capacity) {
    error_text(error, error_capacity, "");
    try {
        const uint64_t available = km_available_memory_bytes();
        if (!path || !*path || strnlen(path, 4097) > 4096 || threads < 1 || threads > 16 || !memory_budget_bytes || !available) { error_text(error, error_capacity, "Invalid model configuration or unavailable memory budget."); return nullptr; }
        const uint64_t budget = std::min(memory_budget_bytes, available);
        const int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) { error_text(error, error_capacity, "The imported model file could not be opened."); return nullptr; }
        FILE * raw_file = fdopen(fd, "rb");
        if (!raw_file) { close(fd); error_text(error, error_capacity, "The imported model file could not be opened."); return nullptr; }
        std::unique_ptr<FILE, close_file> file(raw_file);
        struct stat identity = {};
        if (fstat(fd, &identity) != 0 || !S_ISREG(identity.st_mode) || identity.st_size <= 0 || static_cast<uint64_t>(identity.st_size) > max_model_bytes || static_cast<uint64_t>(identity.st_size) > budget || budget - static_cast<uint64_t>(identity.st_size) < minimum_headroom) { error_text(error, error_capacity, "This model exceeds the conservative on-device memory budget."); return nullptr; }
        unsigned char magic[4] = {};
        if (fread(magic, 1, sizeof(magic), file.get()) != sizeof(magic) || std::memcmp(magic, "GGUF", sizeof(magic)) != 0 || fseek(file.get(), 0, SEEK_SET) != 0) { error_text(error, error_capacity, "A valid single-file GGUF model is required."); return nullptr; }
        initialize_backend();
        auto metadata_parameters = llama_model_default_params();
        metadata_parameters.vocab_only = true;
        metadata_parameters.n_gpu_layers = 0;
        metadata_parameters.load_mode = LLAMA_LOAD_MODE_MMAP;
        // FILE-pointer loading does not discover or open neighboring split files.
        std::unique_ptr<llama_model, decltype(&llama_model_free)> metadata(llama_model_load_from_file_ptr(file.get(), metadata_parameters), llama_model_free);
        estimate admission;
        if (!metadata || !memory_estimate(metadata.get(), static_cast<uint64_t>(identity.st_size), admission)) { error_text(error, error_capacity, "This model lacks a supported native-context memory estimate or chat template."); return nullptr; }
        if (admission.required > budget) { error_text(error, error_capacity, "The model's full native context exceeds the available memory budget; context was not reduced."); return nullptr; }
        metadata.reset();
        if (fseek(file.get(), 0, SEEK_SET) != 0) { error_text(error, error_capacity, "The imported model could not be read."); return nullptr; }
        std::unique_ptr<km_engine> engine(new km_engine());
        auto parameters = llama_model_default_params();
        parameters.n_gpu_layers = 99;
        parameters.load_mode = LLAMA_LOAD_MODE_MMAP;
        parameters.check_tensors = true;
        engine->model = llama_model_load_from_file_ptr(file.get(), parameters);
        if (!engine->model) { error_text(error, error_capacity, "The imported model could not be loaded on this device."); return nullptr; }
        // Recheck the same open file after loading; the imported file must remain
        // immutable for the engine lifetime. mmap has its own VM mapping.
        struct stat after = {};
        if (fstat(fd, &after) != 0 || after.st_size != identity.st_size || after.st_mtime != identity.st_mtime || after.st_ctime != identity.st_ctime) { error_text(error, error_capacity, "The model changed while it was loading."); return nullptr; }
        estimate loaded;
        if (!memory_estimate(engine->model, static_cast<uint64_t>(identity.st_size), loaded, true) || loaded.required > budget || loaded.context != admission.context || loaded.chat_template != admission.chat_template) { error_text(error, error_capacity, "The loaded model failed the native-context admission check."); return nullptr; }
        engine->vocab = llama_model_get_vocab(engine->model);
        engine->native_context = admission.context;
        engine->model_bytes = loaded.weights;
        engine->chat_template = std::move(loaded.chat_template);
        auto context_parameters = llama_context_default_params();
        context_parameters.n_ctx = 0;
        context_parameters.n_batch = batch_capacity;
        context_parameters.n_ubatch = batch_capacity;
        context_parameters.n_threads = threads;
        context_parameters.n_threads_batch = threads;
        context_parameters.n_seq_max = 1;
        context_parameters.type_k = GGML_TYPE_F16;
        context_parameters.type_v = GGML_TYPE_F16;
        context_parameters.swa_full = true;
        context_parameters.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
        context_parameters.no_perf = true;
        engine->context = llama_init_from_model(engine->model, context_parameters);
        if (!engine->context || llama_n_ctx(engine->context) != engine->native_context) { error_text(error, error_capacity, "This device could not allocate the model's full native context; context was not reduced."); return nullptr; }
        engine->sampler = llama_sampler_init_greedy();
        engine->batch = llama_batch_init(batch_capacity, 0, 1);
        engine->owns_batch = true;
        if (!engine->vocab || !engine->sampler || !engine->batch.token || !engine->batch.pos || !engine->batch.n_seq_id || !engine->batch.seq_id || !engine->batch.logits) { error_text(error, error_capacity, "The on-device engine could not allocate its buffers."); return nullptr; }
        // Preserve the open source across the engine lifetime, including any
        // backend's on-demand reads. Context/model release precedes fclose.
        engine->model_file = file.release();
        return engine.release();
    } catch (...) {
        error_text(error, error_capacity, "The on-device engine could not be initialized.");
        return nullptr;
    }
}

extern "C" void km_engine_destroy(km_engine * engine) { delete engine; }
extern "C" uint32_t km_engine_native_context(const km_engine * engine) { return engine ? engine->native_context : 0; }
extern "C" uint64_t km_engine_model_size(const km_engine * engine) { return engine ? engine->model_bytes : 0; }
extern "C" void km_engine_reset_cancel(km_engine * engine) { if (engine) { engine->cancelled.store(false, std::memory_order_release); } }
extern "C" void km_engine_cancel(km_engine * engine) { if (engine) { engine->cancelled.store(true, std::memory_order_release); } }

namespace {
struct clear_memory {
    km_engine * engine;
    ~clear_memory() {
        llama_memory_clear(llama_get_memory(engine->context), true);
        llama_sampler_reset(engine->sampler);
    }
};

int decode_tokens(km_engine * engine, const llama_token * tokens, size_t count, uint32_t position) {
    engine->batch.n_tokens = static_cast<int32_t>(count);
    for (size_t index = 0; index < count; ++index) {
        engine->batch.token[index] = tokens[index];
        engine->batch.pos[index] = static_cast<llama_pos>(position + index);
        engine->batch.n_seq_id[index] = 1;
        engine->batch.seq_id[index][0] = 0;
        engine->batch.logits[index] = index + 1 == count ? 1 : 0;
    }
    return llama_decode(engine->context, engine->batch);
}
} // namespace

extern "C" int32_t km_engine_generate(km_engine * engine, const km_chat_message * messages, size_t message_count, int32_t max_tokens, char * output, size_t output_capacity, char * error, size_t error_capacity) {
    error_text(error, error_capacity, "");
    if (output && output_capacity) { output[0] = '\0'; }
    if (!engine || !messages || !message_count || message_count > 100 || max_tokens < 1 || max_tokens > 256 || !output || output_capacity < 2 || output_capacity > maximum_output_bytes + 1) { error_text(error, error_capacity, "Invalid bounded generation request."); return -1; }
    try {
        std::unique_lock<std::mutex> lock(engine->generation, std::try_to_lock);
        if (!lock.owns_lock()) { error_text(error, error_capacity, "The on-device engine is already in use."); return -1; }
        clear_memory cleanup{engine};
        llama_memory_clear(llama_get_memory(engine->context), true);
        llama_sampler_reset(engine->sampler);
        if (engine->cancelled.load(std::memory_order_acquire)) { return 1; }
        std::vector<llama_chat_message> chat;
        chat.reserve(message_count);
        size_t total = 0;
        for (size_t index = 0; index < message_count; ++index) {
            const auto & message = messages[index];
            if (!message.role || !message.content || strnlen(message.role, 10) >= 10) { error_text(error, error_capacity, "Invalid message roles or content."); return -1; }
            const std::string role(message.role);
            if ((role != "system" && role != "user" && role != "assistant") || (role == "system" && index != 0) || (index + 1 == message_count && role != "user")) { error_text(error, error_capacity, "Invalid message role ordering."); return -1; }
            const size_t length = strnlen(message.content, maximum_prompt_bytes + 1);
            if (length > maximum_prompt_bytes || total > maximum_prompt_bytes - length) { error_text(error, error_capacity, "The conversation exceeds the local request byte limit."); return -1; }
            total += length;
            if (!safe_content(engine->vocab, std::string(message.content, length))) { error_text(error, error_capacity, "Messages must be valid UTF-8 and cannot contain reserved model control tokens."); return -1; }
            chat.push_back({message.role, message.content});
        }
        const int32_t required = llama_chat_apply_template(engine->chat_template.c_str(), chat.data(), chat.size(), true, nullptr, 0);
        if (required <= 0 || static_cast<size_t>(required) > maximum_prompt_bytes * 2) { error_text(error, error_capacity, "This model's exact chat template could not be applied safely."); return -1; }
        std::vector<char> formatted(static_cast<size_t>(required) + 1, 0);
        const int32_t written = llama_chat_apply_template(engine->chat_template.c_str(), chat.data(), chat.size(), true, formatted.data(), static_cast<int32_t>(formatted.size()));
        if (written != required) { error_text(error, error_capacity, "This model's exact chat template could not be applied safely."); return -1; }
        std::vector<llama_token> tokens;
        if (!tokenize(engine->vocab, std::string(formatted.data(), static_cast<size_t>(written)), true, tokens) || tokens.empty() || tokens.size() + static_cast<size_t>(max_tokens) > engine->native_context) { error_text(error, error_capacity, "The conversation and reply budget exceed the model's native context; nothing was truncated."); return -1; }
        uint32_t position = 0;
        while (position < tokens.size()) {
            if (engine->cancelled.load(std::memory_order_acquire)) { return 1; }
            const size_t count = std::min(static_cast<size_t>(batch_capacity), tokens.size() - position);
            const int result = decode_tokens(engine, tokens.data() + position, count, position);
            if (result != 0) { error_text(error, error_capacity, "Prompt evaluation failed; its transient context was cleared."); return engine->cancelled.load(std::memory_order_acquire) ? 1 : -1; }
            position += static_cast<uint32_t>(count);
        }
        std::string reply;
        reply.reserve(std::min(output_capacity - 1, static_cast<size_t>(8192)));
        for (int32_t index = 0; index < max_tokens; ++index) {
            if (engine->cancelled.load(std::memory_order_acquire)) { return 1; }
            // This function both samples and accepts: never accept a second time.
            const llama_token next = llama_sampler_sample(engine->sampler, engine->context, -1);
            if (llama_vocab_is_eog(engine->vocab, next)) { break; }
            std::string fragment;
            if (!piece(engine->vocab, next, fragment) || fragment.size() > output_capacity - 1 - reply.size()) { error_text(error, error_capacity, "The generated reply exceeds the output byte limit."); return -1; }
            reply.append(fragment);
            if (index + 1 < max_tokens) {
                if (engine->cancelled.load(std::memory_order_acquire)) { return 1; }
                if (decode_tokens(engine, &next, 1, position) != 0) { error_text(error, error_capacity, "Reply evaluation failed; its transient context was cleared."); return engine->cancelled.load(std::memory_order_acquire) ? 1 : -1; }
                ++position;
            }
        }
        if (engine->cancelled.load(std::memory_order_acquire)) { return 1; }
        if (!valid_utf8(reply)) { error_text(error, error_capacity, "The generated reply was not complete UTF-8."); return -1; }
        std::memcpy(output, reply.data(), reply.size());
        output[reply.size()] = '\0';
        return 0;
    } catch (...) {
        error_text(error, error_capacity, "The on-device generation failed.");
        return -1;
    }
}
