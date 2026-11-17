# 0008: A Local, Read-Only MCP Server

Status: Accepted, 2026-11-16

## Context

Agent access is a primary feature: people's agents should be able to search and read their archive.

## Decision

Ship an MCP server with the app: a stdio helper inside the app bundle (default) and an optional loopback-only Streamable HTTP transport with per-client tokens. Read-only tools only. The person controls which accounts and folders each client sees, and every request is logged in the app. All message content is returned labelled as untrusted.

## Consequences

No message content passes through any server of ours. Prompt injection through archived mail can at worst steer what an agent reads, within the person's limits. Write tools, if ever added, need their own decision and an in-app confirmation.
