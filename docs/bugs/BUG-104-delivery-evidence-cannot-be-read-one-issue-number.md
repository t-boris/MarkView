---
type: bug
id: BUG-104
title: "Delivery evidence cannot be read: one issue number among the pull request numbers fails the whole GitHub query (\"pull request descriptions could not be read\")"
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-07
provenance: Created by an AI agent through MarkView
related: BUG-085
---

# Delivery evidence cannot be read: one issue number among the pull request numbers fails the whole GitHub query ("pull request descriptions could not be read")

## Summary

The agent reports "pull request descriptions could not be read" for every item. Because of it no delivery can be confirmed and the request on BUG-085 was rejected today (markview_issue_context of BUG-103 says the same: delivery evidence is unknown, GitHub pull requests could not be read). The cause is MarkView's own GitHub connection, not the repository or the network.

## Steps to reproduce

1. In the MarkView repository (t-boris/MarkView) run, for the pull request numbers of `git log origin/main --first-parent` titles, the collector's query in batches of 40: `gh api graphql -f query='query { repository(owner: "t-boris", name: "MarkView") { p293: pullRequest(number: 293) { body } ... } }'`.
2. The batch that contains 293 exits with status 1 (`gh: Could not resolve to a PullRequest with the number of 293.`), the answer has `errors: [NOT_FOUND]` next to the data of the other 39 pull requests.
3. Ask for the delivery evidence of any item (markview_issue_context BUG-103, or request fixed on a bug): "GitHub pull requests could not be read: pull request descriptions could not be read".

## Expected

A number that names an issue (or a deleted pull request) is skipped; the descriptions of the real pull requests of the batch are used. Only a failure that makes the data unreliable (authentication, rate limit, network, a malformed answer, an error other than NOT_FOUND on a requested alias) is reported as "could not be read".

## Actual

IssueEvidenceCollector.pullRequestMatches asks GitHub for the body of every number found in the titles of first-parent commits ("Merge pull request #N", "title (#N)"), 40 per GraphQL query (`pN: pullRequest(number: N) { body }`). Three commits on main are titled "... (#293)" where #293 is an issue (the mind-map feature), not a pull request. GitHub answers that alias with a NOT_FOUND error, `gh api graphql` exits with status 1 even though every other alias in the batch has data, and the collector requires status 0 and no `errors` at all, so it throws away the whole batch and reports "pull request descriptions could not be read". The code's own comment says "A squash title can end in an issue number rather than a pull request number", but the guard that rejects the response runs before the line that tolerates it.

## Environment

MarkView 5.39.0 (also earlier), repository t-boris/MarkView, gh CLI authenticated; reproduced 2026-11-07 against the live repository
