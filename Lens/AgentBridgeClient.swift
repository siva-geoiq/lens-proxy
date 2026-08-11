import Foundation
import Network

struct LengthPrefixedJSONFramer {
    private var buffer = Data()
    private let maximumFrameLength = 4 * 1024 * 1024

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard length <= maximumFrameLength else { throw AgentBridgeError.frameTooLarge(length) }
            guard buffer.count >= length + 4 else { break }
            frames.append(Data(buffer[4..<(length + 4)]))
            buffer.removeSubrange(0..<(length + 4))
        }
        return frames
    }
}

final class AgentBridgeClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lenskart.lens.android-agent")
    private var connection: NWConnection?
    private var framer = LengthPrefixedJSONFramer()
    private var token = ""
    private var port: UInt16?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var shouldReconnect = false

    var onEnvelope: (@Sendable (AgentEnvelope) -> Void)?
    var onStateChange: (@Sendable (NWConnection.State) -> Void)?

    func connect(port: UInt16, token: String) {
        queue.async { [weak self] in
            guard let self else { return }
            stopConnection()
            self.port = port
            self.token = token
            shouldReconnect = true
            reconnectAttempt = 0
            startConnection()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            shouldReconnect = false
            port = nil
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            stopConnection()
        }
    }

    func send(type: String, payload: JSONValue = .object([:])) {
        queue.async { [weak self] in
            guard let self, let connection else { return }
            do {
                let envelope = AgentEnvelope(protocolVersion: 1, token: nil, type: type, payload: payload, error: nil)
                let encoded = try JSONEncoder().encode(envelope)
                var frame = Data([
                    UInt8((encoded.count >> 24) & 0xff),
                    UInt8((encoded.count >> 16) & 0xff),
                    UInt8((encoded.count >> 8) & 0xff),
                    UInt8(encoded.count & 0xff)
                ])
                frame.append(encoded)
                connection.send(content: frame, completion: .contentProcessed { _ in })
            } catch {
                onEnvelope?(
                    AgentEnvelope(
                        protocolVersion: 1,
                        token: nil,
                        type: "clientError",
                        payload: nil,
                        error: BridgeErrorPayload(code: "encode_failed", message: error.localizedDescription)
                    )
                )
            }
        }
    }

    private func receiveNext() {
        guard let activeConnection = connection else { return }
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak activeConnection] data, _, complete, error in
            guard let self else { return }
            if let data { consume(data) }
            if complete || error != nil {
                if let activeConnection, connection === activeConnection {
                    activeConnection.cancel()
                    connection = nil
                    scheduleReconnect()
                }
            } else {
                receiveNext()
            }
        }
    }

    private func startConnection() {
        guard shouldReconnect, connection == nil, let port, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let candidate = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        connection = candidate
        framer = LengthPrefixedJSONFramer()
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, connection === candidate else { return }
            onStateChange?(state)
            switch state {
            case .ready:
                reconnectAttempt = 0
                send(type: "authenticate", payload: .object(["token": .string(token)]))
                receiveNext()
            case .failed, .waiting:
                candidate.cancel()
                connection = nil
                scheduleReconnect()
            case .cancelled:
                connection = nil
                scheduleReconnect()
            default:
                break
            }
        }
        candidate.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectWorkItem == nil else { return }
        let delay = min(0.15 * pow(2, Double(reconnectAttempt)), 2)
        reconnectAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            reconnectWorkItem = nil
            startConnection()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func stopConnection() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        framer = LengthPrefixedJSONFramer()
    }

    private func consume(_ data: Data) {
        do {
            for frame in try framer.append(data) {
                onEnvelope?(try JSONDecoder().decode(AgentEnvelope.self, from: frame))
            }
        } catch {
            onEnvelope?(
                AgentEnvelope(
                    protocolVersion: 1,
                    token: nil,
                    type: "clientError",
                    payload: nil,
                    error: BridgeErrorPayload(code: "decode_failed", message: error.localizedDescription)
                )
            )
        }
    }
}

enum AgentBridgeError: LocalizedError {
    case frameTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case let .frameTooLarge(length): "Android inspector frame is too large (\(length) bytes)."
        }
    }
}
