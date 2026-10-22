import Foundation

/// Serial IPC away from the UI actor. Mutations and their acknowledgements stay ordered.
public actor ServiceConnection {
    private let client: ServiceClient
    public init(path: String = TetherPaths.serviceSocket) { client = ServiceClient(path: path) }
    public func perform(_ request: ServiceRequest, preflight: (@Sendable () throws -> Void)? = nil) throws -> ServiceReply {
        // The caller may have waited behind another RPC. Validate at this actor's
        // entry, immediately before creating or sending the client's request.
        try preflight?()
        return try client.perform(request)
    }
    public func write(_ operation: @Sendable () -> Bool) throws -> ServiceReply {
        guard operation() else { throw ServiceFailure("writeFailed") }
        return try client.perform(ServiceRequest(.snapshot))
    }
}
