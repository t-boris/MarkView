---
type: bug
id: BUG-070
title: UI Studio sends Next.js refresh and navigation data requests to the simulator
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
ready_to_fix: true
updated: 2026-11-04
---

# UI Studio sends Next.js refresh and navigation data requests to the simulator

## Summary

Next.js fetches server-component payloads from its own server (router.refresh(), Link navigation: GET /?_rsc=… with the rsc header). UI Studio does not recognise them as the dev server's own requests and hands them to the simulator as an unknown contract, so "Try again" cannot work and the session shows Preparing.

## Steps to reproduce

1. Open UI Studio on vivaa-platform apps/client-web-app.
2. On the home page press "Try again" under "Couldn't load the cities" (router.refresh()), or follow a client-side link.

## Expected

The request goes to the development server, which renders the payload.

## Actual

The request becomes the unknown contract GET / and is sent to rule preparation; the page waits or gets a simulated answer instead of the payload.

## Environment

MarkView 5.15.2; Next.js 16.2.1. StudioConnectionPolicy.isDevelopmentResource passes /_next/ and static files only. The same applies to Remix (_data), SvelteKit (__data.json), Nuxt (_payload.json) and Astro (_server-islands) data requests.
