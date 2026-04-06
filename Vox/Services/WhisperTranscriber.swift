import Foundation
#if canImport(SwiftWhisper)
import SwiftWhisper
#endif

final class WhisperTranscriber: @unchecked Sendable {
    #if canImport(SwiftWhisper)
    private var whisper: Whisper?
    #endif

    func loadModel() throws {
        guard let modelPath = Bundle.main.path(forResource: "ggml-small.en-q5_1", ofType: "bin") else {
            throw WhisperError.modelNotFound
        }
        #if canImport(SwiftWhisper)
        let modelURL = URL(fileURLWithPath: modelPath)
        whisper = Whisper(fromFileURL: modelURL)
        #else
        print("[WhisperTranscriber] SwiftWhisper not available — add via Xcode SPM")
        #endif
    }

    func transcribe(audioFrames: [Float]) async throws -> String {
        #if canImport(SwiftWhisper)
        guard let whisper else { throw WhisperError.modelNotLoaded }
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        return segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
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
