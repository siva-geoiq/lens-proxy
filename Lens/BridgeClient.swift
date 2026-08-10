import Foundation
import Network

struct JSONLineFramer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

final class BridgeClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lenskart.lens.bridge")
    private var connection: NWConnection?
    private var framer = JSONLineFramer()
    private var token = ""

    var onEnvelope: (@Sendable (BridgeEnvelope) -> Void)?
    var onStateChange: (@Sendable (NWConnection.State) -> Void)?

    func connect(port: UInt16, token: String) {
        disconnect()
        self.token = token
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
            if case .ready = state {
                self?.send(type: "authenticate", payload: ["token": token])
                self?.receiveNext()
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        framer = JSONLineFramer()
    }

    func send<T: Encodable & Sendable>(type: String, payload: T, requestID: String? = nil) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            do {
                let envelope = BridgeEnvelope(
                    protocolVersion: 1,
                    requestID: requestID,
                    type: type,
                    payload: try JSONValue(payload),
                    error: nil
                )
                var data = try JSONEncoder().encode(envelope)
                data.append(0x0A)
                connection.send(content: data, completion: .contentProcessed { _ in })
            } catch {
                let errorEnvelope = BridgeEnvelope(
                    protocolVersion: 1,
                    requestID: requestID,
                    type: "clientError",
                    payload: nil,
                    error: BridgeErrorPayload(code: "encode_failed", message: error.localizedDescription)
                )
                self.onEnvelope?(errorEnvelope)
            }
        }
    }

    func send(type: String) {
        send(type: type, payload: [String: String]())
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.consume(data) }
            if isComplete || error != nil {
                self.connection?.cancel()
                return
            }
            self.receiveNext()
        }
    }

    private func consume(_ data: Data) {
        for line in framer.append(data) {
            do {
                let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: line)
                onEnvelope?(envelope)
            } catch {
                onEnvelope?(
                    BridgeEnvelope(
                        protocolVersion: 1,
                        requestID: nil,
                        type: "clientError",
                        payload: nil,
                        error: BridgeErrorPayload(code: "decode_failed", message: error.localizedDescription)
                    )
                )
            }
        }
    }
}
