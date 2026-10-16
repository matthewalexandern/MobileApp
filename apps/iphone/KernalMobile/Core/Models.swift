import Foundation

public struct Status: Codable, Sendable, Equatable {
    public let apiVersion: String
    public let userDisplayName: String
    public let modelName: String
    public let nativeContextTarget: Int
    public let capabilities: [String]
    public init(apiVersion: String, userDisplayName: String, modelName: String, nativeContextTarget: Int, capabilities: [String]) {
        self.apiVersion = apiVersion; self.userDisplayName = userDisplayName; self.modelName = modelName
        self.nativeContextTarget = nativeContextTarget; self.capabilities = capabilities
    }
    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version", userDisplayName = "user_display_name", modelName = "model_name"
        case nativeContextTarget = "native_context_target", capabilities
    }
}

public struct ChatSession: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public init(id: String, title: String, createdAt: Date) {
        self.id = id; self.title = title; self.createdAt = createdAt
    }
    enum CodingKeys: String, CodingKey { case id, title, createdAt = "created_at" }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    public let createdAt: Date
    public init(id: String, role: String, text: String, createdAt: Date) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
    }
    enum CodingKeys: String, CodingKey { case id, role, text, createdAt = "created_at" }
}

public struct ChatTurn: Codable, Sendable, Equatable {
    public let user: ChatMessage
    public let assistant: ChatMessage
    public let memoryStatus: String
    public init(user: ChatMessage, assistant: ChatMessage, memoryStatus: String) {
        self.user = user; self.assistant = assistant; self.memoryStatus = memoryStatus
    }
    enum CodingKeys: String, CodingKey { case user, assistant, memoryStatus = "memory_status" }
}

public struct MemoryItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let title: String
    public let body: String
    public let origin: String
    public let sourceURL: String
    public let updatedAt: Date
    public let canForget: Bool
    public init(id: String, kind: String, title: String, body: String, origin: String, sourceURL: String, updatedAt: Date, canForget: Bool) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.origin = origin
        self.sourceURL = sourceURL; self.updatedAt = updatedAt; self.canForget = canForget
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, origin, sourceURL = "source_url", updatedAt = "updated_at", canForget = "can_forget"
    }
}
