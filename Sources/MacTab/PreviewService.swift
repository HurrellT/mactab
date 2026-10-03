import AppKit
import ScreenCaptureKit
import OSLog

/// One small still per visible card, only while expanded. No streams or disk cache.
final class PreviewService {
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.tlh.mactab", category: "previews")
    func cancel() { task?.cancel(); task = nil }

    func load(pid: pid_t, windows: [WindowItem], indices: [Int],
              status: @escaping (String?) -> Void, completion: @escaping (Int, NSImage) -> Void) {
        cancel()
        guard CGPreflightScreenCaptureAccess() else {
            status("Screen Recording required")
            return
        }
        status(nil)
        task = Task { @MainActor in
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Window inventory failed: \(error.localizedDescription, privacy: .public)")
                status("Previews unavailable · check permissions")
                return
            }
            guard !Task.isCancelled else { return }
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            var captured = 0
            var captureFailed = false
            for index in indices {
                guard !Task.isCancelled, windows.indices.contains(index) else { return }
                let window = windows[index]
                guard !window.isMinimized else { continue }
                let idMatches = candidates.filter { $0.windowID == window.windowID }
                // If a private AX bridge reports an ID absent from ScreenCaptureKit,
                // retain the public geometry/title fallback instead of losing the preview.
                let matches = idMatches.isEmpty ? candidates.filter {
                    return abs($0.frame.minX - window.frame.minX) < 3 && abs($0.frame.minY - window.frame.minY) < 3 &&
                    abs($0.frame.width - window.frame.width) < 3 && abs($0.frame.height - window.frame.height) < 3 &&
                    ($0.title == window.title || window.title == "Untitled window")
                } : idMatches
                guard matches.count == 1, let source = matches.first else { continue }
                let config = SCStreamConfiguration()
                let scale = min(480 / max(source.frame.width, 1), 320 / max(source.frame.height, 1))
                config.width = max(1, Int(source.frame.width * scale))
                config.height = max(1, Int(source.frame.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                do {
                    let cgImage = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: config)
                    guard !Task.isCancelled else { return }
                    // Give the custom drawing code a concrete, nonzero logical size.
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    completion(index, image)
                    captured += 1
                } catch {
                    guard !Task.isCancelled else { return }
                    captureFailed = true
                    logger.error("Window screenshot failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if captured == 0, !indices.isEmpty {
                status(captureFailed ? "Previews unavailable · check permissions" : "No capturable window previews")
            }
        }
    }
}
