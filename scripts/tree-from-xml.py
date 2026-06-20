#!/usr/bin/env python3
"""
Reconstruct the Instruments "Deep Copy" call tree (Weight / Self Weight / indented
Symbol Names) directly from a headless `xctrace export` time-profile XML — the SAME
data aggregate-time-profile.py consumes. Proves the headless export contains
everything the GUI deep-copy does; the GUI step is never required.

    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
      xcrun xctrace export --input X.trace \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > tp.xml
    ./scripts/tree-from-xml.py tp.xml                 # print the call tree
    ./scripts/tree-from-xml.py tp.xml --verify call_trees/tree.txt   # diff vs a GUI deep-copy

Each <row> is one CPU sample: a <weight> (ns) and a <backtrace> of frames listed
INNERMOST-FIRST (leaf→root). The call tree is those stacks merged from the root
down: a node's Weight is the inclusive ns of every sample passing through it; its
Self Weight is the ns of samples whose LEAF it is. Children are sorted by Weight
descending — exactly the GUI's default. Instruments dedups <frame>/<weight>/
<backtrace> by ref=; all three id->value maps are resolved while streaming.
"""
import sys
import argparse
import xml.etree.ElementTree as ET


class Node:
    __slots__ = ("sym", "incl", "self_w", "kids")

    def __init__(self, sym):
        self.sym = sym
        self.incl = 0
        self.self_w = 0
        self.kids = {}


def parse_samples(xml_path):
    """Yield (weight_ns, [leaf..root] symbols) per sample, resolving all ref= dedup."""
    frame_name = {}
    weight_by_id = {}
    backtrace_frames = {}
    cur_weight = 0
    in_row = False
    in_backtrace = False
    cur_bt_order = None
    stack_order = None

    for event, el in ET.iterparse(xml_path, events=("start", "end")):
        tag = el.tag
        if event == "start":
            if tag == "row":
                in_row = True
                cur_weight = 0
                stack_order = []
            elif tag == "backtrace":
                in_backtrace = True
                cur_bt_order = []
            continue
        if tag == "weight" and in_row:
            wid, ref = el.get("id"), el.get("ref")
            if wid is not None and el.text:
                cur_weight = int(el.text)
                weight_by_id[wid] = cur_weight
            elif ref is not None:
                cur_weight = weight_by_id.get(ref, 0)
        elif tag == "frame":
            fid, name, ref = el.get("id"), el.get("name"), el.get("ref")
            if fid is not None and name is not None:
                frame_name[fid] = name
                sym = name
            elif ref is not None:
                sym = frame_name.get(ref)
            else:
                sym = name
            if in_backtrace and sym is not None:
                cur_bt_order.append(sym)
        elif tag == "backtrace":
            bid, ref = el.get("id"), el.get("ref")
            if bid is not None:
                backtrace_frames[bid] = cur_bt_order
                stack_order = cur_bt_order
            elif ref is not None:
                stack_order = backtrace_frames.get(ref, [])
            else:
                stack_order = cur_bt_order
            in_backtrace = False
            cur_bt_order = None
        elif tag == "row":
            yield cur_weight, (stack_order or [])
            in_row = False
            el.clear()


def build_tree(xml_path):
    root = Node(None)  # virtual root; its children are the sample roots
    grand = 0
    for w, leaf_root in parse_samples(xml_path):
        if not leaf_root:
            continue
        grand += w
        node = root
        # merge from the OUTERMOST frame (root-side) down to the leaf
        path = list(reversed(leaf_root))
        for sym in path:
            child = node.kids.get(sym)
            if child is None:
                child = Node(sym)
                node.kids[sym] = child
            child.incl += w
            node = child
        node.self_w += w  # leaf of this sample
    return root, grand


# --- Instruments-style formatting -------------------------------------------

def fmt_weight(ns):
    if ns == 0:
        return "0 s"
    s = ns / 1e9
    if s >= 60:
        return f"{s/60:.2f} min"
    if s >= 1:
        return f"{s:.2f} s"
    ms = ns / 1e6
    if ms >= 1:
        return f"{ms:.2f} ms"
    us = ns / 1e3
    if us >= 1:
        return f"{us:.2f} µs"
    return f"{ns} ns"


def print_tree(root, grand, out=sys.stdout, max_lines=None):
    print("Weight\tSelf Weight\tSymbol Names", file=out)
    n = [0]

    def walk(node, depth):
        if max_lines is not None and n[0] >= max_lines:
            return
        pct = 100.0 * node.incl / grand if grand else 0.0
        indent = " " * (depth + 2)
        print(f"{fmt_weight(node.incl)}  {pct:.1f}%\t{fmt_weight(node.self_w)}\t{indent}{node.sym}",
              file=out)
        n[0] += 1
        for kid in sorted(node.kids.values(), key=lambda c: c.incl, reverse=True):
            walk(kid, depth + 1)

    for kid in sorted(root.kids.values(), key=lambda c: c.incl, reverse=True):
        walk(kid, 0)


# --- verification against a GUI deep-copy ------------------------------------

def parse_units(s):
    s = s.strip()
    if s == "0 s" or not s:
        return 0.0
    num, unit = s.rsplit(" ", 1)
    mult = {"min": 60, "s": 1, "ms": 1e-3, "µs": 1e-6, "us": 1e-6, "ns": 1e-9}[unit]
    return float(num) * mult


def self_by_symbol_from_deepcopy(path):
    agg = {}
    with open(path) as f:
        next(f)  # header
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 3:
                continue
            self_w = parse_units(cols[1])
            sym = cols[2].strip()
            agg[sym] = agg.get(sym, 0.0) + self_w
    return agg


def self_by_symbol_from_tree(root):
    agg = {}

    def walk(node):
        if node.sym is not None:
            agg[node.sym] = agg.get(node.sym, 0.0) + node.self_w / 1e9
        for k in node.kids.values():
            walk(k)

    walk(root)
    return agg


def verify(root, grand, deepcopy_path):
    gui = self_by_symbol_from_deepcopy(deepcopy_path)
    mine = self_by_symbol_from_tree(root)
    gui_total = sum(gui.values())
    mine_total = sum(mine.values())
    print(f"GUI deep-copy total self : {gui_total:8.2f}s across {len(gui)} symbols")
    print(f"XML-reconstructed self   : {mine_total:8.2f}s across {len(mine)} symbols")
    print(f"grand (inclusive root)   : {grand/1e9:8.2f}s\n")
    syms = sorted(set(gui) | set(mine), key=lambda s: -max(gui.get(s, 0), mine.get(s, 0)))
    print(f"{'GUI(s)':>9} {'XML(s)':>9} {'delta':>8}  symbol")
    print("-" * 80)
    worst = 0.0
    for s in syms[:25]:
        g, m = gui.get(s, 0.0), mine.get(s, 0.0)
        worst = max(worst, abs(g - m))
        print(f"{g:9.2f} {m:9.2f} {g-m:+8.3f}  {s[:60]}")
    allworst = max((abs(gui.get(s, 0) - mine.get(s, 0)) for s in set(gui) | set(mine)), default=0)
    print(f"\nmax abs self-weight delta over ALL symbols: {allworst:.3f}s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xml")
    ap.add_argument("--verify", default=None, help="compare to a GUI deep-copy tree.txt")
    ap.add_argument("--max-lines", type=int, default=None, help="limit printed tree lines")
    args = ap.parse_args()

    root, grand = build_tree(args.xml)
    if grand == 0:
        print("No samples found. Did the xpath/export succeed?", file=sys.stderr)
        sys.exit(1)

    if args.verify:
        verify(root, grand, args.verify)
    else:
        print_tree(root, grand, max_lines=args.max_lines)


if __name__ == "__main__":
    main()
