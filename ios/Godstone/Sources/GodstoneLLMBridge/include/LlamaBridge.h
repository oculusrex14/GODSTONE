#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C++ facade over llama.cpp.
///
/// Swift cannot see C++ directly, so every call into the model funnels through
/// this one header. Keeping the surface this small is deliberate: it is the only
/// place in the iOS app where a memory-unsafe language is reachable, and it is
/// the only file that has to be re-audited when llama.cpp is bumped.
///
/// Threading contract: every method here is BLOCKING and must never be called
/// from the main thread. LlamaRunner owns an actor that enforces this.

typedef NS_ENUM(NSInteger, GSLlamaStatus) {
    GSLlamaStatusOK = 0,
    GSLlamaStatusModelNotFound = 1,
    GSLlamaStatusOutOfMemory = 2,
    GSLlamaStatusContextFailed = 3,
    GSLlamaStatusCancelled = 4
};

/// Called for every decoded token. Return NO to stop generation immediately.
/// Invoked on the caller's thread, never on the main thread.
typedef BOOL (^GSTokenCallback)(NSString *token);

@interface GSLlamaBridge : NSObject

@property (nonatomic, readonly) BOOL isLoaded;
@property (nonatomic, readonly) NSInteger contextTokens;

/// Loads a GGUF model from an on-disk path.
///
/// gpuLayers is the number of transformer layers offloaded to Metal. On A-series
/// silicon the unified memory means offload is nearly free; on a thermally
/// throttled or low-battery device ModelManager passes 0 and we stay on CPU,
/// which is slower but draws far less power (constraint C4).
- (GSLlamaStatus)loadModelAtPath:(NSString *)path
                   contextTokens:(NSInteger)contextTokens
                       gpuLayers:(NSInteger)gpuLayers
                         threads:(NSInteger)threads;

/// Frees the model and the KV cache. Safe to call when nothing is loaded.
- (void)unload;

/// Blocking generation. Returns the full completion; tokens are also streamed
/// through the callback as they are produced so the UI can render immediately.
- (nullable NSString *)generateWithPrompt:(NSString *)prompt
                                 maxTokens:(NSInteger)maxTokens
                               temperature:(float)temperature
                                     topP:(float)topP
                            repeatPenalty:(float)repeatPenalty
                                 stopWords:(NSArray<NSString *> *)stopWords
                                  callback:(nullable GSTokenCallback)callback;

/// Cooperative cancellation. Sets a flag the decode loop checks every token.
- (void)requestCancel;

/// Token count for a string, using the model's own tokenizer. PromptBuilder
/// needs this to budget the context window honestly rather than guessing at
/// four characters per token.
- (NSInteger)countTokens:(NSString *)text;

/// Mean-pooled embedding from the model's own encoder, L2-normalised.
/// Used only when the prebuilt vector index misses; see RagPipeline.
- (nullable NSArray<NSNumber *> *)embed:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
