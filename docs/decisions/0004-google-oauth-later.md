# 0004: No Google Restricted-Scope Verification at Launch

Status: Accepted, 2026-11-16

## Context

Full IMAP access to Gmail (`https://mail.google.com/`) is a restricted scope: a public app needs Google's verification and a yearly third-party security assessment (CASA Tier 2).

## Decision

Do not pursue verification at launch. Gmail and Google Workspace launch with app passwords. Google OAuth is built and tested, and enabled only with a testing-mode client for named testers. Review this decision in May 2027.

## Consequences

Gmail users must turn on 2-Step Verification and create an app password; onboarding explains it. Accounts under Advanced Protection, and Workspace domains that block app passwords, can't sync until this changes; they can still import a Google Takeout export.
