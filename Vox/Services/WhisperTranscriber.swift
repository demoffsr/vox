import Foundation
#if canImport(SwiftWhisper)
import SwiftWhisper
#endif

final class WhisperTranscriber: NSObject, @unchecked Sendable {
    #if canImport(SwiftWhisper)
    private var whisper: Whisper?
    private var pendingContinuation: CheckedContinuation<String, Error>?
    #endif

    func loadModel() throws {
        guard let modelPath = Bundle.main.path(forResource: "ggml-small.en-q5_1", ofType: "bin") else {
            throw WhisperError.modelNotFound
        }
        #if canImport(SwiftWhisper)
        let modelURL = URL(fileURLWithPath: modelPath)
        whisper = Whisper(fromFileURL: modelURL)
        whisper?.delegate = self
        #else
        print("[WhisperTranscriber] SwiftWhisper not available — add via Xcode SPM")
        #endif
    }

    func transcribe(audioFrames: [Float]) async throws -> String {
        #if canImport(SwiftWhisper)
        guard let whisper else { throw WhisperError.modelNotLoaded }

        print("[WhisperTranscriber] Starting transcription of \(audioFrames.count) samples...")

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            Task.detached {
                do {
                    let segments = try await whisper.transcribe(audioFrames: audioFrames)
                    let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    print("[WhisperTranscriber] Result: \(text)")
                    // If delegate didn't fire, resolve here
                    if let cont = self.pendingContinuation {
                        self.pendingContinuation = nil
                        cont.resume(returning: text)
                    }
                } catch {
                    if let cont = self.pendingContinuation {
                        self.pendingContinuation = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        #else
        throw WhisperError.modelNotLoaded
        #endif
    }

    enum WhisperError: Error, LocalizedError {
        case modelNotFound
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "Whisper model file not found in bundle"
            case .modelNotLoaded: return "Whisper model not loaded. Call loadModel() first."
            }
        }
    }
}

#if canImport(SwiftWhisper)
extension WhisperTranscriber: WhisperDelegate {
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {
        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        print("[WhisperTranscriber] Delegate completed: \(text)")
    }

    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {}
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {
        print("[WhisperTranscriber] Delegate error: \(error)")
    }
}
#endif
