import Foundation
#if canImport(SwiftWhisper)
import SwiftWhisper
#endif

final class WhisperTranscriber: @unchecked Sendable {
    #if canImport(SwiftWhisper)
    private var whisper: Whisper?
    #endif

    private let processingQueue = DispatchQueue(label: "com.vox.whisper", qos: .userInitiated)
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

    func transcribe(audioFrames: [Float], completion: @escaping (String?) -> Void) {
        #if canImport(SwiftWhisper)
        guard let whisper else {
            completion(nil)
            return
        }

        // Skip if already processing
        guard !isBusy else {
            print("[WhisperTranscriber] Skipping — already busy")
            completion(nil)
            return
        }

        isBusy = true
        print("[WhisperTranscriber] Starting transcription of \(audioFrames.count) samples...")

        processingQueue.async { [weak self] in
            let group = DispatchGroup()
            group.enter()

            var resultText: String?

            Task {
                do {
                    let segments = try await whisper.transcribe(audioFrames: audioFrames)
                    resultText = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    print("[WhisperTranscriber] Result: \(resultText ?? "")")
                } catch {
                    print("[WhisperTranscriber] Error: \(error)")
                }
                group.leave()
            }

            // Wait up to 60 seconds (first run is slow due to model warmup)
            let timeout = group.wait(timeout: .now() + 60)
            self?.isBusy = false

            if timeout == .timedOut {
                print("[WhisperTranscriber] TIMEOUT — transcription took too long")
                completion(nil)
            } else {
                completion(resultText)
            }
        }
        #else
        completion(nil)
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
