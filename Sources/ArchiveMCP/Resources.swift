// MCP resources over one archive (DESIGN 9A). Every message is
// `emailarchiver://message/<id>` and every thread is
// `emailarchiver://thread/<id>`, so clients that browse resources can
// attach them. Like the tools, the resource layer is read-only: it
// opens no connection and writes nothing; message-derived text is
// wrapped as untrusted. Listing pages with a cursor so a large archive
// never returns one unbounded response.

import ArchiveCore
import Foundation
import MCP

enum ArchiveResources {
    static let scheme = "emailarchiver://"
    /// Resource entries returned per listing page.
    static let pageSize = 500
    /// Body characters per message resource, same cap class as the tools.
    static let maxBodyChars = ArchiveTools.maxBodyChars

    // MARK: Listing

    /// The URI shapes a client can fill in from the templates.
    static func templates() -> [Resource.Template] {
        [
            Resource.Template(
                uriTemplate: "\(scheme)message/{id}",
                name: "Archived message",
                description: """
                One archived message as JSON: headers, subject, from, \
                date, thread id, and the rendered body text (untrusted).
                """,
                mimeType: "application/json"
            ),
            Resource.Template(
                uriTemplate: "\(scheme)thread/{id}",
                name: "Archived thread",
                description: """
                One archived conversation as JSON: the thread's stored \
                subject and every message in it, in conversation order.
                """,
                mimeType: "application/json"
            ),
        ]
    }

    /// One page of resources. The cursor is `"m:<id>"` while messages are
    /// being listed and `"t:<id>"` for threads; `nil`/`""` starts at the
    /// first message. The page ends when a full page of threads runs out,
    /// or when both tables are exhausted (`nextCursor` nil).
    static func list(
        cursor: String?, store: ArchiveStore
    ) throws -> ListResources.Result {
        let raw = cursor ?? "m:0"
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let after = Int64(parts[1]),
            parts[0] == "m" || parts[0] == "t"
        else {
            throw ArchiveTools.ToolError.badArguments("bad cursor: \(raw)")
        }

        switch parts[0] {
        case "m":
            let messages = try store.listMessages(after: after, limit: pageSize)
            var resources = messages.map(messageResource)
            if messages.count == pageSize {
                return ListResources.Result(
                    resources: resources,
                    nextCursor: "m:\(messages.last!.id)"
                )
            }
            // Messages exhausted: continue into threads on the same page.
            let remaining = pageSize - messages.count
            let threads = try store.listThreads(after: 0, limit: remaining)
            resources += threads.map(threadResource)
            if threads.count == remaining {
                return ListResources.Result(
                    resources: resources,
                    nextCursor: "t:\(threads.last!.id)"
                )
            }
            return ListResources.Result(resources: resources, nextCursor: nil)
        default:
            let threads = try store.listThreads(after: after, limit: pageSize)
            let resources = threads.map(threadResource)
            if threads.count == pageSize {
                return ListResources.Result(
                    resources: resources,
                    nextCursor: "t:\(threads.last!.id)"
                )
            }
            return ListResources.Result(resources: resources, nextCursor: nil)
        }
    }

    static func messageResource(_ summary: MessageSummary) -> Resource {
        Resource(
            name: summary.subject ?? "Message \(summary.id)",
            uri: "\(scheme)message/\(summary.id)",
            description: """
            From \(summary.fromEmail ?? "unknown"), \
            \(iso(summary.dateReceived ?? summary.dateSent)) \
            (\(summary.size) bytes)
            """,
            mimeType: "application/json"
        )
    }

    static func threadResource(_ ref: ThreadRef) -> Resource {
        Resource(
            name: ref.subject ?? "Thread \(ref.id)",
            uri: "\(scheme)thread/\(ref.id)",
            description: "An archived conversation.",
            mimeType: "application/json"
        )
    }

    // MARK: Reading

    /// One resource's content. Unknown schemes and ids fail the request;
    /// nothing is ever invented to fill a gap.
    static func read(
        _ uri: String, store: ArchiveStore
    ) throws -> ReadResource.Result {
        guard uri.hasPrefix(scheme) else {
            throw ArchiveTools.ToolError.badArguments(
                "unknown resource scheme: \(uri)"
            )
        }
        let rest = uri.dropFirst(scheme.count)
        let segments = rest.split(separator: "/")
        guard segments.count == 2, let id = Int64(segments[1]) else {
            throw ArchiveTools.ToolError.badArguments(
                "bad resource URI: \(uri)"
            )
        }

        let value: Value
        switch segments[0] {
        case "message":
            value = try messageJSON(id: id, store: store)
        case "thread":
            value = try threadJSON(id: id, store: store)
        default:
            throw ArchiveTools.ToolError.badArguments(
                "unknown resource kind: \(segments[0])"
            )
        }
        let text = ArchiveTools.render(value)
        return ReadResource.Result(
            contents: [
                .text(text, uri: uri, mimeType: "application/json")
            ]
        )
    }

    /// One message as JSON. The shape mirrors the get_message tool (same
    /// untrusted wrapping, same body cap) with the raw store data left out:
    /// resource readers want the readable message, not its bytes.
    static func messageJSON(
        id: Int64, store: ArchiveStore, maxBodyChars: Int = maxBodyChars
    ) throws -> Value {
        guard let summary = try store.message(id: id) else {
            throw ArchiveTools.ToolError.notFound("message id \(id)")
        }
        let data = try store.messageData(summary.hash)
        let headers = MailBridge.headerFields(for: data)
        let headerObject = Value.object(
            Dictionary(
                uniqueKeysWithValues: headers.map { ($0.name, Value.string($0.value)) }
            )
        )

        var body = MailBridge.messageBody(for: data) ?? ""
        let truncated = body.count > maxBodyChars
        if truncated { body = String(body.prefix(maxBodyChars)) }
        let bodyValue: Value = body.isEmpty
            ? .null
            : .string(ArchiveTools.untrusted("message body", body))

        return .object([
            "id": .int(Int(summary.id)),
            "thread_id": .optional(summary.threadID.map { .int(Int($0)) }),
            "date": .string(iso(summary.dateReceived ?? summary.dateSent)),
            "from": .string(addressLine(summary)),
            "headers": headerObject,
            "subject": summary.subject.map {
                .string(ArchiveTools.untrusted("subject", $0))
            } ?? .null,
            "body": bodyValue,
            "body_truncated": .bool(truncated),
        ])
    }

    /// One thread as JSON: the stored subject and every message in it, in
    /// conversation order (the threadMessages ordering).
    static func threadJSON(id: Int64, store: ArchiveStore) throws -> Value {
        guard let subject = try store.threadSubject(threadID: id) else {
            throw ArchiveTools.ToolError.notFound("thread id \(id)")
        }
        let messages = try store.threadMessages(threadID: id)
        let messageValues = messages.map { summary -> Value in
            .object([
                "id": .int(Int(summary.id)),
                "date": .string(iso(summary.dateReceived ?? summary.dateSent)),
                "from": .string(addressLine(summary)),
                "subject": summary.subject.map {
                    .string(ArchiveTools.untrusted("subject", $0))
                } ?? .null,
            ])
        }
        return .object([
            "thread_id": .int(Int(id)),
            "subject": .string(ArchiveTools.untrusted("thread subject", subject)),
            "message_count": .int(messages.count),
            "messages": .array(messageValues),
        ])
    }

    static func addressLine(_ summary: MessageSummary) -> String {
        if let name = summary.fromName, !name.isEmpty {
            return "\(name) <\(summary.fromEmail ?? "unknown")>"
        }
        return summary.fromEmail ?? "unknown"
    }

    static func iso(_ date: Date?) -> String {
        date?.formatted(.iso8601) ?? "unknown"
    }
}

extension Value {
    /// `.string` for a value, `.null` for nil — optional JSON fields render
    /// as explicit nulls so the resource shape stays stable for clients.
    static func optional(_ value: Value?) -> Value {
        value ?? .null
    }
}
