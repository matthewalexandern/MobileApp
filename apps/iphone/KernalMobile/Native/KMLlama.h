#ifndef KM_LLAMA_H
#define KM_LLAMA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct km_engine km_engine;
typedef struct km_chat_message {
    const char * role;
    const char * content;
} km_chat_message;

// Current process availability, capped by physical memory. It is not a promise
// that a model/context fits. The Swift runtime must reserve its own safety margin.
uint64_t km_available_memory_bytes(void);

// Serialized worker use only, except cancel/reset_cancel which are atomic.
// budget is the app's conservative currently available byte budget, never the
// device's advertised total. A model whose full native context does not fit is
// refused; this API never reduces context or downloads a replacement model.
km_engine * km_engine_create(const char * path, int32_t threads,
                             uint64_t memory_budget_bytes,
                             char * error, size_t error_capacity);
void km_engine_destroy(km_engine * engine);
uint32_t km_engine_native_context(const km_engine * engine);
uint64_t km_engine_model_size(const km_engine * engine);

// Call reset_cancel before installing a cancellation handler, then generate.
// Never clear cancellation from inside generation. Cancellation is observed
// between bounded decode calls; Metal work already submitted may finish first.
void km_engine_reset_cancel(km_engine * engine);
void km_engine_cancel(km_engine * engine);

// 0 = complete/bounded generation; 1 = cancelled; negative = failure.
// max_tokens is 1...256. Output is UTF-8 and NUL-terminated on success. On any
// failure/cancellation output is empty. Caller owns all argument buffers for the
// duration of this synchronous call; message roles are system/user/assistant.
int32_t km_engine_generate(km_engine * engine, const km_chat_message * messages,
                           size_t message_count, int32_t max_tokens,
                           char * output, size_t output_capacity,
                           char * error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
