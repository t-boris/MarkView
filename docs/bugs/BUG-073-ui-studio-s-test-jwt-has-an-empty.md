---
type: bug
id: BUG-073
title: UI Studio's test JWT has an empty signature, so vivaa sends every page to login
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio's test JWT has an empty signature, so vivaa sends every page to login

## Summary

When UI Studio starts a development server it gives secret variables test values. A JWT-shaped secret gets an unsigned token `header.payload.` whose third segment is empty. vivaa's `@vivaa/auth` middleware (resolveSupabasePublicConfig → isSupportedAnonKey) requires three non-empty segments, treats NEXT_PUBLIC_SUPABASE_ANON_KEY as missing and fails closed: every page answers 307 → /auth/login.

## Steps to reproduce

1. Open vivaa-platform in MarkView 5.18.0 and stop any own `next dev` on :3000
2. Open UI Studio on apps/client-web-app so MarkView starts the server with simulated connections
3. Look at the page, or run `curl -sI localhost:3000/`

## Expected

Public pages (/, /gallery) open; only protected routes ask to sign in. A test value keeps the shape a library checks (a JWT with three non-empty segments).

## Actual

Every page, including /, redirects to /auth/login without a `redirect=` parameter (the fail-closed branch). The server's NEXT_PUBLIC_SUPABASE_ANON_KEY test value has segment lengths [35, 79, 0].

## Environment

MarkView 5.18.0, macOS 27, vivaa apps/client-web-app (Next.js 16.2.1, @supabase/ssr). Cause: StudioConnections.testValue (MarkView/Models/UIStudioConnections.swift) builds `alg: none` tokens with an empty signature.
