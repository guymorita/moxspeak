import Testing
import Foundation
@testable import SpeakeasyCore

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func ok(_ data: Data, url: URL) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                     headerFields: ["Content-Type": "audio/pcm"])!, data)
}

// MARK: - Tests
//
// These tests all share one process-wide `StubURLProtocol.handler`. Swift Testing runs
// @Test functions concurrently by default, which races on that shared static and produces
// cross-test contamination (test A's request served by test B's handler). `.serialized`
// forces this suite's tests to run one at a time so the shared stub is safe under the
// default `swift test` invocation, with no flags required at the call site.

@Suite(.serialized)
struct OpenAICompatibleProviderTests {

    @Test func sendsCorrectRequestBody() async throws {
        nonisolated(unsafe) var captured: Data?
        StubURLProtocol.handler = { request in
            captured = request.httpBodyStreamData() ?? request.httpBody
            return ok(Data(count: 48000), url: request.url!)
        }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        _ = try await provider.synthesize(text: "hello", voice: "af_bella", speed: 1.0)

        let json = try JSONSerialization.jsonObject(with: #require(captured)) as! [String: Any]
        #expect(json["input"] as? String == "hello")
        #expect(json["voice"] as? String == "af_bella")
        #expect(json["response_format"] as? String == "pcm")
        #expect(json["stream"] as? Bool == true)
        // unit_normalization defaults to false upstream and must be turned on.
        let norm = json["normalization_options"] as! [String: Any]
        #expect(norm["unit_normalization"] as? Bool == true)
    }

    @Test func returnsAudioBytes() async throws {
        StubURLProtocol.handler = { request in ok(Data(count: 96000), url: request.url!) }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        let data = try await provider.synthesize(text: "hello", voice: "v", speed: 1.0)
        #expect(data.count == 96000)
    }

    @Test func mapsNonSuccessStatusToSpeechError() async {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                             headerFields: nil)!, Data("server exploded".utf8))
        }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        await #expect(throws: SpeechError.httpStatus(code: 500, body: "server exploded")) {
            try await provider.synthesize(text: "hello", voice: "v", speed: 1.0)
        }
    }

    @Test func parsesVoiceList() async throws {
        let payload = Data("""
        {"voices":[{"id":"af_bella","name":"af_bella"},{"id":"af_sky","name":"af_sky"}]}
        """.utf8)
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "application/json"])!, payload)
        }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        let voices = try await provider.listVoices()
        #expect(voices.count == 2)
        #expect(voices.first?.id == "af_bella")
    }

    @Test func identityProbeRejectsAServiceThatIsNotATtsEngine() async {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "text/html"])!,
             Data("<html><body>hello from some other app</body></html>".utf8))
        }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        let identified = await provider.identityProbe()
        #expect(identified == false)
    }

    @Test func identityProbeAcceptsAValidVoiceList() async {
        let payload = Data(#"{"voices":[{"id":"af_bella","name":"af_bella"}]}"#.utf8)
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "application/json"])!, payload)
        }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        #expect(await provider.identityProbe() == true)
    }

    @Test func identityProbeRejectsAnEmptyVoiceList() async {
        // This is the security gate, not a nicety: `identityProbe` is what stands between
        // the user's selected text and an unidentified endpoint. A server that answers
        // `{"voices":[]}` has proven nothing about being a TTS engine, so it must be
        // rejected. Relaxing the check to `return true` has to fail here.
        let payload = Data(#"{"voices":[]}"#.utf8)
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["Content-Type": "application/json"])!, payload)
        }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        #expect(await provider.identityProbe() == false)
    }

    @Test func cancelledTransportErrorIsMappedToCancellationError() async {
        // Load-bearing mapping: `SpeechSession.render` catches `CancellationError` to tell
        // "the user replaced the selection" apart from "the backend failed". Without this
        // translation a deliberately cancelled chunk would surface as `.failed` with a
        // URLError, and the cancellation path in `render` would never run.
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        await #expect(throws: CancellationError.self) {
            try await provider.synthesize(text: "hello", voice: "v", speed: 1.0)
        }
    }

    @Test func otherTransportErrorsAreNotMappedToCancellation() async {
        // The counterpart: a genuine network failure must stay a SpeechError, or every
        // backend outage would be silently swallowed as "cancelled".
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let provider = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880),
                                                session: stubbedSession())
        await #expect(throws: SpeechError.self) {
            try await provider.synthesize(text: "hello", voice: "v", speed: 1.0)
        }
    }
}

// Helper: URLProtocol receives the body as a stream for async uploads.
extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
