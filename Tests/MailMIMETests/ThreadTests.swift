// Threading tests (DESIGN 7, M1.9): JWZ reply chains, stub pruning,
// subject merging, and hostile input — cycles, self references, duplicate
// and missing Message-IDs — never hang, never lose a message, and always
// produce a well-formed forest.

import XCTest
@testable import MailMIME

final class ThreadTests: XCTestCase {
    private func msg(_ id: String, _ refs: [String] = [], _ subject: String = "") -> ThreadMessage {
        ThreadMessage(id: id, references: refs, subject: subject)
    }

    private func find(_ roots: [ThreadContainer], _ id: String) -> ThreadContainer? {
        for root in roots {
            if root.id == id { return root }
            if let hit = find(root.children, id) { return hit }
        }
        return nil
    }

    private func allContainers(_ roots: [ThreadContainer]) -> [ThreadContainer] {
        var result: [ThreadContainer] = []
        var seen = Set<ObjectIdentifier>()
        var stack = roots
        while let next = stack.popLast() {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            stack.append(contentsOf: next.children)
        }
        return result
    }

    func testEmptyInput() {
        XCTAssertEqual(Threading.thread([]).count, 0)
    }

    func testLoneMessagesAreRoots() {
        let roots = Threading.thread([msg("<a@x>"), msg("<b@x>")])
        XCTAssertEqual(roots.count, 2)
        XCTAssertNil(roots[0].parent)
    }

    func testSimpleReplyChain() {
        let roots = Threading.thread([
            msg("<a@x>", [], "Hello"),
            msg("<b@x>", ["<a@x>"], "Re: Hello"),
            msg("<c@x>", ["<a@x>", "<b@x>"], "Re: Re: Hello"),
        ])
        XCTAssertEqual(roots.count, 1)
        let a = roots[0]
        XCTAssertEqual(a.message?.id, "<a@x>")
        XCTAssertEqual(a.children.map(\.message?.id), ["<b@x>"])
        XCTAssertEqual(a.children[0].children.map(\.message?.id), ["<c@x>"])
    }

    func testReplyArrivingBeforeParentAttachesToStub() {
        // Out-of-order import: the reply is processed first, the original
        // arrives later and must take over the stub's place in the tree.
        let roots = Threading.thread([
            msg("<b@x>", ["<a@x>"], "Re: Hello"),
            msg("<a@x>", [], "Hello"),
        ])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].message?.id, "<a@x>")
        XCTAssertEqual(roots[0].children.map(\.message?.id), ["<b@x>"])
    }

    func testMissingMiddleAncestorIsPruned() {
        // References name <x@x>, which is not in the set; the stub between
        // the root and the reply collapses.
        let roots = Threading.thread([
            msg("<a@x>", [], "Hello"),
            msg("<c@x>", ["<x@x>", "<a@x>"], "Re: Hello"),
        ])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].message?.id, "<a@x>")
        XCTAssertEqual(roots[0].children.map(\.message?.id), ["<c@x>"])
    }

    func testUnknownReferenceOnlyLeavesOrphanAtRoot() {
        let roots = Threading.thread([msg("<d@x>", ["<y@y>"], "Forward")])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].message?.id, "<d@x>")
        XCTAssertTrue(roots[0].children.isEmpty)
    }

    func testStubGroupKeepsEmptyRootInsteadOfPromotingBranches() {
        // Two replies reference the same missing parent: the stub stays as
        // an empty root holding both, instead of promoting both to the top.
        let roots = Threading.thread([
            msg("<b@x>", ["<x@x>"], "Re: Hi"),
            msg("<c@x>", ["<x@x>"], "Re: Hi"),
        ])
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots[0].isEmpty)
        XCTAssertEqual(roots[0].children.count, 2)
    }

    func testSelfReferenceIgnored() {
        let roots = Threading.thread([msg("<a@x>", ["<a@x>"], "Loop")])
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots[0].children.isEmpty)
    }

    func testTwoNodeReferenceCycle() {
        let roots = Threading.thread([
            msg("<a@x>", ["<b@x>"], "A"),
            msg("<b@x>", ["<a@x>"], "B"),
        ])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].message?.id, "<b@x>")
        XCTAssertEqual(roots[0].children.map(\.message?.id), ["<a@x>"])
    }

    func testThreeNodeReferenceCycle() {
        let roots = Threading.thread([
            msg("<a@x>", ["<c@x>"], "A"),
            msg("<b@x>", ["<a@x>"], "B"),
            msg("<c@x>", ["<b@x>"], "C"),
        ])
        // One tree, no hang, no lost message: the stub created first wins the
        // root, and the link that would close the cycle is refused.
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].message?.id, "<c@x>")
        XCTAssertEqual(roots[0].children.map(\.message?.id), ["<a@x>"])
        XCTAssertEqual(roots[0].children[0].children.map(\.message?.id), ["<b@x>"])
    }

    func testMissingMessageIDGetsSynthesizedAndStaysDistinct() {
        let roots = Threading.thread([msg("", [], "One"), msg("", [], "Two")])
        XCTAssertEqual(roots.count, 2)
        XCTAssertNotEqual(roots[0].id, roots[1].id)
        XCTAssertNotNil(roots[0].message)
        XCTAssertNotNil(roots[1].message)
    }

    func testDuplicateMessageIDKeepsBothMessages() {
        let roots = Threading.thread([msg("<a@x>", [], "First"), msg("<a@x>", [], "Second")])
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots.filter { $0.message?.subject == "First" }.count, 1)
        XCTAssertEqual(roots.filter { $0.message?.subject == "Second" }.count, 1)
    }

    func testSameSubjectFullThreadsStaySeparate() {
        // Both roots carry messages with references of their own: shared
        // subject alone does not merge them.
        let roots = Threading.thread([
            msg("<a@x>", ["<x@x>"], "Hello"),
            msg("<b@x>", ["<y@y>"], "Re: Hello"),
        ])
        XCTAssertEqual(roots.count, 2)
    }

    func testSameSubjectMergesUnderReflessRoot() {
        let roots = Threading.thread([
            msg("<a@x>", [], "Hello"),
            msg("<b@x>", [], "Re: Hello"),
        ])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].message?.id, "<a@x>")
        XCTAssertEqual(roots[0].children.map(\.message?.id), ["<b@x>"])
    }

    func testSameSubjectMergesUnderEmptyRoot() {
        let roots = Threading.thread([
            msg("<b@x>", ["<x@x>"], "Hello"),
            msg("<c@x>", [], "Hello"),
        ])
        // <b@x> sits under a stub that prunes away, leaving a full root with
        // references; <c@x> has none, so it becomes the primary parent.
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].message?.id, "<c@x>")
        XCTAssertEqual(roots[0].children.map(\.message?.id), ["<b@x>"])
    }

    func testEmptySubjectsNeverMerge() {
        let roots = Threading.thread([msg("<a@x>"), msg("<b@x>")])
        XCTAssertEqual(roots.count, 2)
    }

    func testSimplifiedSubjectVariants() {
        XCTAssertEqual(Threading.simplifiedSubject("Re: Re[2]: Fwd: Hello (fwd)"), "hello")
        XCTAssertEqual(Threading.simplifiedSubject("FW:  Hi  There "), "hi there")
        XCTAssertEqual(Threading.simplifiedSubject("RE(3):Update"), "update")
        XCTAssertEqual(Threading.simplifiedSubject("Re"), "re")
        XCTAssertEqual(Threading.simplifiedSubject("Reply: yes"), "reply: yes")
        XCTAssertEqual(Threading.simplifiedSubject(""), "")
    }

    func testFuzzInvariants() {
        // Deterministic pseudo-random corpus with hostile reference graphs:
        // unknown ids, self references, duplicate ids, cycles, empty ids.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }

        var messages: [ThreadMessage] = []
        var pool: [String] = []
        for i in 0..<400 {
            let known = next(4) == 0
            var id = known ? "<id-\(i)@host\(next(3))>" : ""
            var refs: [String] = []
            let refCount = next(4)
            for _ in 0..<refCount {
                let roll = next(6)
                if roll <= 1, !pool.isEmpty {
                    refs.append(pool[next(pool.count)]) // existing id
                } else if roll == 2 {
                    refs.append("<ghost-\(next(5))@nowhere>") // unknown id
                } else if roll == 3 {
                    refs.append(id.isEmpty ? "<ghost-\(next(5))@nowhere>" : id) // self ref
                } else {
                    refs.append("<junk-\(next(9))@x>") // usually unknown
                }
            }
            if !pool.isEmpty, next(12) == 0, !id.isEmpty {
                id = pool[next(pool.count)] // duplicate Message-ID
            }
            let subject = next(3) == 0 ? "Re: topic \(next(8))" : "topic \(next(8))"
            messages.append(msg(id, refs, subject))
            if !id.isEmpty { pool.append(id) }
        }

        let roots = Threading.thread(messages)

        // Every message lands in exactly one container; every link is
        // symmetric; nothing is its own ancestor; the walk terminates.
        var seenMessages = 0
        var seenIDs = Set<ObjectIdentifier>()
        for container in allContainers(roots) {
            XCTAssertTrue(seenIDs.insert(ObjectIdentifier(container)).inserted, "visited twice")
            if container.message != nil { seenMessages += 1 }
            if let parent = container.parent {
                XCTAssertTrue(parent.children.contains { $0 === container }, "asymmetric link")
            }
            var node: ThreadContainer? = container
            var walked = 0
            while let current = node {
                node = current.parent
                walked += 1
                XCTAssertLessThan(walked, messages.count + 10, "parent cycle")
            }
        }
        XCTAssertEqual(seenMessages, messages.count, "a message was lost")
    }
}
