// JNI bridge over llama.cpp.
//
// Design notes:
//  * The model is mmap'd, never fully read into the heap. On a 3 GB device this
//    is the difference between working and being OOM-killed.
//  * Generation streams token by token through a Kotlin callback so the UI can
//    render progressively. A survivor should see words appearing, not a spinner.
//  * All state lives behind an opaque handle so Kotlin never owns raw pointers.

#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <memory>

#include "llama.h"

#define LOG_TAG "GodstoneLLM"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

struct GodstoneContext {
    llama_model*   model   = nullptr;
    llama_context* ctx     = nullptr;
    llama_sampler* sampler = nullptr;
    int            n_ctx   = 2048;
};

GodstoneContext* as_ctx(jlong handle) {
    return reinterpret_cast<GodstoneContext*>(handle);
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_io_godstone_llm_LlamaBridge_nativeLoadModel(
        JNIEnv* env, jobject, jstring jpath, jint nCtx, jint nThreads) {

    const char* path = env->GetStringUTFChars(jpath, nullptr);

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.use_mmap  = true;    // essential on low-RAM devices
    mparams.use_mlock = false;   // never lock: the OS must be able to evict us
    mparams.n_gpu_layers = 0;    // Android GPU offload is unreliable across SoCs

    llama_model* model = llama_model_load_from_file(path, mparams);
    env->ReleaseStringUTFChars(jpath, path);

    if (model == nullptr) {
        LOGE("model load failed");
        return 0;   // Kotlin turns this into a graceful degraded mode (C5)
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx       = static_cast<uint32_t>(nCtx);
    cparams.n_batch     = 512;
    cparams.n_threads   = nThreads;
    cparams.n_threads_batch = nThreads;
    cparams.flash_attn  = true;

    llama_context* ctx = llama_init_from_model(model, cparams);
    if (ctx == nullptr) {
        llama_model_free(model);
        LOGE("context creation failed");
        return 0;
    }

    // Low temperature: this is a reference tool, not a creative writer.
    auto sparams = llama_sampler_chain_default_params();
    llama_sampler* chain = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(0.3f));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    auto* gc = new GodstoneContext{model, ctx, chain, nCtx};
    LOGI("model loaded, n_ctx=%d threads=%d", nCtx, nThreads);
    return reinterpret_cast<jlong>(gc);
}

JNIEXPORT void JNICALL
Java_io_godstone_llm_LlamaBridge_nativeFreeModel(JNIEnv*, jobject, jlong handle) {
    auto* gc = as_ctx(handle);
    if (gc == nullptr) return;

    if (gc->sampler) llama_sampler_free(gc->sampler);
    if (gc->ctx)     llama_free(gc->ctx);
    if (gc->model)   llama_model_free(gc->model);

    delete gc;
    llama_backend_free();
    LOGI("model released");
}

JNIEXPORT jint JNICALL
Java_io_godstone_llm_LlamaBridge_nativeGenerate(
        JNIEnv* env, jobject thiz, jlong handle,
        jstring jprompt, jint maxTokens, jobject callback) {

    auto* gc = as_ctx(handle);
    if (gc == nullptr) return -1;

    const char* prompt = env->GetStringUTFChars(jprompt, nullptr);
    const llama_vocab* vocab = llama_model_get_vocab(gc->model);

    // Tokenise the prompt.
    int n_prompt = -llama_tokenize(vocab, prompt, strlen(prompt),
                                   nullptr, 0, true, true);
    std::vector<llama_token> tokens(n_prompt);
    llama_tokenize(vocab, prompt, strlen(prompt),
                   tokens.data(), tokens.size(), true, true);
    env->ReleaseStringUTFChars(jprompt, prompt);

    // Refuse rather than silently truncate context: a truncated survival
    // procedure is worse than no answer at all.
    if (n_prompt >= gc->n_ctx - maxTokens) {
        LOGE("prompt too long: %d tokens, ctx %d", n_prompt, gc->n_ctx);
        return -2;
    }

    jclass cbClass = env->GetObjectClass(callback);
    jmethodID onToken = env->GetMethodID(cbClass, "onToken", "(Ljava/lang/String;)V");

    llama_batch batch = llama_batch_get_one(tokens.data(), tokens.size());

    int generated = 0;
    char piece[256];

    for (int i = 0; i < maxTokens; i++) {
        if (llama_decode(gc->ctx, batch) != 0) {
            LOGE("decode failed at token %d", i);
            break;
        }

        llama_token next = llama_sampler_sample(gc->sampler, gc->ctx, -1);

        if (llama_vocab_is_eog(vocab, next)) break;

        int n = llama_token_to_piece(vocab, next, piece, sizeof(piece), 0, true);
        if (n > 0) {
            jstring jpiece = env->NewStringUTF(std::string(piece, n).c_str());
            env->CallVoidMethod(callback, onToken, jpiece);
            env->DeleteLocalRef(jpiece);
        }

        batch = llama_batch_get_one(&next, 1);
        generated++;
    }

    return generated;
}

} // extern "C"
