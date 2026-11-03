import Foundation

// MARK: - JSON values

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
}

// MARK: - Wire format: newline-delimited JSON

public struct ControlRequest: Codable, Equatable, Sendable {
    public var id: String
    public var cmd: String
    public var args: [String: JSONValue]

    public init(id: String = UUID().uuidString, cmd: String, args: [String: JSONValue] = [:]) {
        self.id = id
        self.cmd = cmd
        self.args = args
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        cmd = try container.decode(String.self, forKey: .cmd)
        args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: String?

    public static func success(id: String, _ result: JSONValue = .object([:])) -> ControlResponse {
        ControlResponse(id: id, ok: true, result: result, error: nil)
    }

    public static func failure(id: String, _ error: String) -> ControlResponse {
        ControlResponse(id: id, ok: false, result: nil, error: error)
    }
}

public enum ControlCoding {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ line: Data) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: line)
    }

    public static func decodeResponse(_ line: Data) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: line)
    }
}

public enum TiriPaths {
    /// `TIRI_HOME` isolates a test instance; real use never sets it.
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TIRI_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tiri", isDirectory: true)
    }

    public static var configDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TIRI_CONFIG_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tiri", isDirectory: true)
    }

    public static var socket: String {
        if let override = ProcessInfo.processInfo.environment["TIRI_SOCKET"], !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("control.sock").path
    }
}
