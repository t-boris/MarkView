import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}
func summary(_ items: [StructureOutline.Item]) -> [String] { items.map { "\($0.depth):\($0.title)@\($0.line)" } }

let json = """
{
  "name": "app",
  "scripts": {
    "build": "tsc",
    "test": "jest"
  },
  "deps": [
    { "id": 1, "tags": ["a", "b"] },
    { "id": 2 }
  ],
  "text": "a \\"quoted: value\\" and {braces}",
  "last": null
}
"""
check(summary(StructureOutline.json(json)) == ["0:name@2", "0:scripts@3", "1:build@4", "1:test@5", "0:deps@7", "1:[0]@8", "2:id@8", "2:tags@8", "1:[1]@9", "2:id@9", "0:text@11", "0:last@12"],
      "json keys, nested, with lines: \(summary(StructureOutline.json(json)))")
check(StructureOutline.json("[{\"a\":1},{\"b\":2}]").map(\.title) == ["[0]", "a", "[1]", "b"], "a root array lists its objects")
check(StructureOutline.json("{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":{\"f\":1}}}}}}", maxDepth: 3).map(\.title) == ["a", "b", "c"], "depth is capped")
check(StructureOutline.json("{\"a\": // note\n 1}").map(\.title) == ["a"], "a jsonc comment is skipped")
check(StructureOutline.json("").isEmpty && StructureOutline.json("not json").isEmpty, "empty and malformed input is harmless")

let yaml = """
# config
name: demo
services:
  web:
    image: nginx
    ports:
      - "80:80"
      - name: second
        port: 8080
  db:
    script: |
      not: a key
      still: text
    image: postgres
---
other:
  - a
"quoted key": 1
url: http://example.com
"""
check(summary(StructureOutline.yaml(yaml)) == ["0:name@2", "0:services@3", "1:web@4", "2:image@5", "2:ports@6", "3:name@8", "3:port@9", "1:db@10", "2:script@11", "2:image@14",
                                                "0:other@16", "0:quoted key@18", "0:url@19"],
      "yaml keys by indentation, block scalars skipped, list item keys: \(summary(StructureOutline.yaml(yaml)))")
check(StructureOutline.yaml("- a\n- b\n").isEmpty && StructureOutline.yaml("").isEmpty, "a plain list has no keys")
check(StructureOutline.yaml("key: value # note\nother: 'x: y'\n").map(\.title) == ["key", "other"], "values with colons and comments")
func paths(_ items: [StructureOutline.Item]) -> [String] { items.map(\.pathJSON) }
check(paths(StructureOutline.json(json)).prefix(8) == ["[\"name\"]", "[\"scripts\"]", "[\"scripts\",\"build\"]", "[\"scripts\",\"test\"]", "[\"deps\"]", "[\"deps\",0]", "[\"deps\",0,\"id\"]", "[\"deps\",0,\"tags\"]"],
      "json key paths address the tree viewer's nodes: \(paths(StructureOutline.json(json)))")
check(paths(StructureOutline.json(json))[8] == "[\"deps\",1]" && paths(StructureOutline.json(json))[9] == "[\"deps\",1,\"id\"]", "json: the second array element")
let yamlPaths = paths(StructureOutline.yaml(yaml))
check(yamlPaths[1] == "[\"services\"]" && yamlPaths[3] == "[\"services\",\"web\",\"image\"]", "yaml key paths: \(yamlPaths)")
check(yamlPaths[5] == "[\"services\",\"web\",\"ports\",1,\"name\"]", "yaml: a key in a list item carries the index: \(yamlPaths[5])")
check(StructureOutline.supports(URL(fileURLWithPath: "/a/b.YML")) && StructureOutline.supports(URL(fileURLWithPath: "/a/b.json")) && !StructureOutline.supports(URL(fileURLWithPath: "/a/b.md")), "supported files")

print(failures == 0 ? "All structure outline checks passed." : "\(failures) structure outline check(s) failed.")
exit(failures == 0 ? 0 : 1)
