import Foundation
import Testing
@testable import TiriCore

@Suite struct KeyedModelTests {
    func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anthropicGetsItsHeadersAndALowEffortOnCurrentModels() throws {
        let keyed = KeyedModel(provider: .anthropic, model: "claude-haiku-5-5", key: " sk-ant-x ")
        let request = keyed.request(instructions: "Title it.", input: "fix the build")
        #expect(request?.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-x")
        #expect(request?.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = try body(request)
        #expect(body["system"] as? String == "Title it.")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        // An older model refuses effort.
        #expect(try self.body(KeyedModel(provider: .anthropic, model: "claude-haiku-4-5", key: "k").request(instructions: "", input: ""))["output_config"] == nil)
    }

    @Test func othersAreChatCompletionsAtTheirOwnAddress() throws {
        let keyed = KeyedModel(provider: .other, model: "deepseek-chat", baseURL: "https://api.deepseek.com/v1/", key: "sk-1")
        let request = keyed.request(instructions: "Title it.", input: "x")
        #expect(request?.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        #expect(try body(request)["reasoning_effort"] == nil)
        #expect(keyed.providerName == "api.deepseek.com")
        // Pasting the whole endpoint works as well.
        #expect(KeyedModel(provider: .other, model: "m", baseURL: "http://localhost:11434/v1/chat/completions", key: "k")
            .request(instructions: "", input: "")?.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(!KeyedModel(provider: .other, model: "m", baseURL: "deepseek", key: "k").isComplete)
        #expect(!KeyedModel(provider: .anthropic, model: "m", key: "  ").isComplete)
    }

    @Test func answersAreReadFromEitherShape() {
        let anthropic = KeyedModel(provider: .anthropic, model: "m", key: "k")
        let said = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":" Fix the build \n"}],"stop_reason":"end_turn"}"#
        #expect(anthropic.answer(from: Data(said.utf8)) == "Fix the build")
        #expect(anthropic.answer(from: Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)) == nil)
        let openai = KeyedModel(provider: .openai, model: "m", key: "k")
        #expect(openai.answer(from: Data(#"{"choices":[{"message":{"role":"assistant","content":"修复构建"}}]}"#.utf8)) == "修复构建")
        #expect(KeyedModel.problem(status: 401, data: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)) == "401: invalid x-api-key")
    }
}
