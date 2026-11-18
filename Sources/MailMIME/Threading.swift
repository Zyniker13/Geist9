// Threading (DESIGN 7): the JWZ algorithm over Message-ID / In-Reply-To /
// References, producing a forest of containers. Pure string level: the sync
// layer merges provider thread IDs into these threads later; MailMIME only
// sees header text. Must tolerate hostile input — cycles, self references,
// duplicate and missing Message-IDs — without hanging, losing a message, or
// building a corrupted forest.

public struct ThreadMessage: Sendable {
    /// Normalized Message-ID in `<id@host>` form; empty means "synthesize".
    public let id: String
    /// The reply chain, oldest first: References when present, else
    /// In-Reply-To. Ids in the same `<id@host>` form.
    public let references: [String]
    /// Decoded subject, used for the subject-merge pass.
    public let subject: String

    public init(id: String, references: [String], subject: String) {
        self.id = id
        self.references = references
        self.subject = subject
    }
}

/// One node of the thread forest. Holds a message, or is empty (a stub for
/// a referenced message that is not in the set). Stubs that end up with a
/// message keep their position in the tree.
public final class ThreadContainer {
    /// Table key: the message id, or the synthesized one.
    public internal(set) var id: String
    /// The message, or nil for a stub.
    public internal(set) var message: ThreadMessage?
    public internal(set) var parent: ThreadContainer?
    public internal(set) var children: [ThreadContainer] = []

    init(id: String, message: ThreadMessage?) {
        self.id = id
        self.message = message
    }

    /// True if this container has no message of its own.
    public var isEmpty: Bool { message == nil }

    /// Ancestors from the immediate parent upward.
    public func ancestors() -> [ThreadContainer] {
        var result: [ThreadContainer] = []
        var node = parent
        while let p = node {
            result.append(p)
            node = p.parent
        }
        return result
    }

    /// All descendants, depth-first pre-order.
    public func descendants() -> [ThreadContainer] {
        var result: [ThreadContainer] = []
        var stack: [ThreadContainer] = children.reversed()
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: next.children.reversed())
        }
        return result
    }
}

public enum Threading {
    /// Threads messages into a forest of roots (JWZ). Never throws and never
    /// drops a message: every input message ends up in exactly one container,
    /// even with cycles, self references, or duplicate/missing ids.
    public static func thread(_ messages: [ThreadMessage]) -> [ThreadContainer] {
        var table: [String: ThreadContainer] = [:]
        var created: [ThreadContainer] = []
        var removed = Set<ObjectIdentifier>()

        func container(_ id: String) -> ThreadContainer {
            if let existing = table[id] { return existing }
            let fresh = ThreadContainer(id: id, message: nil)
            table[id] = fresh
            created.append(fresh)
            return fresh
        }

        func syntheticID() -> String {
            var n = 0
            while true {
                let candidate = "<thread-synth-\(n)@invalid>"
                if table[candidate] == nil { return candidate }
                n += 1
            }
        }

        // Steps 1+2: create containers and link each reply chain. A message
        // arriving after something referenced it fills the stub in place.
        for message in messages {
            var key = message.id
            if key.isEmpty || table[key]?.message != nil {
                key = syntheticID()
            }
            let own: ThreadContainer
            if key == message.id, let stub = table[key], stub.message == nil {
                stub.message = message
                own = stub
            } else {
                own = ThreadContainer(id: key, message: message)
                table[key] = own
                created.append(own)
            }

            var prev: ThreadContainer?
            for ref in dedup(message.references) {
                if ref.isEmpty || ref == key { continue } // never its own or a non-ancestor
                let node = container(ref)
                if node === own { continue }
                if let p = prev, p !== node, node.parent == nil, !isDescendant(p, of: node) {
                    link(parent: p, child: node)
                }
                prev = node
            }
            if let p = prev, p !== own, own.parent == nil, !isDescendant(p, of: own) {
                link(parent: p, child: own)
            }
        }

        // Step 4: prune empty containers (stub chains left by references to
        // messages that are not in the set). Children of an empty container
        // are promoted; promotion all the way to the root set happens only
        // for a single child, so unrelated branches do not all surface.
        // Reversed creation order processes deeper containers first.
        for node in created.reversed() {
            guard node.message == nil else { continue }
            if node.children.isEmpty {
                if let parent = node.parent {
                    parent.children.removeAll { $0 === node }
                    node.parent = nil
                }
                removed.insert(ObjectIdentifier(node))
            } else if node.children.count == 1 {
                let child = node.children[0]
                child.parent = node.parent
                if let parent = node.parent,
                   let i = parent.children.firstIndex(where: { $0 === node }) {
                    parent.children[i] = child
                }
                node.parent = nil
                node.children = []
                removed.insert(ObjectIdentifier(node))
            } else if node.parent != nil {
                let parent = node.parent!
                for child in node.children { child.parent = parent }
                if let i = parent.children.firstIndex(where: { $0 === node }) {
                    parent.children.replaceSubrange(i...i, with: node.children)
                }
                node.parent = nil
                node.children = []
                removed.insert(ObjectIdentifier(node))
            }
            // An empty root with several children stays: JWZ keeps it so the
            // children do not all jump to the top level.
        }

        let roots = created.filter { $0.parent == nil && !removed.contains(ObjectIdentifier($0)) }

        // Step 5: group root subjects. Roots sharing a simplified subject
        // merge under the first root that can act as a parent — an empty one,
        // else one with no references. Two full messages that merely share a
        // subject stay separate threads. Empty subjects never merge.
        var finalRoots: [ThreadContainer] = []
        var groups: [String: [ThreadContainer]] = [:]
        var order: [String] = []
        for root in roots {
            let key = simplifiedSubject(root.message?.subject ?? "")
            if key.isEmpty {
                finalRoots.append(root)
                continue
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(root)
        }
        for key in order {
            let group = groups[key]!
            if group.count == 1 {
                finalRoots.append(group[0])
                continue
            }
            let primary = group.first { $0.message == nil }
                ?? group.first { $0.message?.references.isEmpty ?? false }
            guard let primary else {
                finalRoots.append(contentsOf: group)
                continue
            }
            for member in group where member !== primary {
                if !isDescendant(member, of: primary) {
                    link(parent: primary, child: member)
                }
            }
            finalRoots.append(primary)
        }
        return finalRoots
    }

    /// Simplified subject for grouping: repeated Re:/Fwd:/Fw: prefixes (with
    /// optional bracketed counters) and a trailing "(fwd)" stripped, case
    /// folded, whitespace collapsed.
    public static func simplifiedSubject(_ subject: String) -> String {
        var s = Substring(subject)
        while true {
            let rest = s.drop(while: { $0 == " " || $0 == "\t" })
            var matched = false
            for prefix in ["re", "fw", "fwd"] {
                guard rest.lowercased().hasPrefix(prefix) else { continue }
                var after = rest.dropFirst(prefix.count)
                if after.first == "[" || after.first == "(" {
                    let closer: Character = after.first == "[" ? "]" : ")"
                    if let close = after.firstIndex(of: closer) {
                        let inner = after[after.index(after.startIndex, offsetBy: 1)..<close]
                        if !inner.isEmpty, inner.allSatisfy(\.isNumber) {
                            after = after[after.index(close, offsetBy: 1)...]
                        }
                    }
                }
                guard after.first == ":" else { continue }
                s = after.dropFirst()
                matched = true
                break
            }
            if !matched { break }
        }
        var text = String(s)
        if text.lowercased().hasSuffix("(fwd)") {
            text = String(text.dropLast(5))
        }
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .lowercased()
    }

    static func dedup(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    /// True if `node` is an ancestor of (or equal to) `candidate`.
    static func isDescendant(_ candidate: ThreadContainer, of node: ThreadContainer) -> Bool {
        var current: ThreadContainer? = candidate
        while let c = current {
            if c === node { return true }
            current = c.parent
        }
        return false
    }

    static func link(parent: ThreadContainer, child: ThreadContainer) {
        child.parent = parent
        parent.children.append(child)
    }
}
