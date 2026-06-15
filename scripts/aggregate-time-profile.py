#!/usr/bin/env python3
"""
Aggregate an Instruments Time Profiler trace into CPU-weighted self/total time
per symbol — fully headless (no GUI "Deep Copy" step that parse-call-tree.py
needs).

Pipeline:
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
      xcrun xctrace export --input X.trace \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > tp.xml
    ./scripts/aggregate-time-profile.py tp.xml --top 30 [--grep PATTERN]

Each <row> is one sample carrying a <weight> (ns) and a <backtrace> whose frames
are listed innermost-first. Self time is attributed to the leaf (first) frame;
total time to every distinct symbol appearing in the stack.

Instruments dedups THREE levels by ref=, and ALL must be resolved or attribution
silently vanishes: <frame> (id+name, then ref), <weight> (id+ns, then ref), AND
<backtrace> (id + child frames, then ref). The backtrace dedup is the big one —
a hot loop samples the SAME stack millions of times, so the vast majority of rows
are `<backtrace ref="N"/>` with no inline frames. Miss it and those rows count
toward grand_total but attribute to nothing → a phantom "unsymbolicated" majority.
We resolve all three id->value maps while streaming (handles the 10s-of-MB export
without loading it all).
"""
import sys
import argparse
import xml.etree.ElementTree as ET
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xml")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--grep", default=None, help="only show symbols matching this substring")
    ap.add_argument("--total", action="store_true", help="sort by total (inclusive) time")
    ap.add_argument("--under", default=None,
                    help="only count samples whose stack contains a frame matching this "
                         "substring (isolates one subtree's internal self-time breakdown)")
    ap.add_argument("--stacks", type=int, default=0,
                    help="instead of per-symbol, report the N heaviest full call stacks "
                         "(samples keyed by their entire leaf→root backtrace)")
    ap.add_argument("--depth", type=int, default=12,
                    help="frames of each stack to print in --stacks mode (leaf first)")
    ap.add_argument("--fromroot", action="store_true",
                    help="in --stacks mode, key/print from the OUTERMOST (root-side) frames "
                         "instead of the leaf — shows the top-level branches of the call tree")
    args = ap.parse_args()

    frame_name = {}            # frame id -> symbol name
    weight_by_id = {}          # weight id -> ns (Instruments dedups repeats by ref=)
    backtrace_frames = {}      # backtrace id -> ordered [leaf..root] symbols
    self_ns = defaultdict(int)  # leaf symbol -> ns
    total_ns = defaultdict(int)  # symbol -> ns (counted once per sample)
    grand_total = 0

    stack_ns = defaultdict(int)   # full-path key -> ns
    stack_path = {}               # full-path key -> ordered [leaf..root] symbols

    cur_weight = 0
    in_row = False
    # The frame list for the backtrace currently being parsed. Frames append here
    # (leaf→root, as emitted); resolved to stack_order at </backtrace>.
    cur_bt_order = None
    in_backtrace = False
    # The resolved stack for the current row (set at </backtrace>).
    stack_order = None

    # Stream: clear elements as we go to bound memory.
    for event, el in ET.iterparse(args.xml, events=("start", "end")):
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
        # end events
        if tag == "weight":
            if in_row:
                wid = el.get("id")
                ref = el.get("ref")
                if wid is not None and el.text:
                    cur_weight = int(el.text)
                    weight_by_id[wid] = cur_weight
                elif ref is not None:
                    cur_weight = weight_by_id.get(ref, 0)
        elif tag == "frame":
            # Resolve name: defined (id+name) or referenced (ref).
            fid = el.get("id")
            name = el.get("name")
            ref = el.get("ref")
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
            # Resolve the row's stack: a backtrace is either DEFINED (id + inline
            # frames) or a back-REFERENCE (ref=) to one defined earlier. The hot
            # loop makes the vast majority refs, so this is where most weight is.
            bid = el.get("id")
            ref = el.get("ref")
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
            stack_order = stack_order or []
            stack_syms = set(stack_order)
            leaf = stack_order[0] if stack_order else None
            include = True
            if args.under is not None:
                under = args.under.lower()
                include = any(under in s.lower() for s in (stack_syms or ()))
            if include:
                if leaf is not None:
                    self_ns[leaf] += cur_weight
                for s in (stack_syms or ()):
                    total_ns[s] += cur_weight
                if args.stacks and stack_order:
                    if args.fromroot:
                        # Outermost frames (root-side): the top-level branches of
                        # the call tree. stack_order is leaf→root, so the root is
                        # the tail; print root→leaf.
                        truncated = list(reversed(stack_order))[: args.depth]
                    else:
                        # Leaf-side frames only: the deep task/runtime prefix
                        # varies per sample and would fragment otherwise-identical
                        # hot paths. `--depth` frames define the tree.
                        truncated = stack_order[: args.depth]
                    key = "\x01".join(truncated)
                    stack_ns[key] += cur_weight
                    if key not in stack_path:
                        stack_path[key] = truncated
                grand_total += cur_weight
            in_row = False
            el.clear()

    if grand_total == 0:
        print("No samples found. Did the xpath/export succeed?", file=sys.stderr)
        sys.exit(1)

    if args.stacks:
        rows = sorted(stack_ns.items(), key=lambda kv: kv[1], reverse=True)[: args.stacks]
        print(f"Total CPU sampled: {grand_total/1e6:.1f} ms across {len(stack_ns)} distinct stacks\n")
        for rank, (key, ns) in enumerate(rows, 1):
            path = stack_path[key]
            print(f"#{rank}  {100*ns/grand_total:6.2f}%  {ns/1e6:8.1f} ms  (leaf→ {len(path)} frames)")
            for sym in path:
                print(f"        {sym}")
            print()
        return

    key = total_ns if args.total else self_ns
    label = "TOTAL" if args.total else "SELF"
    rows = sorted(key.items(), key=lambda kv: kv[1], reverse=True)
    if args.grep:
        rows = [(s, v) for s, v in rows if args.grep.lower() in s.lower()]

    gt_ms = grand_total / 1e6
    print(f"Total CPU sampled: {gt_ms:.1f} ms across {len(self_ns)} leaf symbols\n")
    print(f"{'self%':>7} {'total%':>7} {'self ms':>9} {'total ms':>9}  symbol")
    print("-" * 90)
    for sym, _ in rows[: args.top]:
        s = self_ns.get(sym, 0)
        t = total_ns.get(sym, 0)
        print(f"{100*s/grand_total:6.2f}% {100*t/grand_total:6.2f}% "
              f"{s/1e6:9.1f} {t/1e6:9.1f}  {sym}")


if __name__ == "__main__":
    main()
