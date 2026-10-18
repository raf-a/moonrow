import Foundation

/// One JSON-RPC 2.0 message as MCP sends them: a request, a notification or a response.
public enum JSONRPCMessage: Sendable, Hashable {
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONValue, result: JSONValue?, error: JSONRPCError?)

    /// Reads one message. Batches (arrays) and anything that isn't JSON-RPC 2.0 fail.
    public static func parse(_ data: Data) throws(JSONRPCError) -> JSONRPCMessage {
        guard let value = try? JSONValue.decode(data) else { throw .parse }
        guard case .object(let o) = value else {
            throw value.array != nil ? JSONRPCError(code: -32600, message: "Batches are not supported") : .invalidRequest
        }
        guard o["jsonrpc"]?.string == "2.0" else { throw .invalidRequest }
        let id = o["id"]
        if let id, !Self.isValidID(id) { throw .invalidRequest }
        if let method = o["method"]?.string {
            if let id { return .request(id: id, method: method, params: o["params"]) }
            return .notification(method: method, params: o["params"])
        }
        guard let id, o["result"] != nil || o["error"] != nil else { throw .invalidRequest }
        let error = o["error"].flatMap { e -> JSONRPCError? in
            guard let code = e["code"]?.int else { return nil }
            return JSONRPCError(code: Int(code), message: e["message"]?.string ?? "", data: e["data"])
        }
        return .response(id: id, result: o["result"], error: error)
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int: true
        case .double(let d): d.rounded() == d
        default: false
        }
    }

    public var json: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            var o: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
            if let params { o["params"] = params }
            return .object(o)
        case .notification(let method, let params):
            var o: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
            if let params { o["params"] = params }
            return .object(o)
        case .response(let id, let result, let error):
            var o: [String: JSONValue] = ["jsonrpc": "2.0", "id": id]
            if let error { o["error"] = error.json } else { o["result"] = result ?? .object([:]) }
            return .object(o)
        }
    }

    public static func result(_ id: JSONValue, _ result: JSONValue) -> JSONRPCMessage {
        .response(id: id, result: result, error: nil)
    }

    public static func error(_ id: JSONValue?, _ error: JSONRPCError) -> JSONRPCMessage {
        .response(id: id ?? .null, result: nil, error: error)
    }
}

public struct JSONRPCError: Error, Sendable, Hashable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parse = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid request")
    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }
    public static func invalidParams(_ message: String) -> JSONRPCError { JSONRPCError(code: -32602, message: message) }
    public static let internalError = JSONRPCError(code: -32603, message: "internal_error")
    /// MCP's code for a resource that doesn't exist.
    public static func resourceNotFound(_ uri: String) -> JSONRPCError {
        JSONRPCError(code: -32002, message: "Resource not found", data: ["uri": .string(uri)])
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["code": .int(Int64(code)), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}
