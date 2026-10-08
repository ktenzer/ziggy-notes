import Foundation
import Temporal

/// Provider-agnostic structured LLM completion used by the analysis, identity,
/// and summary activities.
///
/// Following the Temporal AI patterns: provider-side retries are disabled (we
/// own retries via Temporal) and provider failures are translated into
/// `ApplicationError` with the right retryable/non-retryable classification.
struct LLMClient: Sendable {
    let config: WorkerConfig

    /// Pick the provider based on preference AND which key is present, matching
    /// Python `resolve_provider`. Throws a RETRYABLE `NoLLMKey` when neither key
    /// is set (so the activity retries until a key is available).
    func resolveProvider() throws -> String {
        let pref = config.llmProvider.lowercased()
        let hasOpenAI = !(config.openaiApiKey ?? "").isEmpty
        let hasAnthropic = !(config.anthropicApiKey ?? "").isEmpty
        if pref == "anthropic" {
            if hasAnthropic { return "anthropic" }
            if hasOpenAI { return "openai" }
        } else {
            if hasOpenAI { return "openai" }
            if hasAnthropic { return "anthropic" }
        }
        throw ApplicationError(
            message: "No LLM API key set. Set OPENAI_API_KEY or ANTHROPIC_API_KEY (and LLM_PROVIDER) and restart the worker; this activity will retry until a key is available.",
            type: "NoLLMKey"
        )
    }

    /// Run a structured completion with whichever provider is available and decode
    /// the JSON response into `T`. `jsonHint` describes the expected JSON shape.
    func structuredCompletion<T: Decodable>(
        system: String, user: String, jsonHint: String, as _: T.Type
    ) async throws -> T {
        let provider = try resolveProvider()
        if provider == "anthropic" {
            return try await anthropic(system: system, user: user, jsonHint: jsonHint)
        }
        return try await openAI(system: system, user: user, jsonHint: jsonHint)
    }

    // MARK: - OpenAI

    private func openAI<T: Decodable>(system: String, user: String, jsonHint: String) async throws -> T {
        guard let key = config.openaiApiKey, !key.isEmpty else {
            throw ApplicationError(message: "OPENAI_API_KEY is not set", type: "NoLLMKey")
        }
        let sys = system + "\n\nReturn ONLY a single JSON object (no markdown, no prose) of this shape:\n" + jsonHint
        let body: [String: Any] = [
            "model": config.model(for: "openai"),
            "messages": [
                ["role": "system", "content": sys],
                ["role": "user", "content": user],
            ],
            "temperature": 0.3,
            "response_format": ["type": "json_object"],
        ]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, status) = try await send(req, provider: "OpenAI")
        try Self.classify(status: status, data: data, provider: "OpenAI")
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw ApplicationError(message: "OpenAI returned no content", type: "LLMError")
        }
        // A "length" finish means the JSON was cut off mid-response.
        if let finish = first["finish_reason"] as? String, finish == "length" {
            throw ApplicationError(
                message: "OpenAI response was truncated (finish_reason=length); the transcript is too long to return in one structured response.",
                type: "LLMError", isNonRetryable: true
            )
        }
        return try Self.decode(content, provider: "OpenAI")
    }

    // MARK: - Anthropic

    private func anthropic<T: Decodable>(system: String, user: String, jsonHint: String) async throws -> T {
        guard let key = config.anthropicApiKey, !key.isEmpty else {
            throw ApplicationError(message: "ANTHROPIC_API_KEY is not set", type: "NoLLMKey")
        }
        let sys = system + "\n\nReturn ONLY a single JSON object that matches this shape (no markdown, no prose):\n" + jsonHint
        // The summary can be sizable (summary + attendees + key points + action
        // items + next steps + feedback). A small cap truncates the response
        // mid-JSON on longer meetings ("Unexpected end of file"); allow the
        // model's full output budget instead.
        let maxTokens = 8192
        let body: [String: Any] = [
            "model": config.model(for: "anthropic"),
            "max_tokens": maxTokens,
            "system": sys,
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, status) = try await send(req, provider: "Anthropic")
        try Self.classify(status: status, data: data, provider: "Anthropic")
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = obj["content"] as? [[String: Any]]
        else {
            throw ApplicationError(message: "Anthropic returned no content", type: "LLMError")
        }
        // A "max_tokens" stop means the JSON was cut off; surface that clearly and
        // non-retryably rather than failing with a confusing decode error (and
        // without retrying a deterministically-too-long request forever).
        if let stop = obj["stop_reason"] as? String, stop == "max_tokens" {
            throw ApplicationError(
                message: "Anthropic response was truncated at max_tokens=\(maxTokens); the transcript is too long to return in one structured response.",
                type: "LLMError", isNonRetryable: true
            )
        }
        let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
        return try Self.decode(text, provider: "Anthropic")
    }

    // MARK: - Helpers

    private func send(_ req: URLRequest, provider: String) async throws -> (Data, Int) {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            throw ApplicationError(message: "\(provider) connection error: \(error)", type: "ConnectionError")
        }
    }

    /// Map an HTTP status to a retryable/non-retryable `ApplicationError`,
    /// mirroring Python's `_classify_*_error`.
    private static func classify(status: Int, data: Data, provider: String) throws {
        if (200..<300).contains(status) { return }
        let detail = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
        switch status {
        case 401, 403:
            // Retryable: a fixed key + restart recovers (unlimited-retry design).
            throw ApplicationError(message: "\(provider) auth error \(status): \(detail)", type: "AuthenticationError")
        case 429:
            throw ApplicationError(message: "\(provider) rate limited: \(detail)", type: "RateLimitError")
        case 500...:
            throw ApplicationError(message: "\(provider) server error \(status): \(detail)", type: "ServerError")
        default:
            throw ApplicationError(message: "\(provider) client error \(status): \(detail)", type: "ClientError", isNonRetryable: true)
        }
    }

    private static func decode<T: Decodable>(_ raw: String, provider: String) throws -> T {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "`", with: "")
            if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
                text = String(text[start...end])
            }
        }
        guard let data = text.data(using: .utf8) else {
            throw ApplicationError(message: "\(provider) returned undecodable text", type: "LLMError")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApplicationError(message: "\(provider) returned non-conforming JSON: \(error)", type: "LLMError")
        }
    }
}
