# ADR-004: Category-mapped routing profiles

## Status
Accepted

## Context
Model selection should align to broad classifications: Coding, Security, Cost, Performance, Confidence — configurable in Settings.

## Decision
- Each prompt is classified into primary (+ optional secondary) categories with confidence.
- A **RoutingProfile** maps category → preferred model id(s) + tie-break weights (accuracy, cost, tokens, latency).
- Route scorer ranks eligible models; UI presents ranking on preview.
- Profiles are per-user (later: per-org) and versioned on each `RouteDecision` snapshot.

## Consequences
- Clear settings mental model
- Heuristic classifier v1 is enough to exercise the path; ML improves later without UI churn
