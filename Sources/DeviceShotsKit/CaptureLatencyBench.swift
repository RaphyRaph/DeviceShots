import Foundation
import AppKit

/// Headless latency harness driven by `DEVICESHOTS_BENCH=*`.
///
/// Measures the same path as a global hotkey:
/// - trigger → clipboard (PNG / file URL on the pasteboard)
/// - trigger → paste (⌘V posted, when Accessibility allows)
///
/// Set `DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=1` to time rediscovery on the
/// critical path (legacy hotkey behavior). Combine with `DEVICESHOTS_OPT_*`.
enum CaptureLatencyBench {
    struct Sample: Codable {
        var iteration: Int
        var deviceName: String
        var deviceKind: String
        var triggerToClipboardMs: Double?
        var triggerToPasteMs: Double?
        var deviceToolMs: Double?
        var discoveryMs: Double?
        /// Time from tool result → pasteboard readiness (app delivery path).
        var deliveryOverheadMs: Double?
        /// Time from pasteboard → ⌘V posted (nil when paste was not measured).
        var pasteDeltaMs: Double?
        var ok: Bool
        var pasted: Bool?
        var error: String?
    }

    struct Report: Codable {
        var deviceName: String
        var deviceKind: String
        var iterations: Int
        var warmup: Int
        var measuredPaste: Bool
        var includeDiscovery: Bool
        var opts: String
        var samples: [Sample]
        var clipboardMs: Stats?
        var pasteMs: Stats?
        var deviceToolMs: Stats?
        var discoveryMs: Stats?
        var deliveryOverheadMs: Stats?
        var pasteDeltaMs: Stats?
    }

    struct Stats: Codable {
        var count: Int
        var min: Double
        var median: Double
        var mean: Double
        var max: Double
    }

    @MainActor
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["DEVICESHOTS_BENCH"] == "1" else { return }
        Task { @MainActor in
            await run()
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func run() async {
        let env = ProcessInfo.processInfo.environment
        let iterations = max(1, Int(env["DEVICESHOTS_BENCH_ITERATIONS"] ?? "2") ?? 2)
        let warmup = max(0, Int(env["DEVICESHOTS_BENCH_WARMUP"] ?? "1") ?? 1)
        let index = max(0, Int(env["DEVICESHOTS_BENCH_INDEX"] ?? "0") ?? 0)
        let measurePaste = env["DEVICESHOTS_BENCH_PASTE"] != "0"
        let includeDiscovery = env["DEVICESHOTS_BENCH_INCLUDE_DISCOVERY"] == "1"
            || LatencyOpts.forceHotkeyRefresh
        let outPath = env["DEVICESHOTS_BENCH_OUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("deviceshots-latency.json").path

        // Keep delivery on the fast image-only path for comparable numbers.
        let defaults = UserDefaults.standard
        defaults.set(ClipboardMode.image.rawValue, forKey: Prefs.clipboardMode)
        defaults.set(false, forKey: Prefs.saveToFolder)
        defaults.set(false, forKey: Prefs.playSound)

        let store = DeviceStore.shared
        await store.refresh()

        guard store.devices.indices.contains(index), store.devices[index].available else {
            let report = emptyFailureReport(
                warmup: warmup,
                measuredPaste: measurePaste,
                includeDiscovery: includeDiscovery,
                error: "No available device at index \(index). Open the menu once or connect a device."
            )
            write(report, to: outPath)
            fputs("BENCH FAIL: no available device at index \(index)\n", stderr)
            return
        }

        let device = store.devices[index]
        fputs(
            "BENCH measuring \(device.name) (\(device.kind)) — \(warmup) warmup + \(iterations) timed, paste=\(measurePaste) discovery=\(includeDiscovery) opts={\(LatencyOpts.summary)}\n",
            stderr
        )

        for _ in 0..<warmup {
            _ = await store.measureCaptureLatency(
                of: device,
                thenPaste: false,
                includeDiscovery: includeDiscovery
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        var samples: [Sample] = []
        for i in 1...iterations {
            var sample = await store.measureCaptureLatency(
                of: device,
                thenPaste: measurePaste,
                includeDiscovery: includeDiscovery
            )
            sample.iteration = i
            samples.append(sample)
            let clip = sample.triggerToClipboardMs.map { String(format: "%.1f", $0) } ?? "—"
            let paste = sample.triggerToPasteMs.map { String(format: "%.1f", $0) } ?? "—"
            let disc = sample.discoveryMs.map { String(format: "%.1f", $0) } ?? "—"
            fputs(
                "BENCH iter \(i)/\(iterations) clipboard_ms=\(clip) paste_ms=\(paste) discovery_ms=\(disc) ok=\(sample.ok)\n",
                stderr
            )
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let report = Report(
            deviceName: device.name,
            deviceKind: String(describing: device.kind),
            iterations: iterations,
            warmup: warmup,
            measuredPaste: measurePaste,
            includeDiscovery: includeDiscovery,
            opts: LatencyOpts.summary,
            samples: samples,
            clipboardMs: stats(samples.compactMap(\.triggerToClipboardMs)),
            pasteMs: stats(samples.compactMap(\.triggerToPasteMs)),
            deviceToolMs: stats(samples.compactMap(\.deviceToolMs)),
            discoveryMs: stats(samples.compactMap(\.discoveryMs)),
            deliveryOverheadMs: stats(samples.compactMap(\.deliveryOverheadMs)),
            pasteDeltaMs: stats(samples.compactMap(\.pasteDeltaMs))
        )
        write(report, to: outPath)
        fputs("BENCH wrote \(outPath)\n", stderr)
    }

    private static func emptyFailureReport(
        warmup: Int,
        measuredPaste: Bool,
        includeDiscovery: Bool,
        error: String
    ) -> Report {
        Report(
            deviceName: "",
            deviceKind: "",
            iterations: 0,
            warmup: warmup,
            measuredPaste: measuredPaste,
            includeDiscovery: includeDiscovery,
            opts: LatencyOpts.summary,
            samples: [
                Sample(
                    iteration: 0,
                    deviceName: "",
                    deviceKind: "",
                    triggerToClipboardMs: nil,
                    triggerToPasteMs: nil,
                    deviceToolMs: nil,
                    discoveryMs: nil,
                    deliveryOverheadMs: nil,
                    pasteDeltaMs: nil,
                    ok: false,
                    pasted: nil,
                    error: error
                )
            ],
            clipboardMs: nil,
            pasteMs: nil,
            deviceToolMs: nil,
            discoveryMs: nil,
            deliveryOverheadMs: nil,
            pasteDeltaMs: nil
        )
    }

    private static func stats(_ values: [Double]) -> Stats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let sum = sorted.reduce(0, +)
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
        return Stats(
            count: sorted.count,
            min: sorted.first!,
            median: median,
            mean: sum / Double(sorted.count),
            max: sorted.last!
        )
    }

    private static func write(_ report: Report, to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            fputs("BENCH FAIL: could not write \(path): \(error)\n", stderr)
        }
    }
}

extension DeviceStore {
    /// Timed capture used by `CaptureLatencyBench`. Mirrors hotkey capture without UI noise.
    @MainActor
    func measureCaptureLatency(
        of device: Device,
        thenPaste: Bool,
        includeDiscovery: Bool = false
    ) async -> CaptureLatencyBench.Sample {
        let clock = ContinuousClock()
        let trigger = clock.now

        var discoveryMs: Double?
        var target = device
        if includeDiscovery {
            await refresh()
            discoveryMs = (clock.now - trigger).milliseconds
            if let match = devices.first(where: { $0.id == device.id }), match.available {
                target = match
            } else if devices.indices.contains(0), devices[0].available {
                target = devices[0]
            }
        }

        let toolStart = clock.now
        let outcome = await DeviceDiscovery.captureScreenshot(of: target)
        let afterTool = clock.now
        let toolMs = (afterTool - toolStart).milliseconds

        switch outcome {
        case .success(let png):
            do {
                _ = try deliver(png, from: target)
                let afterClipboard = clock.now
                let clipboardMs = (afterClipboard - trigger).milliseconds
                let deliveryOverheadMs = (afterClipboard - afterTool).milliseconds

                var pasted: Bool?
                var pasteMs: Double?
                var pasteDeltaMs: Double?
                if thenPaste {
                    pasted = simulatePasteForBench()
                    pasteMs = (clock.now - trigger).milliseconds
                    pasteDeltaMs = pasteMs.map { $0 - clipboardMs }
                }

                return CaptureLatencyBench.Sample(
                    iteration: 0,
                    deviceName: target.name,
                    deviceKind: String(describing: target.kind),
                    triggerToClipboardMs: clipboardMs,
                    triggerToPasteMs: pasteMs,
                    deviceToolMs: toolMs,
                    discoveryMs: discoveryMs,
                    deliveryOverheadMs: deliveryOverheadMs,
                    pasteDeltaMs: pasteDeltaMs,
                    ok: true,
                    pasted: pasted,
                    error: nil
                )
            } catch {
                return CaptureLatencyBench.Sample(
                    iteration: 0,
                    deviceName: target.name,
                    deviceKind: String(describing: target.kind),
                    triggerToClipboardMs: nil,
                    triggerToPasteMs: nil,
                    deviceToolMs: toolMs,
                    discoveryMs: discoveryMs,
                    deliveryOverheadMs: nil,
                    pasteDeltaMs: nil,
                    ok: false,
                    pasted: nil,
                    error: error.localizedDescription
                )
            }
        case .failure(let error):
            return CaptureLatencyBench.Sample(
                iteration: 0,
                deviceName: target.name,
                deviceKind: String(describing: target.kind),
                triggerToClipboardMs: nil,
                triggerToPasteMs: nil,
                deviceToolMs: toolMs,
                discoveryMs: discoveryMs,
                deliveryOverheadMs: nil,
                pasteDeltaMs: nil,
                ok: false,
                pasted: nil,
                error: error.message
            )
        }
    }

    /// Same as production paste, but never prompts for Accessibility during bench runs.
    fileprivate func simulatePasteForBench() -> Bool {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) else {
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        return keyDown != nil && keyUp != nil
    }
}

private extension Duration {
    var milliseconds: Double {
        let comps = components
        return Double(comps.seconds) * 1_000 + Double(comps.attoseconds) / 1e15
    }
}
