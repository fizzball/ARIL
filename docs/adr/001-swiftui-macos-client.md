# ADR-001: Native SwiftUI macOS client

## Status
Accepted

## Context
ARIL needs a premium desktop chat UX comparable to Hermes: sidebar sessions, strong wordmark hero, composite input bar, status footer, and rich pre-send intelligence UI with animations.

## Decision
Build the client as a **native SwiftUI macOS 14+** app generated via XcodeGen. The client is a thin presentation + local history layer; all routing intelligence lives on the server.

## Consequences
- Best fit for macOS look, accessibility, and performance
- No Windows/Linux client initially (acceptable)
- Requires Xcode for builds; SPM deps kept minimal
