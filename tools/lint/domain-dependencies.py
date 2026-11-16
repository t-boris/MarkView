#!/usr/bin/env python3
"""Domain dependencies of the app (AR-21): which domain folder names a type that another domain folder declares.

A domain is a folder directly under MarkView/Models or MarkView/Views. Domain A depends on domain B of the same layer
when a Swift file in A names a type that a file in B declares at the top level. Models and Views are two separate graphs
(a view of domain X using a model of domain Y is not a dependency cycle between the two layers' domains).

The weight of the edge A -> B is the number of distinct types of B that files of A name. The domains are layered, lowest first
(RANKS): Appearance, then Shared (infrastructure that names no feature domain), then AI (the assistants the features call), then the
feature domains, then Workspace (which composes the features and is named by none of them). A domain may name its own rank and
the ranks below it; an edge that points up is a back-edge, whether or not anything points back. A pair of feature domains that name
each other (an edge of weight above zero in both directions, a cycle) has one back-edge too: the direction with the smaller weight,
or the direction an allow-list entry names. The lint rule `domain-cycles` (architecture-lint.sh) ratchets the back-edges so they
only fall.

Names are matched in code only (comments and string literals are skipped, but `\\(...)` interpolations are read), and a member
access (`x.Name`) is not a reference. A name that cannot be told from another declaration is ignored and reported as ambiguous:
a type that is also declared nested somewhere in the referencing domain, or a nested name of the same file.

Usage: tools/lint/domain-dependencies.py [--root <repo>] [--layer Models|Views] [--why <from> <to>] [--json]
  --layer   one graph only (default: both)
  --why     the types and the files behind the edge <from> -> <to> (domain names, e.g. Browser AgentTools; needs --layer)
  --json    print the measurement as JSON (the lint rule reads it this way)

The layering is printed in the report; `rank(domain)` and `back_edges(layer)` are what the lint rule calls.
"""
import argparse
import json
import re
import sys
from pathlib import Path

LAYERS = ("Models", "Views")
# The layering of the domain folders, lowest first. A folder with no entry is a feature domain.
RANKS = {"Appearance": 0, "Shared": 1, "AI": 2}
FEATURE_RANK = 3
COMPOSITION = "Workspace"   # the domain that composes the others: the highest rank, named by no feature domain
COMPOSITION_RANK = 4


def rank(domain):
    return COMPOSITION_RANK if domain == COMPOSITION else RANKS.get(domain, FEATURE_RANK)

TOKEN = re.compile(r'//[^\n]*|/\*|#{0,4}"""|#{0,4}"|[A-Za-z_]\w*|[()]')
DECLARATION = re.compile(
    r"^(?P<indent>[ \t]*)(?:@\w+(?:\([^)\n]*\))?[ \t]+)*(?P<mods>(?:(?:public|private|fileprivate|internal|open|final|indirect|nonisolated|package)[ \t]+)*)"
    r"(?:class|struct|enum|protocol|actor|typealias)[ \t]+(?P<name>[A-Za-z_]\w*)",
    re.M)


def identifiers(text):
    """Every identifier in code that is not a member name (`x.Name`): comments and string literals are skipped, interpolations read."""
    found = set()

    def string_end(position, opener):
        hashes = opener.count("#")
        close = ('"""' if opener.endswith('"""') else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        body = re.compile(re.escape(close) + "|" + re.escape(escape) + r"\(|" + re.escape(escape) + r"[\s\S]")
        while True:
            match = body.search(text, position)
            if not match:
                return len(text)
            if match.group() == close:
                return match.end()
            if match.group().endswith("("):
                position = code(match.end(), True)
            else:
                position = match.end()

    def code(position, until_paren):
        depth = 0
        while True:
            match = TOKEN.search(text, position)
            if not match:
                return len(text)
            token = match.group()
            position = match.end()
            if token.startswith("//"):
                continue
            if token == "/*":
                nesting = 1
                while nesting and position < len(text):
                    step = re.compile(r"/\*|\*/").search(text, position)
                    if not step:
                        return len(text)
                    nesting += 1 if step.group() == "/*" else -1
                    position = step.end()
                continue
            if '"' in token:
                position = string_end(position, token)
                continue
            if token == "(":
                depth += 1
            elif token == ")":
                if until_paren and depth == 0:
                    return position
                depth -= 1
            elif match.start() == 0 or text[match.start() - 1] != ".":
                found.add(token)

    code(0, False)
    return found


def measure(root, layers=LAYERS):
    """{layer: {domains, files, declared, ambiguous, edges, pairs}} for the Swift code under root/MarkView/<layer>/<domain>/."""
    result = {}
    for layer in layers:
        base = Path(root) / "MarkView" / layer
        domains = sorted(p.name for p in base.iterdir() if p.is_dir()) if base.is_dir() else []
        files = {}
        for domain in domains:
            files[domain] = sorted(p for p in (base / domain).rglob("*.swift") if p.is_file())
        toplevel = {}    # type name -> domains that declare it at the top level and not privately
        nested = {}      # domain -> every name declared anywhere in it (any indentation, private or not)
        texts = {}
        for domain in domains:
            nested[domain] = set()
            for path in files[domain]:
                text = path.read_text(encoding="utf-8", errors="replace")
                texts[path] = text
                for match in DECLARATION.finditer(text):
                    nested[domain].add(match.group("name"))
                    if not match.group("indent") and not re.search(r"private|fileprivate", match.group("mods")):
                        toplevel.setdefault(match.group("name"), set()).add(domain)
        ambiguous = {}   # name -> domains in which it is declared or ignored
        links = {}       # (from, to) -> {type name -> [files]}
        for domain in domains:
            for path in files[domain]:
                local = {m.group("name") for m in DECLARATION.finditer(texts[path])}
                for name in identifiers(texts[path]) - local:
                    owners = toplevel.get(name)
                    if not owners or owners == {domain}:
                        continue
                    if len(owners) > 1 or name in nested[domain]:
                        ambiguous.setdefault(name, set()).update(owners | ({domain} if name in nested[domain] else set()))
                        continue
                    owner = next(iter(owners))
                    links.setdefault((domain, owner), {}).setdefault(name, []).append(path.relative_to(root).as_posix())
        edges = {pair: len(types) for pair, types in links.items()}
        pairs = []
        for (a, b), weight in sorted(edges.items()):
            back = edges.get((b, a))
            if back and (a, b) < (b, a):
                pairs.append({"a": a, "b": b, "a_to_b": weight, "b_to_a": back})
        result[layer] = {
            "domains": domains,
            "files": {domain: len(paths) for domain, paths in files.items()},
            "declared": {domain: sum(1 for owners in toplevel.values() if domain in owners) for domain in domains},
            "ambiguous": {name: sorted(owners) for name, owners in sorted(ambiguous.items())},
            "edges": edges,
            "pairs": pairs,
            "links": links,
        }
    return result


def back_edge(pair, preferred=()):
    """(from, to, weight, forward weight) of the back-edge of a pair of domains that name each other: the direction `preferred` (a set
    of (from, to)) names, else the one that points up the layering, else (two domains of one rank) the lighter direction."""
    a, b, ab, ba = pair["a"], pair["b"], pair["a_to_b"], pair["b_to_a"]
    if (a, b) in preferred:
        return a, b, ab, ba
    if (b, a) in preferred:
        return b, a, ba, ab
    if rank(a) != rank(b):
        return (a, b, ab, ba) if rank(b) > rank(a) else (b, a, ba, ab)
    return (a, b, ab, ba) if (ab, a, b) <= (ba, b, a) else (b, a, ba, ab)


def back_edges(layer, preferred=()):
    """[(from, to, weight, forward weight)], sorted: the back-edge of every pair of domains that name each other, and every edge that
    points up the layering although nothing points back (a lower domain that names a higher one has it inside)."""
    found = {}
    for pair in layer["pairs"]:
        source, target, weight, forward = back_edge(pair, preferred)
        found[(source, target)] = (weight, forward)
    for (source, target), weight in layer["edges"].items():
        if rank(target) > rank(source):
            found.setdefault((source, target), (weight, layer["edges"].get((target, source), 0)))
    return [(source, target, weight, forward) for (source, target), (weight, forward) in sorted(found.items())]


def components(layer):
    """The strongly connected groups of domains (size above one) of the edge graph, as sorted lists."""
    graph = {domain: [] for domain in layer["domains"]}
    for (a, b) in layer["edges"]:
        graph[a].append(b)
    index, low, on_stack, stack, groups, counter = {}, {}, set(), [], [], [0]

    def visit(node):
        index[node] = low[node] = counter[0]
        counter[0] += 1
        stack.append(node)
        on_stack.add(node)
        for target in graph[node]:
            if target not in index:
                visit(target)
                low[node] = min(low[node], low[target])
            elif target in on_stack:
                low[node] = min(low[node], index[target])
        if low[node] == index[node]:
            group = []
            while True:
                member = stack.pop()
                on_stack.discard(member)
                group.append(member)
                if member == node:
                    break
            if len(group) > 1:
                groups.append(sorted(group))

    sys.setrecursionlimit(10000)
    for node in layer["domains"]:
        if node not in index:
            visit(node)
    return sorted(groups)


def report(layer_name, layer):
    lines = []
    domains = layer["domains"]
    pairs = layer["pairs"]
    type_edges = sum(p["a_to_b"] + p["b_to_a"] for p in pairs)
    back = back_edges(layer)
    lines.append(f"{layer_name}: {len(domains)} domains, {sum(layer['files'].values())} files, {sum(layer['declared'].values())} top-level types")
    lines.append(f"  domain pairs in cycles: {len(pairs)}; type edges in them: {type_edges}")
    lines.append(f"  back-edges (up the layering, or the lighter side of a cycle): {len(back)}; types in them: {sum(b[2] for b in back)}")
    for source, target, weight, forward in sorted(back, key=lambda b: (-b[2], b[0], b[1])):
        lines.append(f"    {source} -> {target}: {weight} type(s) back, {forward} forward")
    groups = components(layer)
    lines.append("  strongly connected groups: " + ("; ".join(f"{len(g)} domains" for g in groups) if groups else "none"))
    fan_out, fan_in = {}, {}
    for (a, b), weight in layer["edges"].items():
        fan_out.setdefault(a, []).append((b, weight))
        fan_in.setdefault(b, []).append((a, weight))
    lines.append("  domain: depends on (domains, types) / used by (domains, types)")
    for domain in domains:
        out, inn = fan_out.get(domain, []), fan_in.get(domain, [])
        lines.append(f"    {domain}: {len(out)} / {sum(w for _, w in out)} ; {len(inn)} / {sum(w for _, w in inn)}")
    if layer["ambiguous"]:
        lines.append(f"  ambiguous names ignored ({len(layer['ambiguous'])}): " + ", ".join(
            f"{name} ({'/'.join(owners)})" for name, owners in layer["ambiguous"].items()))
    return lines


def main():
    parser = argparse.ArgumentParser(description="Dependencies between the domain folders of MarkView/Models and MarkView/Views.")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--layer", choices=LAYERS)
    parser.add_argument("--why", nargs=2, metavar=("FROM", "TO"))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    layers = (args.layer,) if args.layer else LAYERS
    measured = measure(args.root, layers)
    if args.why:
        if not args.layer:
            parser.error("--why needs --layer")
        types = measured[args.layer]["links"].get(tuple(args.why), {})
        print(f"{args.why[0]} -> {args.why[1]}: {len(types)} type(s)")
        for name, found in sorted(types.items()):
            print(f"  {name}: " + ", ".join(sorted(set(found))))
        return
    if args.json:
        printable = {}
        for layer, data in measured.items():
            printable[layer] = {key: value for key, value in data.items() if key not in ("edges", "links")}
            printable[layer]["edges"] = {f"{a} -> {b}": weight for (a, b), weight in sorted(data["edges"].items())}
        print(json.dumps(printable, indent=1, sort_keys=True))
        return
    for layer in layers:
        print("\n".join(report(layer, measured[layer])))


if __name__ == "__main__":
    main()
