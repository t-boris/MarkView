<!--
Fixture: as-hr
Purpose: Body contains plain "---" horizontal rules but NO real marker.
         The parser must NOT match a bare "---" — the marker form requires
         the literal "DEEP-DIVES" token surrounded by "\n\n---" prefix and
         "---\n" suffix.
Expected parser behavior:
  - body  = full file content unchanged.
  - topics = [] (empty).
-->
# Section A

Some prose about section A.

---

# Section B

Some prose about section B. Note the horizontal rule above is a normal markdown
`<hr>` — it is **not** a deep-dives marker.

---

# Section C

Final section. Again, the bare `---` rules sprinkled through this document must
never trigger marker detection because there is no `DEEP-DIVES` token.
