import Foundation
import UIKit
import GodstoneCore

/// Decides which model to load, whether Metal may be used, and when to evict.
///
/// The model is the single largest resource in the app. Getting this wrong does
/// not produce a slow app, it produces a jetsam kill in the middle of somebody
/// looking up how to stop a bleed. Every policy below exists because of C4
/// (battery is life) and C5 (degrade, never fail).
public final class ModelManager: @unchecked Sendable {

    public static let shared = ModelManager()

    private let runner = LlamaRunner()
    private var currentTier: Tier?
    private var evictionTask: Task<Void, Never>?

    /// Idle eviction. Holding a quantised 4B model resident while the user reads
    /// a manual for ten minutes buys nothing and risks everything.
    private static let idleEvictionSeconds: UInt64 = 180

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil) { [weak self] _ in
                // Non-negotiable: the Archive must stay readable (C5). The model
                // is the first thing overboard, always.
                Task { await self?.evictNow() }
            }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil) { [weak self] _ in
                Task { await self?.evictNow() }
            }
    }

    // MARK: - Tier and capability

    public var bundledModelPath: String? {
        Bundle.main.path(forResource: Tier.current.modelFile, ofType: nil)
            ?? modelURLInAppSupport()?.path
    }

    private func modelURLInAppSupport() -> URL? {
        // LARGE tier ships the weights as a downloadable pack (tab 11), so the
        // file lives in Application Support rather than the bundle.
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory,
                                in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent("models")
                     .appendingPathComponent(Tier.current.modelFile)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Metal offload is granted only when the device is not already in trouble.
    /// A hot or nearly flat phone runs on CPU: measurably slower, dramatically
    /// less power, and it will not thermally throttle into uselessness.
    private var permittedGpuLayers: Int {
        UIDevice.current.isBatteryMonitoringEnabled = true

        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let thermal = ProcessInfo.processInfo.thermalState

        if thermal == .serious || thermal == .critical { return 0 }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 0 }
        if level >= 0, level < 0.15, state != .charging { return 0 }

        return 99   // offload everything; unified memory makes this cheap
    }

    private var permittedThreads: Int {
        // Performance cores only. Spilling onto efficiency cores adds heat and
        // scheduler churn for almost no additional tokens per second.
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func ensureLoaded() async throws -> LlamaRunner {
        guard let path = bundledModelPath else {
            throw LlamaRunner.RunnerError.modelMissing
        }

        let tier = Tier.current

        do {
            try await runner.load(path: path,
                                  contextTokens: tier.contextTokens,
                                  gpuLayers: permittedGpuLayers,
                                  threads: permittedThreads)
        } catch LlamaRunner.RunnerError.outOfMemory {
            // Degrade rather than fail (C5): retry once at half context, which
            // roughly halves the KV cache, the thing that actually blew up.
            try await runner.load(path: path,
                                  contextTokens: max(1024, tier.contextTokens / 2),
                                  gpuLayers: 0,
                                  threads: permittedThreads)
        }

        currentTier = tier
        scheduleEviction()
        return runner
    }

    public func touch() {
        scheduleEviction()
    }

    private func scheduleEviction() {
        evictionTask?.cancel()
        evictionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ModelManager.idleEvictionSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.evictNow()
        }
    }

    public func evictNow() async {
        await runner.cancel()
        await runner.unload()
        currentTier = nil
    }
}
