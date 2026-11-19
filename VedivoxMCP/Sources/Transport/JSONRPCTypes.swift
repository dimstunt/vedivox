import Foundation

// MARK: - AnyCodable

/// Type-erased Codable wrapper for arbitrary JSON values.
///
/// Supports: nil, Bool, Int, Double, String, `[AnyCodable]`, `[String: AnyCodable]`.
package struct AnyCodable: Sendable {
    package let value: Any & Sendable

    package init(_ value: Any & Sendable) {
        self.value = value
    }

    // Convenience factory methods
    package static let null = AnyCodable(NullValue.null)
    package static func bool(_ v: Bool) -> AnyCodable { AnyCodable(v) }
    package static func int(_ v: Int) -> AnyCodable { AnyCodable(v) }
    package static func double(_ v: Double) -> AnyCodable { AnyCodable(v) }
    package static func string(_ v: String) -> AnyCodable { AnyCodable(v) }
    package static func array(_ v: [AnyCodable]) -> AnyCodable { AnyCodable(v) }
    package static func object(_ v: [String: AnyCodable]) -> AnyCodable { AnyCodable(v) }

    /// Returns the value as Double, converting from Int if needed.
    package var asDouble: Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

/// Sentinel type for JSON null.
private enum NullValue: Sendable {
    case null
}

extension AnyCodable: Decodable {
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NullValue.null
            return
        }
        if let boolVal = try? container.decode(Bool.self) {
            self.value = boolVal
            return
        }
        if let intVal = try? container.decode(Int.self) {
            self.value = intVal
            return
        }
        if let doubleVal = try? container.decode(Double.self) {
            self.value = doubleVal
            return
        }
        if let stringVal = try? container.decode(String.self) {
            self.value = stringVal
            return
        }
        if let arrayVal = try? container.decode([AnyCodable].self) {
            self.value = arrayVal
            return
        }
        if let dictVal = try? container.decode([String: AnyCodable].self) {
            self.value = dictVal
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "AnyCodable: unsupported JSON value"
        )
    }
}

extension AnyCodable: Encodable {
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NullValue:
            try container.encodeNil()
        case let boolVal as Bool:
            try container.encode(boolVal)
        case let intVal as Int:
            try container.encode(intVal)
        case let doubleVal as Double:
            try container.encode(doubleVal)
        case let stringVal as String:
            try container.encode(stringVal)
        case let arrayVal as [AnyCodable]:
            try container.encode(arrayVal)
        case let dictVal as [String: AnyCodable]:
            try container.encode(dictVal)
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "AnyCodable: unsupported type \(type(of: value))"
                )
            )
        }
    }
}

// MARK: - RequestId

/// JSON-RPC request ID — may be an integer or a string.
package enum RequestId: Sendable {
    case int(Int)
    case string(String)
}

extension RequestId: Decodable {
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RequestId must be Int or String"
            )
        }
    }
}

extension RequestId: Encodable {
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        }
    }
}

// MARK: - JSONRPCRequest

/// Incoming JSON-RPC 2.0 request or notification.
package struct JSONRPCRequest: Decodable, Sendable {
    package let jsonrpc: String
    package let id: RequestId?
    package let method: String
    package let params: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        // Only an absent id makes a notification. MCP forbids `"id": null`, and
        // reading it as absent left a client waiting for an answer that never came.
        id = container.contains(.id) ? try container.decode(RequestId.self, forKey: .id) : nil
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent([String: AnyCodable].self, forKey: .params)
    }
}

// MARK: - JSONRPCResponse

/// Outgoing JSON-RPC 2.0 response.
package struct JSONRPCResponse: Encodable, Sendable {
    package let jsonrpc: String = "2.0"
    package let id: RequestId?
    package let result: AnyCodable?
    package let error: JSONRPCErrorDetail?

    package init(id: RequestId?, result: AnyCodable) {
        self.id = id
        self.result = result
        self.error = nil
    }

    package init(id: RequestId?, error: JSONRPCErrorDetail) {
        self.id = id
        self.result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    /// `id` is always present: JSON-RPC answers a request it could not parse with `"id": null`.
    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

// MARK: - JSONRPCErrorDetail

/// JSON-RPC error object.
package struct JSONRPCErrorDetail: Encodable, Sendable {
    package let code: Int
    package let message: String

    package init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}
