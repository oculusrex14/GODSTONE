#import "LlamaBridge.h"

#include "llama.h"

#include <atomic>
#include <string>
#include <vector>

// llama.cpp is vendored at third_party/llama.cpp and built by XcodeGen as a
// static library with GGML_METAL=ON. Nothing is fetched at build time, so the
// whole app can be rebuilt on a machine that has never seen the internet.

@implementation GSLlamaBridge {
    llama_model   *_model;
    llama_context *_ctx;
    llama_sampler *_sampler;
    std::atomic<bool> _cancelFlag;
    NSInteger _contextTokens;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _model = nullptr;
        _ctx = nullptr;
        _sampler = nullptr;
        _cancelFlag = false;
        _contextTokens = 0;

        // Backend init is global and idempotent, but doing it once here keeps
        // the Metal device creation off the first-token critical path.
        static dispatch_once_t once;
        dispatch_once(&once, ^{ llama_backend_init(); });
    }
    return self;
}

- (void)dealloc {
    [self unload];
}

- (BOOL)isLoaded {
    return _model != nullptr && _ctx != nullptr;
}

- (NSInteger)contextTokens {
    return _contextTokens;
}

- (GSLlamaStatus)loadModelAtPath:(NSString *)path
                   contextTokens:(NSInteger)contextTokens
                       gpuLayers:(NSInteger)gpuLayers
                         threads:(NSInteger)threads {

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return GSLlamaStatusModelNotFound;
    }

    [self unload];

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = (int32_t)gpuLayers;

    // mmap the weights rather than reading them. The kernel pages in only what
    // is touched, so a 4 GB model does not cost 4 GB of resident memory, and
    // iOS can evict clean pages under pressure instead of killing us.
    mparams.use_mmap = true;

    // Never mlock. Wiring gigabytes on a phone is the fastest possible route to
    // a jetsam kill, and it would starve the Archive's SQLite page cache.
    mparams.use_mlock = false;

    _model = llama_model_load_from_file([path UTF8String], mparams);
    if (_model == nullptr) {
        return GSLlamaStatusOutOfMemory;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = (uint32_t)contextTokens;
    cparams.n_threads = (int32_t)threads;
    cparams.n_threads_batch = (int32_t)threads;

    // Quantised KV cache. Halves the cache footprint at a quality cost that is
    // not measurable on a 0.6B-4B model, and the cache is what actually blows
    // the memory budget at long context.
    cparams.type_k = GGML_TYPE_Q8_0;
    cparams.type_v = GGML_TYPE_Q8_0;

    cparams.flash_attn = true;

    _ctx = llama_init_from_model(_model, cparams);
    if (_ctx == nullptr) {
        llama_model_free(_model);
        _model = nullptr;
        return GSLlamaStatusContextFailed;
    }

    _contextTokens = contextTokens;
    return GSLlamaStatusOK;
}

- (void)unload {
    if (_sampler) { llama_sampler_free(_sampler); _sampler = nullptr; }
    if (_ctx)     { llama_free(_ctx);             _ctx = nullptr; }
    if (_model)   { llama_model_free(_model);     _model = nullptr; }
    _contextTokens = 0;
}

- (void)requestCancel {
    _cancelFlag = true;
}

- (std::vector<llama_token>)tokenize:(NSString *)text addBos:(BOOL)addBos {
    const llama_vocab *vocab = llama_model_get_vocab(_model);
    std::string s = [text UTF8String];

    int32_t upper = (int32_t)s.size() + (addBos ? 1 : 0);
    std::vector<llama_token> out(upper);

    int32_t n = llama_tokenize(vocab, s.data(), (int32_t)s.size(),
                               out.data(), upper, addBos, false);
    if (n < 0) {
        out.resize(-n);
        n = llama_tokenize(vocab, s.data(), (int32_t)s.size(),
                           out.data(), (int32_t)out.size(), addBos, false);
    }
    out.resize(n > 0 ? n : 0);
    return out;
}

- (NSInteger)countTokens:(NSString *)text {
    if (!self.isLoaded) { return 0; }
    return (NSInteger)[self tokenize:text addBos:NO].size();
}

- (nullable NSString *)generateWithPrompt:(NSString *)prompt
                                 maxTokens:(NSInteger)maxTokens
                               temperature:(float)temperature
                                     topP:(float)topP
                            repeatPenalty:(float)repeatPenalty
                                 stopWords:(NSArray<NSString *> *)stopWords
                                  callback:(nullable GSTokenCallback)callback {

    if (!self.isLoaded) { return nil; }
    _cancelFlag = false;

    const llama_vocab *vocab = llama_model_get_vocab(_model);
    std::vector<llama_token> tokens = [self tokenize:prompt addBos:YES];
    if (tokens.empty()) { return nil; }

    // Refuse to start rather than silently truncating the grounding context.
    // A prompt that does not fit means PromptBuilder mis-budgeted, and a
    // half-truncated citation is worse than no answer at all (C3).
    if ((NSInteger)tokens.size() >= _contextTokens - maxTokens) {
        return nil;
    }

    llama_memory_clear(llama_get_memory(_ctx), true);

    if (_sampler) { llama_sampler_free(_sampler); }
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    _sampler = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(_sampler,
        llama_sampler_init_penalties(64, repeatPenalty, 0.0f, 0.0f));
    llama_sampler_chain_add(_sampler, llama_sampler_init_top_p(topP, 1));
    llama_sampler_chain_add(_sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(_sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    llama_batch batch = llama_batch_get_one(tokens.data(), (int32_t)tokens.size());
    if (llama_decode(_ctx, batch) != 0) {
        return nil;
    }

    std::string result;
    result.reserve(4096);
    char piece[256];

    for (NSInteger produced = 0; produced < maxTokens; produced++) {

        if (_cancelFlag.load()) { break; }

        llama_token id = llama_sampler_sample(_sampler, _ctx, -1);
        if (llama_vocab_is_eog(vocab, id)) { break; }

        int32_t n = llama_token_to_piece(vocab, id, piece, sizeof(piece), 0, false);
        if (n <= 0) { break; }

        NSString *chunk = [[NSString alloc] initWithBytes:piece
                                                   length:(NSUInteger)n
                                                 encoding:NSUTF8StringEncoding];
        if (chunk == nil) { continue; }

        result.append(piece, (size_t)n);

        if (callback != nil && callback(chunk) == NO) { break; }

        // Stop sequences are checked on the accumulated string, not per token,
        // because a stop word is frequently split across two tokens.
        BOOL hitStop = NO;
        NSString *soFar = [NSString stringWithUTF8String:result.c_str()];
        for (NSString *stop in stopWords) {
            if (stop.length > 0 && [soFar hasSuffix:stop]) {
                result.resize(result.size() - strlen([stop UTF8String]));
                hitStop = YES;
                break;
            }
        }
        if (hitStop) { break; }

        llama_batch next = llama_batch_get_one(&id, 1);
        if (llama_decode(_ctx, next) != 0) { break; }
    }

    return [NSString stringWithUTF8String:result.c_str()];
}

- (nullable NSArray<NSNumber *> *)embed:(NSString *)text {
    if (!self.isLoaded) { return nil; }

    std::vector<llama_token> tokens = [self tokenize:text addBos:YES];
    if (tokens.empty()) { return nil; }

    llama_memory_clear(llama_get_memory(_ctx), true);

    llama_batch batch = llama_batch_get_one(tokens.data(), (int32_t)tokens.size());
    if (llama_decode(_ctx, batch) != 0) { return nil; }

    const float *emb = llama_get_embeddings(_ctx);
    if (emb == nullptr) { return nil; }

    int32_t dim = llama_model_n_embd(_model);

    double norm = 0.0;
    for (int32_t i = 0; i < dim; i++) { norm += (double)emb[i] * (double)emb[i]; }
    norm = norm > 0.0 ? sqrt(norm) : 1.0;

    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)dim];
    for (int32_t i = 0; i < dim; i++) {
        [out addObject:@((double)emb[i] / norm)];
    }
    return out;
}

@end
