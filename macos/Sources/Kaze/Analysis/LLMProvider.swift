import Foundation

/// Which LLM provider powers the daily analysis. Keys are stored per-provider so you can
/// configure several and switch between them.
enum LLMProviderKind: String, CaseIterable, Identifiable {
    case anthropic, openai, google
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (GPT)"
        case .google: return "Google (Gemini)"
        }
    }

    /// Sensible, widely-available defaults. All are editable in Settings — set a newer
    /// model id (e.g. a GPT-5 / Gemini 2.5 variant) when you have access.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openai: return "gpt-4o"
        case .google: return "gemini-2.0-flash"
        }
    }

    var keyHint: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .google: return "AIza…"
        }
    }

    var keychainAccount: String { "api-key-\(rawValue)" }

    /// Env vars that override the Keychain (handy for headless/cron runs).
    var envVars: [String] {
        switch self {
        case .anthropic: return ["ANTHROPIC_API_KEY", "KAZE_ANTHROPIC_API_KEY"]
        case .openai: return ["OPENAI_API_KEY", "KAZE_OPENAI_API_KEY"]
        case .google: return ["GEMINI_API_KEY", "GOOGLE_API_KEY", "KAZE_GOOGLE_API_KEY"]
        }
    }
}

enum LLMError: Error, CustomStringConvertible {
    case noProvider
    case http(status: Int, body: String)
    case refusal(String?)
    case emptyResponse
    case transport(String)

    var description: String {
        switch self {
        case .noProvider: return "No API key set for the selected provider (Settings → AI Analysis)."
        case .http(let s, let b): return "API error \(s): \(b.prefix(300))"
        case .refusal(let c): return "Request refused by the model's safety filter (\(c ?? "unknown"))."
        case .emptyResponse: return "The model returned no usable content."
        case .transport(let m): return "Network error: \(m)"
        }
    }
}

/// A provider takes a system + user prompt (optionally with JPEG images for vision) and a
/// JSON schema, and returns the model's JSON string (validated against the schema by the
/// provider's structured-output mode). All three providers support vision.
protocol LLMProvider {
    func completeJSON(system: String, user: String, images: [Data], schema: [String: Any]) async throws -> String
}

extension LLMProvider {
    func completeJSON(system: String, user: String, schema: [String: Any]) async throws -> String {
        try await completeJSON(system: system, user: user, images: [], schema: schema)
    }
}

/// Active-provider + per-provider model selection, persisted in UserDefaults.
enum LLMSettings {
    private static let providerKey = "kaze.llm.provider"

    static var activeProvider: LLMProviderKind {
        get { LLMProviderKind(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    static func model(for kind: LLMProviderKind) -> String {
        let v = UserDefaults.standard.string(forKey: "kaze.llm.model.\(kind.rawValue)")
        return (v?.isEmpty == false) ? v! : kind.defaultModel
    }

    static func setModel(_ model: String, for kind: LLMProviderKind) {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed.isEmpty ? kind.defaultModel : trimmed,
                                  forKey: "kaze.llm.model.\(kind.rawValue)")
    }

    /// Builds the active provider, or nil if its key isn't set.
    static func makeActiveProvider() -> (provider: LLMProvider, kind: LLMProviderKind, model: String)? {
        let kind = activeProvider
        guard let key = APIKeyStore.key(for: kind) else { return nil }
        let model = model(for: kind)
        let provider: LLMProvider
        switch kind {
        case .anthropic: provider = AnthropicProvider(apiKey: key, model: model)
        case .openai: provider = OpenAIProvider(apiKey: key, model: model)
        case .google: provider = GeminiProvider(apiKey: key, model: model)
        }
        return (provider, kind, model)
    }
}

/// Shared JSON POST helper with a long timeout (daily prompts can be large).
enum LLMHTTP {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    static func postJSON(_ urlString: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw LLMError.transport("bad URL: \(urlString)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw LLMError.transport(error.localizedDescription) }

        guard let http = response as? HTTPURLResponse else { throw LLMError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.emptyResponse
        }
        return json
    }
}

/// Translates our JSON Schema into the OpenAPI-subset dialect Gemini's responseSchema wants
/// (uppercase types, no additionalProperties).
enum SchemaTranslator {
    static func toGemini(_ schema: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        if let type = schema["type"] as? String { out["type"] = type.uppercased() }
        if let props = schema["properties"] as? [String: Any] {
            var newProps: [String: Any] = [:]
            for (k, v) in props {
                if let vd = v as? [String: Any] { newProps[k] = toGemini(vd) }
            }
            out["properties"] = newProps
        }
        if let items = schema["items"] as? [String: Any] { out["items"] = toGemini(items) }
        if let required = schema["required"] as? [String] { out["required"] = required }
        if let e = schema["enum"] as? [String] { out["enum"] = e }
        return out
    }
}
