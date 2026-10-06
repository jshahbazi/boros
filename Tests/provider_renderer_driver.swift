// Standalone driver for synthetic, independent template-oracle comparisons.
// The narrow stubs satisfy the request-builder references; only the production renderer runs here.
import Foundation

// The renderer never uses cleanup accounting; keep the standalone closure narrow.
struct EpisodeCleanupLimits: Codable, Equatable {
    static let defaults = EpisodeCleanupLimits()
}
struct Conversation {}
struct GenerationSettings {
    var endpointURL = "http://localhost:11234/v1"
    var endpointModel = Qwen38TextAdapter.modelID
    var endpointAPIKey = ""
    var maximumOutput = 512
    var temperature = 0.2
    var seed = 42
    var thinkingEnabled = false
    var endpointJSONOutput = false
    func messages(_ prompt: String, conversation: Conversation) -> [[String: String]] { [] }
}
enum LocalEndpoint {
    static func chatURL(_ address: String) -> URL? { URL(string: address) }
}

@main enum ProviderRendererDriver {
    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let bodies = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let outputs = bodies.map { body -> [String: Any] in
            var result: [String: Any] = ["json_contract_version": Qwen38TextRendering.jsonObjectRenderingVersion,
                "json_instruction_sha256": EndpointRequest.digest(Data(Qwen38TextRendering.jsonObjectInstruction.utf8)),
                "json_instruction_pin": Qwen38TextRendering.jsonObjectInstructionSHA256,
                "json_instruction_bytes": Qwen38TextRendering.jsonObjectInstruction.utf8.count]
            do {
                var request = body
                let labels = request.removeValue(forKey: "oracle_assignments") as? [String]
                let assignments = try labels.map { values in try values.map { value in
                    guard let component = ProviderMessageComponent(rawValue: value) else { throw QwenTextRenderingError.invalidRequest }
                    return component
                } }
                let rendered = try Qwen38TextAdapter.renderAttributed(request, assignments: assignments)
                result["rendered"] = rendered.complete; result["recent"] = rendered.recent; result["evidence"] = rendered.evidence
            } catch { result["error"] = "rejected" }
            return result
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: outputs))
    }
}
