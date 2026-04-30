<!--
Fixture: no-marker
Purpose: Body only — no marker present anywhere in the file.
Expected parser behavior:
  - body  = full file content unchanged.
  - topics = [] (empty).
-->
# Plain Document

This file represents the case where the LLM finished its response without ever
emitting a `---DEEP-DIVES---` marker (e.g. an in-progress stream that has not
yet reached the marker section, or a node whose output happens to contain no
deep-dive suggestions).

The parser should treat the entire buffer as markdown body and return an empty
topics list. The UI then renders the body in the center pane and shows
"No deep dives yet." in the right pane.
