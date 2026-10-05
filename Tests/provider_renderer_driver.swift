// Standalone driver for synthetic, independent template-oracle comparisons.
// The narrow stubs satisfy the request-builder references; only the production renderer runs here.
import Foundation

struct Conversation {}
struct GenerationSettings {
    var endpointURL = "http://localhost:11234/v1"
    var endpointModel = Qwen38TextAdapter.modelID
    var endpointAPIKey = ""
    var maximumOutput = 512
    var temperature = 0.2
    var seed = 42
    var thinkingEnabled = false
    func messages(_ prompt: String, conversation: Conversation) -> [[String: String]] { [] }
}
enum LocalEndpoint {
    static func chatURL(_ address: String) -> URL? { URL(string: address) }
}

@main enum ProviderRendererDriver {
    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let bodies = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let outputs = bodies.map { body -> [String: String] in
            do { return ["rendered": try Qwen38TextAdapter.render(body)] }
            catch { return ["error": "rejected"] }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: outputs))
    }
}
