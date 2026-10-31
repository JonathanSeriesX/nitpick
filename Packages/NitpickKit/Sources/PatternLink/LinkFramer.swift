import Foundation
import Network

/// Length-prefixed framing for the link: a 4-byte big-endian body length followed by a JSON body.
/// A zero or over-limit length fails the connection.
final class LinkFramer: NWProtocolFramerImplementation {
  /// Largest accepted message body.
  static let maxMessageSize = 4 * 1024 * 1024
  static let definition = NWProtocolFramer.Definition(implementation: LinkFramer.self)
  static let label = "NitpickLink"

  init(framer: NWProtocolFramer.Instance) {}
  func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
  func wakeup(framer: NWProtocolFramer.Instance) {}
  func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
  func cleanup(framer: NWProtocolFramer.Instance) {}

  func handleOutput(
    framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int,
    isComplete: Bool
  ) {
    framer.writeOutput(data: withUnsafeBytes(of: UInt32(messageLength).bigEndian) { Data($0) })
    do { try framer.writeOutputNoCopy(length: messageLength) } catch {
      framer.markFailed(error: error as? NWError)
    }
  }

  func handleInput(framer: NWProtocolFramer.Instance) -> Int {
    while true {
      var length = 0
      let parsed = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, _ in
        guard let buffer, buffer.count >= 4 else { return 0 }
        length = Int(buffer.loadUnaligned(as: UInt32.self).bigEndian)
        return 4
      }
      guard parsed else { return 4 }
      guard (1...Self.maxMessageSize).contains(length) else {
        framer.markFailed(error: .posix(.EBADMSG))
        return 0
      }
      let message = NWProtocolFramer.Message(definition: Self.definition)
      // Delivers the body once it has fully arrived; returning 0 waits for more input.
      guard framer.deliverInputNoCopy(length: length, message: message, isComplete: true) else {
        return 0
      }
    }
  }
}

/// JSON coding used on the wire: sorted keys, ISO 8601 dates with millisecond precision.
public enum LinkCodec {
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// Encodes `value`; throws if the body exceeds the 4 MiB frame limit.
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(fractional.format(date))
    }
    let data = try encoder.encode(value)
    guard data.count <= LinkFramer.maxMessageSize else {
      throw EncodingError.invalidValue(
        value,
        .init(
          codingPath: [], debugDescription: "Message exceeds \(LinkFramer.maxMessageSize) bytes"))
    }
    return data
  }

  /// Decodes a message body. Accepts ISO 8601 dates with or without fractional seconds.
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let string = try decoder.singleValueContainer().decode(String.self)
      if let date = (try? fractional.parse(string))
        ?? (try? Date.ISO8601FormatStyle().parse(string))
      {
        return date
      }
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Bad ISO 8601 date: \(string)"))
    }
    return try decoder.decode(type, from: data)
  }
}

extension NWParameters {
  /// Inserts the link framer on top of the transport (and TLS, when present).
  func addingLinkFramer() -> NWParameters {
    defaultProtocolStack.applicationProtocols.insert(
      NWProtocolFramer.Options(definition: LinkFramer.definition), at: 0)
    return self
  }
}

extension NWConnection {
  /// Sends one framed message body.
  func sendFrame(_ body: Data, completion: @escaping @Sendable (NWError?) -> Void = { _ in }) {
    let context = ContentContext(
      identifier: "frame", metadata: [NWProtocolFramer.Message(definition: LinkFramer.definition)])
    send(
      content: body, contentContext: context, isComplete: true,
      completion: .contentProcessed(completion))
  }
}
