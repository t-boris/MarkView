<!--
Fixture: multiple-markers
Purpose: Two real markers appear in the buffer (e.g. the LLM accidentally emitted
         a topic list, then continued generating prose, then emitted a second
         topic list at the end).
Expected parser behavior:
  - The parser MUST take the LAST occurrence of the marker.
  - body  = everything before the SECOND (final) marker — including the first
            marker line and its now-stale topic list.
  - topics = exactly 2 entries (from the last marker section):
      [0] label="Final topic A", hint="latest hint A", scopeHint=["a.md"]
      [1] label="Final topic B", hint="latest hint B", scopeHint=["b.md"]
-->
# First Pass Summary

Some early summary content.

---DEEP-DIVES---
- Stale topic 1 :: outdated hint 1 :: old1.md
- Stale topic 2 :: outdated hint 2 :: old2.md

# Revised Summary

The model decided to revise its output and emit a fresh marker section below.
The previous topic list above is now stale and the parser must ignore it in
favor of the trailing marker.

---DEEP-DIVES---
- Final topic A :: latest hint A :: a.md
- Final topic B :: latest hint B :: b.md
