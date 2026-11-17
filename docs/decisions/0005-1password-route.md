# 0005: How the App Talks to 1Password

Status: Proposed: decided by the M0 spike

## Context

Credentials can live in a dedicated 1Password vault (DESIGN 4). There are three possible routes: the official 1Password SDK with desktop app integration through a helper, the `op` CLI with desktop app integration, and service account tokens.

## Decision

To be decided in M0 from the spike. Default if the spike can't decide: `op` with desktop app integration for interactive use, and service account tokens for unattended Macs.

## Consequences

Whatever the route, the app process never holds a 1Password session longer than one sync, and nothing from 1Password reaches disk.
