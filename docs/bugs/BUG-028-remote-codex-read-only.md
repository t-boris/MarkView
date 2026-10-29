---
type: bug
id: BUG-028
title: Remote Codex mistakes its home sandbox for work-project permissions
status: fixed
branch: fix/bug-028-remote-file-routing
severity: high
reporter: Boris Tsekinovsky
created: 2026-10-28
---

# Remote Codex mistakes its home sandbox for work-project permissions

## Summary

Through a saved relay connection, Codex could read a work-computer file but refused a subsequent
request to edit it, saying the workspace was restricted to read-only access. It returned proposed
text without calling a work-computer write tool. The requested file was inside the selected project.

## Root cause

The CLI runs in a private transport directory on HOME under a read-only native sandbox. The WORK
project is accessed through MCP tools that execute with the work user's permissions. The old prompt
called WORK the actual execution environment without clearly distinguishing these two permission
domains. Codex applied its native sandbox policy to the MCP file edit.

Fresh developer instructions corrected new conversations, but CLI resume kept the earlier developer
messages and refusals. Changing command-line configuration alone did not repair an existing thread.
An isolated workspace-write experiment also failed to repair that history; native read-only access
is retained in the shipped fix.

## Resolution

- Identify both computers explicitly. Treat user-supplied absolute paths as WORK paths, and require a
  work-tool permission failure before describing a requested WORK edit as unwritable.
- Report the work root's actual writability and file-edit capabilities in workspace_info. Scope and
  operating-system errors continue to come from the work endpoint.
- Before resuming Codex, use its stdio app-server to find the saved thread in this connection's exact
  transport directory and append updated developer context with thread/inject_items. Resume that
  explicit thread ID. No model turn runs and no Codex session file is edited directly.
- Hash the instructions and thread ID to avoid appending identical context on every reconnect.
  Missing history starts a fresh session; unsupported/failed refresh stops startup with an actionable
  error. Native tools remain disabled/guarded and the native sandbox remains read-only.

The app-server integration uses Codex's experimental thread/inject_items API, verified with CLI
0.165.0. Older incompatible CLIs must be updated on the home computer.

## Verification

The natural-request live check uses a real signed-in Codex and the production HTTPS relay: read an
absolute WORK path, continue the same conversation, and save a text replacement without explicitly
asking the model to use MCP. It asserts the WORK file changed and HOME remained untouched. The
original refusal was reproduced in a disposable session before applying the context refresh.

Standalone checks exercise fragmented app-server responses, no saved thread, exact thread selection,
developer-message injection, reconnect deduplication, changed/large Unicode context, protocol errors
and private stamp permissions. Existing file/path/symlink isolation, native-tool guard, browser,
relay, Keychain and concurrent reconnection checks remain in the verification suite.

Run the normal suite with `bash tools/tests/remote-workspace-tests.sh`. The optional signed-in test
is `bash tools/tests/remote-workspace-live.sh <relay> <private-key-file> <MarkView.app> codex --natural-edit`.
`MARKVIEW_LIVE_MODEL` selects a test model. `MARKVIEW_LIVE_RESUME_FIXTURE` can recover a preserved,
validated temporary fixture without replacing its saved conversation.
