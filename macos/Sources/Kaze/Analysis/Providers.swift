import Foundation

/// Anthropic Messages API. Structured output via output_config.format; first text block is
/// the schema-validated JSON. Images go as base64 content blocks.
struct AnthropicProvider: LLMProvider {
    let apiKey: String
    let model: String
    var maxTokens = 8000

    func completeJSON(system: String, user: String, images: [Data], schema: [String: Any]) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": user]]
        for (i, image) in images.enumerated() {
            content.append(["type": "text", "text": "Image \(i + 1):"])
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": "image/jpeg",
                "data": image.base64EncodedString(),
            ]])
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]
        let json = try await LLMHTTP.postJSON(
            "https://api.anthropic.com/v1/messages",
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
            body: body)

        if json["stop_reason"] as? String == "refusal" {
            throw LLMError.refusal((json["stop_details"] as? [String: Any])?["category"] as? String)
        }
        guard let blocks = json["content"] as? [[String: Any]] else { throw LLMError.emptyResponse }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String { return text }
        }
        throw LLMError.emptyResponse
    }
}

/// OpenAI Chat Completions. Structured output via response_format json_schema (strict).
/// Images go as data-URL image_url content parts.
struct OpenAIProvider: LLMProvider {
    let apiKey: String
    let model: String
    var maxTokens = 8000

    func completeJSON(system: String, user: String, images: [Data], schema: [String: Any]) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": user]]
        for (i, image) in images.enumerated() {
            content.append(["type": "text", "text": "Image \(i + 1):"])
            content.append(["type": "image_url", "image_url": [
                "url": "data:image/jpeg;base64,\(image.base64EncodedString())",
            ]])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "kaze_analysis", "strict": true, "schema": schema],
            ],
            "max_completion_tokens": maxTokens,
        ]
        let json = try await LLMHTTP.postJSON(
            "https://api.openai.com/v1/chat/completions",
            headers: ["authorization": "Bearer \(apiKey)"],
            body: body)

        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.emptyResponse
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw LLMError.refusal(refusal)
        }
        guard let text = message["content"] as? String, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        return text
    }
}

/// Google Gemini generateContent. Structured output via generationConfig.responseSchema.
/// Images go as inline_data parts.
struct GeminiProvider: LLMProvider {
    let apiKey: String
    let model: String
    var maxTokens = 8000

    func completeJSON(system: String, user: String, images: [Data], schema: [String: Any]) async throws -> String {
        var parts: [[String: Any]] = [["text": user]]
        for (i, image) in images.enumerated() {
            parts.append(["text": "Image \(i + 1):"])
            parts.append(["inline_data": [
                "mime_type": "image/jpeg", "data": image.base64EncodedString(),
            ]])
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": SchemaTranslator.toGemini(schema),
                "maxOutputTokens": maxTokens,
            ],
        ]
        // Key goes in a header (x-goog-api-key), never in the URL.
        let json = try await LLMHTTP.postJSON(
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent",
            headers: ["x-goog-api-key": apiKey],
            body: body)

        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            // A blocked prompt returns promptFeedback instead of candidates.
            if let feedback = json["promptFeedback"] as? [String: Any],
               let reason = feedback["blockReason"] as? String {
                throw LLMError.refusal(reason)
            }
            throw LLMError.emptyResponse
        }
        if let reason = first["finishReason"] as? String,
           reason != "STOP" && reason != "MAX_TOKENS" {
            throw LLMError.refusal(reason)
        }
        guard let content = first["content"] as? [String: Any],
              let outParts = content["parts"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }
        let text = outParts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
