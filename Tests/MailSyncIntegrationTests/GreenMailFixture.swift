// The GreenMail-only fixture enum, kept as a thin delegate so any older
// references still compile: everything real lives in MailServer.swift, the
// server-parameterized fixture the whole integration target shares.

import Foundation
@testable import MailSync

enum GreenMail {
    static var host: String {
        MailServer.configured().first(where: { $0.kind == .greenmail })?.host ?? "127.0.0.1"
    }

    static var port: Int {
        MailServer.configured().first(where: { $0.kind == .greenmail })?.port ?? 13143
    }

    static var user: String { MailServer.user }
    static var password: String { MailServer.password }

    static func requireServer() async throws {
        let server = try configured()
        try await server.requireServer()
    }

    private static func configured() throws -> MailServer {
        guard let server = MailServer.configured().first(where: { $0.kind == .greenmail }) else {
            throw ServerMissing(message: "GreenMail excluded via GEIST9_SKIP_SERVERS")
        }
        return server
    }

    static func freshFixtureFolder() throws -> String {
        try configured().freshFixtureFolder()
    }
    static func resetFixture(folder: String) async throws {
        try await configured().resetFixture(folder: folder)
    }
    static func seed(_ messages: [Data], to folder: String) async throws {
        try await configured().seed(messages, to: folder)
    }
    static func createFolder(_ folder: String) async throws {
        try await configured().createFolder(folder)
    }
}
