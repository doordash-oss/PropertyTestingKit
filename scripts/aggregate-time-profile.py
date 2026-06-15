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
total time to every distinct symbol appearing in the stack. Frames are defined
once (id+name) and back-referenced by ref=, so we resolve a global id->name map
while streaming (handles the 10s-of-MB export without loading it all).
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
    args = ap.parse_args()

    frame_name = {}            # frame id -> symbol name
    weight_by_id = {}          # weight id -> ns (Instruments dedups repeats by ref=)
    self_ns = defaultdict(int)  # leaf symbol -> ns
    total_ns = defaultdict(int)  # symbol -> ns (counted once per sample)
    grand_total = 0

    cur_weight = 0
    leaf = None
    stack_syms = None
    in_row = False

    # Stream: clear elements as we go to bound memory.
    for event, el in ET.iterparse(args.xml, events=("start", "end")):
        tag = el.tag
        if event == "start":
            if tag == "row":
                in_row = True
                cur_weight = 0
                leaf = None
                stack_syms = set()
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
            if in_row and sym is not None:
                if leaf is None:
                    leaf = sym
                stack_syms.add(sym)
        elif tag == "row":
            include = True
            if args.under is not None:
                under = args.under.lower()
                include = any(under in s.lower() for s in (stack_syms or ()))
            if include:
                if leaf is not None:
                    self_ns[leaf] += cur_weight
                for s in (stack_syms or ()):
                    total_ns[s] += cur_weight
                grand_total += cur_weight
            in_row = False
            el.clear()

    if grand_total == 0:
        print("No samples found. Did the xpath/export succeed?", file=sys.stderr)
        sys.exit(1)

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
