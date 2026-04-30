<!--
Fixture: in-code-fence
Purpose: Body contains a fenced code block whose contents include the literal
         string "---DEEP-DIVES---". A *real* terminal marker still appears at
         the end of the buffer.
Expected parser behavior:
  - The "---DEEP-DIVES---" inside the code fence MUST NOT be treated as the marker.
  - lastIndexOf semantics naturally pick the trailing real marker.
  - body  = everything before the trailing real marker (including the entire
            code-fenced section, marker text and all).
  - topics = exactly 1 entry:
      [0] label="Marker semantics", hint="how the parser disambiguates", scopeHint=["docs/parser.md"]
-->
# Marker Disambiguation

The parser must tolerate documentation that *describes* the marker. For example,
the snippet below shows the literal marker form, but it sits inside a fenced
code block and so it is not an actual end-of-stream marker.

```text
The end-of-stream marker looks like this:

---DEEP-DIVES---
- Some example :: explaining the format :: example.md
```

The real marker appears just below this paragraph and is what the parser must use.

---DEEP-DIVES---
- Marker semantics :: how the parser disambiguates :: docs/parser.md
