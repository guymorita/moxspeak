import Foundation

public struct EngineConfig: Sendable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    public var outputFormat: AudioFormat
    public var recommendedCharacterCap: Int
    public var supportsIncrementalStreaming: Bool
    public var requestTimeout: TimeInterval

    public init(baseURL: URL,
                model: String,
                apiKey: String? = nil,
                outputFormat: AudioFormat = .kokoroPCM,
                recommendedCharacterCap: Int = 150,
                supportsIncrementalStreaming: Bool = true,
                requestTimeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.outputFormat = outputFormat
        self.recommendedCharacterCap = recommendedCharacterCap
        self.supportsIncrementalStreaming = supportsIncrementalStreaming
        self.requestTimeout = requestTimeout
    }

    /// The bootstrapped local engine. The port is supplied by EngineSupervisor
    /// in the app-shell plan; there is no auto-discovery.
    public static func kokoroLocal(port: Int) -> EngineConfig {
        EngineConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                     model: "kokoro")
    }
}

/// Speaks the OpenAI `/v1/audio/speech` shape, which Kokoro-FastAPI, OpenAI, Groq and
/// most local servers all implement.
public struct OpenAICompatibleProvider: SpeechProvider {

    private let config: EngineConfig
    private let session: URLSession

    public init(config: EngineConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var outputFormat: AudioFormat { config.outputFormat }
    public var supportsIncrementalStreaming: Bool { config.supportsIncrementalStreaming }
    public var recommendedCharacterCap: Int { config.recommendedCharacterCap }

    /// Always false, and not configurable.
    ///
    /// Every server behind this shape — Kokoro-FastAPI, OpenAI, Groq — normalizes text on its
    /// own before phonemizing. Sending it text we have already normalized is not a no-op: the
    /// server's rules run again over our output and mangle it ("five dollars" picks up a
    /// second "dollars" from a `$` we already consumed). Normalization belongs to the engine
    /// that owns the phonemizer, and for this provider that engine is remote.
    public var requiresTextNormalization: Bool { false }

    public func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        var request = URLRequest(url: config.baseURL.appending(path: "/v1/audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": config.model,
            "input": text,
            "voice": voice,
            "speed": speed,
            "response_format": responseFormatName,
            "stream": config.supportsIncrementalStreaming,
            // unit_normalization defaults to false upstream; "10KB" is unspoken without it.
            "normalization_options": ["normalize": true, "unit_normalization": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SpeechError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpeechError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpeechError.httpStatus(code: http.statusCode, body: body)
        }
        return data
    }

    public func listVoices() async throws -> [Voice] {
        var request = URLRequest(url: config.baseURL.appending(path: "/v1/audio/voices"))
        request.timeoutInterval = config.requestTimeout
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SpeechError.badResponse("voice list unavailable")
        }

        struct Payload: Decodable {
            struct Entry: Decodable { let id: String; let name: String? }
            let voices: [Entry]
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return decoded.voices.map { Voice(id: $0.id, name: $0.name ?? $0.id) }
    }

    /// Confirms this endpoint is actually a compatible TTS engine before any user text
    /// is sent to it. A port is not an identity.
    public func identityProbe() async -> Bool {
        do {
            let voices = try await listVoices()
            return !voices.isEmpty
        } catch {
            return false
        }
    }

    private var responseFormatName: String {
        config.outputFormat.isRawPCM ? "pcm" : "mp3"
    }
}
