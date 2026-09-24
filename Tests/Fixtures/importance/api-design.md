# Partner API Design

## Authentication and key rotation

Every request is signed with the partner's secret key (HMAC-SHA256 over the body and
timestamp). Requests older than 5 minutes are rejected to prevent replay. Keys must
be rotated every 90 days; a leaked key must be revoked immediately through
`POST /v1/keys/{id}/revoke`, which takes effect within 60 seconds.

## Rate limits

Each partner may send 100 requests per second. Above that the API answers 429 with a
`Retry-After` header; partners must back off instead of retrying immediately.

## Idempotency

`POST` requests must carry an `Idempotency-Key` header. Replaying a request with the
same key returns the original response instead of creating a second payment.

## History of the API

Version 0 was a SOAP interface used by two partners in 2019. It was replaced by this
REST design in 2021.

## Examples

A minimal request in curl, with a placeholder key, for trying things out locally.

## TODO

Describe webhooks here.
