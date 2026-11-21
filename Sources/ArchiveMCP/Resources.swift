// MCP resources over one archive (DESIGN 9A). Every message is
// `emailarchiver://message/<id>` and every thread is
// `emailarchiver://thread/<id>`, so clients that browse resources can
// attach them. Like the tools, the resource layer is read-only and goes
// through the same AccessContext as the tools: hidden messages and
// threads never appear in listings, a read of a hidden id answers
// "not found", and names, descriptions and content are redacted by the
// policy. Listing pages with a cursor so a large archive never returns
// one unbounded response.

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
    /// or when both tables are exhausted (`nextCursor` nil). With a
    /// visibility filter, hidden rows are skipped by the query itself, so
    /// pages stay full and the cursor (a last id, not a row number) stays
    /// stable.
    static func list(
        cursor: String?, ctx: ToolContext
    ) throws -> ListResources.Result {
        // Resource reads pass the same gate as tool calls (0053): the
        // disabled check, the rate limit, and the activity log.
        try ctx.access.beginRequest(tool: "list_resources", query: cursor)
        let raw = cursor ?? "m:0"
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let after = Int64(parts[1]),
            parts[0] == "m" || parts[0] == "t"
        else {
            ctx.access.endRequest(tool: "list_resources", query: cursor, resultCount: nil)
            throw ArchiveTools.ToolError.badArguments("bad cursor: \(raw)")
        }

        switch parts[0] {
        case "m":
            let messages = try ctx.store.listMessages(
                after: after, limit: pageSize, visible: ctx.access.visibility)
            var resources = messages.map { messageResource($0, redaction: ctx.access.redaction) }
            if messages.count == pageSize {
                ctx.access.endRequest(
                    tool: "list_resources", query: cursor, resultCount: resources.count)
                return ListResources.Result(
                    resources: resources,
                    nextCursor: "m:\(messages.last!.id)"
                )
            }
            // Messages exhausted: continue into threads on the same page.
            let remaining = pageSize - messages.count
            let threads = try ctx.store.listThreads(
                after: 0, limit: remaining, visible: ctx.access.visibility)
            resources += threads.map { threadResource($0, redaction: ctx.access.redaction) }
            if threads.count == remaining {
                ctx.access.endRequest(
                    tool: "list_resources", query: cursor, resultCount: resources.count)
                return ListResources.Result(
                    resources: resources,
                    nextCursor: "t:\(threads.last!.id)"
                )
            }
            ctx.access.endRequest(
                tool: "list_resources", query: cursor, resultCount: resources.count)
            return ListResources.Result(resources: resources, nextCursor: nil)
        default:
            let threads = try ctx.store.listThreads(
                after: after, limit: pageSize, visible: ctx.access.visibility)
            let resources = threads.map { threadResource($0, redaction: ctx.access.redaction) }
            if threads.count == pageSize {
                ctx.access.endRequest(
                    tool: "list_resources", query: cursor, resultCount: resources.count)
                return ListResources.Result(
                    resources: resources,
                    nextCursor: "t:\(threads.last!.id)"
                )
            }
            ctx.access.endRequest(
                tool: "list_resources", query: cursor, resultCount: resources.count)
            return ListResources.Result(resources: resources, nextCursor: nil)
        }
    }

    static func messageResource(
        _ summary: MessageSummary, redaction: AccessPolicy.Redaction
    ) -> Resource {
        // Name and description are rendered by clients: subject and the
        // from address are content, so the redaction policy applies here
        // too, not only inside the message JSON.
        let name = summary.subject.map {
            Redactor.apply(redaction, to: $0)
        } ?? "Message \(summary.id)"
        let from = Redactor.apply(
            redaction, to: summary.fromEmail ?? "unknown")
        return Resource(
            name: name,
            uri: "\(scheme)message/\(summary.id)",
            description: """
            From \(from), \
            \(iso(summary.dateReceived ?? summary.dateSent)) \
            (\(summary.size) bytes)
            """,
            mimeType: "application/json"
        )
    }

    static func threadResource(
        _ ref: ThreadRef, redaction: AccessPolicy.Redaction
    ) -> Resource {
        Resource(
            name: ref.subject.map { Redactor.apply(redaction, to: $0) }
                ?? "Thread \(ref.id)",
            uri: "\(scheme)thread/\(ref.id)",
            description: "An archived conversation.",
            mimeType: "application/json"
        )
    }

    // MARK: Reading

    /// One resource's content. Unknown schemes and ids fail the request;
    /// nothing is ever invented to fill a gap. A hidden id fails the same
    /// way as an unknown one.
    static func read(
        _ uri: String, ctx: ToolContext
    ) throws -> ReadResource.Result {
        // Resource reads pass the same gate as tool calls (0053): the
        // disabled check, the rate limit, and the activity log.
        try ctx.access.beginRequest(tool: "read_resource", query: uri)
        guard uri.hasPrefix(scheme) else {
            ctx.access.endRequest(tool: "read_resource", query: uri, resultCount: nil)
            throw ArchiveTools.ToolError.badArguments(
                "unknown resource scheme: \(uri)"
            )
        }
        let rest = uri.dropFirst(scheme.count)
        let segments = rest.split(separator: "/")
        guard segments.count == 2, let id = Int64(segments[1]) else {
            ctx.access.endRequest(tool: "read_resource", query: uri, resultCount: nil)
            throw ArchiveTools.ToolError.badArguments(
                "bad resource URI: \(uri)"
            )
        }

        let value: Value
        switch segments[0] {
        case "message":
            guard try ctx.access.isVisible(messageID: id, store: ctx.store) else {
                ctx.access.endRequest(tool: "read_resource", query: uri, resultCount: nil)
                throw ArchiveTools.ToolError.notFound("message id \(id)")
            }
            value = try messageJSON(id: id, ctx: ctx)
        case "thread":
            guard try ctx.access.threadIsVisible(threadID: id, store: ctx.store) else {
                ctx.access.endRequest(tool: "read_resource", query: uri, resultCount: nil)
                throw ArchiveTools.ToolError.notFound("thread id \(id)")
            }
            value = try threadJSON(id: id, ctx: ctx)
        default:
            ctx.access.endRequest(tool: "read_resource", query: uri, resultCount: nil)
            throw ArchiveTools.ToolError.badArguments(
                "unknown resource kind: \(segments[0])"
            )
        }
        let text = ArchiveTools.render(value)
        ctx.access.endRequest(tool: "read_resource", query: uri, resultCount: 1)
        return ReadResource.Result(
            contents: [
                .text(text, uri: uri, mimeType: "application/json")
            ]
        )
    }

    /// One message as JSON. The shape mirrors the get_message tool (same
    /// untrusted wrapping, same body cap, same redaction and headers-only
    /// handling) with the raw store data left out: resource readers want
    /// the readable message, not its bytes.
    static func messageJSON(id: Int64, ctx: ToolContext) throws -> Value {
        let store = ctx.store
        let access = ctx.access
        guard let summary = try store.message(id: id) else {
            throw ArchiveTools.ToolError.notFound("message id \(id)")
        }
        let data = try store.messageData(summary.hash)
        let headers = MailBridge.headerFields(for: data)
        // Header values are where addresses live; the redaction mode
        // applies to them in every non-`none` mode.
        let headerObject = Value.object(
            Dictionary(
                uniqueKeysWithValues: headers.map {
                    ($0.name, .string(Redactor.apply(access.redaction, to: $0.value)))
                }
            )
        )

        var body = MailBridge.messageBody(for: data) ?? ""
        let cap = min(maxBodyChars, access.maxCharsPerCall)
        let truncated = body.count > cap
        if truncated { body = String(body.prefix(cap)) }
        // `headersOnly` omits the body field entirely — the absence is the
        // policy speaking, and `null` would be indistinguishable from "no
        // body was stored".
        var object: [String: Value] = [
            "id": .int(Int(summary.id)),
            "thread_id": .optional(summary.threadID.map { .int(Int($0)) }),
            "date": .string(iso(summary.dateReceived ?? summary.dateSent)),
            "from": .string(
                ArchiveTools.red("from", addressLine(summary), redaction: access.redaction)),
            "headers": headerObject,
            "subject": summary.subject.map {
                .string(ArchiveTools.red("subject", $0, redaction: access.redaction))
            } ?? .null,
        ]
        if access.redaction == .headersOnly {
            object["body_omitted"] = .bool(true)
        } else {
            let bodyValue: Value = body.isEmpty
                ? .null
                : .string(ArchiveTools.red("message body", body, redaction: access.redaction))
            object["body"] = bodyValue
            object["body_truncated"] = .bool(truncated)
        }
        return .object(object)
    }

    /// One thread as JSON: the visible messages in conversation order.
    /// The subject comes from the first visible message, not the thread
    /// row: the stored root subject may be a hidden message's subject,
    /// and that would leak exactly once, quietly.
    static func threadJSON(id: Int64, ctx: ToolContext) throws -> Value {
        let store = ctx.store
        let messages = try store.threadMessages(
            threadID: id, visible: ctx.access.visibility)
        guard let first = messages.first else {
            throw ArchiveTools.ToolError.notFound("thread id \(id)")
        }
        let subject = first.subject ?? "Thread \(id)"
        let messageValues = messages.map { summary -> Value in
            .object([
                "id": .int(Int(summary.id)),
                "date": .string(iso(summary.dateReceived ?? summary.dateSent)),
                "from": .string(
                    ArchiveTools.red(
                        "from", addressLine(summary), redaction: ctx.access.redaction)),
                "subject": summary.subject.map {
                    .string(ArchiveTools.red("subject", $0, redaction: ctx.access.redaction))
                } ?? .null,
            ])
        }
        return .object([
            "thread_id": .int(Int(id)),
            "subject": .string(
                ArchiveTools.red(
                    "thread subject", subject, redaction: ctx.access.redaction)),
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
