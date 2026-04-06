import Foundation
#if canImport(SwiftWhisper)
import SwiftWhisper
#endif

final class WhisperTranscriber: @unchecked Sendable {
    #if canImport(SwiftWhisper)
    private var whisper: Whisper?
    #endif

    private var isBusy = false

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
        guard !isBusy else {
            print("[WhisperTranscriber] Skipping chunk — already busy")
            return ""
        }

        isBusy = true
        defer { isBusy = false }

        print("[WhisperTranscriber] Starting transcription of \(audioFrames.count) samples...")
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        print("[WhisperTranscriber] Result: \(text)")
        return text
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
