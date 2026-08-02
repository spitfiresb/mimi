import Foundation

enum MimiError: LocalizedError {
    case transcriberUnavailable
    case noSupportedLocale
    case noCompatibleAudioFormat
    case audioConversionUnsupported
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            return "SpeechTranscriber is unavailable on this machine."
        case .noSupportedLocale:
            return "No supported locale for transcription."
        case .noCompatibleAudioFormat:
            return "No audio format compatible with the transcriber."
        case .audioConversionUnsupported:
            return "Cannot convert microphone audio to the transcriber's format."
        case .notPrepared:
            return "Speech engine is not ready yet."
        }
    }
}
