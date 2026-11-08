import Foundation

/// A model reached with someone's own API key: titles and search for a Mac without Apple Intelligence.
/// The key lives in the keychain, never in settings.json, which agents read and `tiri settings` prints.
public struct KeyedModel: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case anthropic, openai
        /// Anything that speaks OpenAI's chat completions: DeepSeek, Qwen, Kimi, OpenRouter, Ollama…
        case other
    }

    public var provider: Provider
    public var model: String
    /// Only for `other`, like `https://api.deepseek.com/v1`.
    public var baseURL: String
    public var key: String

    public init(provider: Provider, model: String, baseURL: String = "", key: String) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.key = key
    }

    /// Small and quick is right for a title of a few words. Anyone can type another.
    public static func suggestedModel(_ provider: Provider) -> String {
        switch provider {
        case .anthropic: "claude-haiku-5-5"
        case .openai: "gpt-5.4-mini"
        case .other: ""
        }
    }

    /// Who the excerpts go to, to say so where it's chosen and where it's used.
    public var providerName: String {
        switch provider {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .other: URL(string: baseURL)?.host ?? baseURL
        }
    }

    public var isComplete: Bool {
        let model = model.trimmingCharacters(in: .whitespaces), key = key.trimmingCharacters(in: .whitespaces)
        return !model.isEmpty && !key.isEmpty && (provider != .other || endpoint != nil)
    }

    var endpoint: URL? {
        switch provider {
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")
        case .openai: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .other:
            var base = baseURL.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
            guard let url = URL(string: base + "/chat/completions"), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
            return url
        }
    }

    /// One question, one answer: the instructions, then what they apply to.
    public func request(instructions: String, input: String) -> URLRequest? {
        guard let endpoint else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = model.trimmingCharacters(in: .whitespaces), key = key.trimmingCharacters(in: .whitespaces)
        var body: [String: Any]
        switch provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            // Thinking counts toward max_tokens, so there's room for a little before the few words.
            body = ["model": model, "max_tokens": 1024, "system": instructions,
                    "messages": [["role": "user", "content": input]]]
            // Older models refuse effort; on the current ones, low keeps a title quick.
            if Self.takesEffort(model) { body["output_config"] = ["effort": "low"] }
        case .openai, .other:
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            body = ["model": model, "messages": [["role": "system", "content": instructions], ["role": "user", "content": input]]]
            // Others mostly don't know it, and some refuse what they don't know.
            if provider == .openai, model.hasPrefix("gpt-5") { body["reasoning_effort"] = "low" }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func takesEffort(_ model: String) -> Bool {
        guard let match = model.firstMatch(of: /^claude-[a-z]+-(\d+)/), let major = Int(match.1) else { return false }
        return major >= 5
    }

    /// The words it answered with, or nil when it answered nothing usable.
    public func answer(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let text: String?
        switch provider {
        case .anthropic:
            if object["stop_reason"] as? String == "refusal" { return nil }
            let blocks = (object["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            text = blocks.compactMap { $0["text"] as? String }.joined()
        case .openai, .other:
            let message = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            text = message?["content"] as? String
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What went wrong, in the service's own words when it gave some.
    public static func problem(status: Int, data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let said = (object?["error"] as? [String: Any])?["message"] as? String ?? object?["message"] as? String
        if let said, !said.isEmpty { return "\(status): \(said)" }
        return "\(status): " + HTTPURLResponse.localizedString(forStatusCode: status)
    }
}
