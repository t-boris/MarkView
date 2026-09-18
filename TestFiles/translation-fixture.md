---
title: Translation fixture
tags: [demo, тест]
---

# Heading One

A paragraph with **bold**, a [link](https://example.com/path?a=1), `inline code`
and a second line that wraps.

## Table section

| Column A | Column B | Notes |
|----------|:--------:|------:|
| first    | value 1  | ok    |
| second   | value 2  | ok    |
| third    | value 3  | ok    |

Table without leading pipes:

Name | Role
--- | ---
Ann | dev
Bo | ops

## Code section

```swift
// A fenced block containing a table-looking line and a heading
let s = "| not | a | table |"
// # not a heading
print("```")
```

Text right after the fence with no blank line.

## Lists

1. First item
2. Second item
   - nested bullet
   - another nested

     A continuation paragraph inside the list.
3. Third item

- [ ] task one
- [x] task two

> A block quote
> spanning two lines.

Final paragraph.
