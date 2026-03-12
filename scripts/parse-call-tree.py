#!/usr/bin/env python3
"""
Parse and analyze Instruments call tree exports.

Usage:
    ./scripts/parse-call-tree.py <call_tree.txt> [options]

Options:
    --top N             Show top N most expensive functions (default: 20)
    --search PATTERN    Search for functions matching pattern
    --threshold MS      Only show functions taking >= MS milliseconds
    --self-time         Sort by self time instead of total time
    --subtree PATTERN   Focus analysis on subtree rooted at function matching PATTERN
                        (filters out benchmark machinery, focuses on actual code)
    --children LINE     Show direct children of entry at LINE number

Output columns:
    - Total time: Time spent in function including children
    - Self time: Time spent in function excluding children
    - % of parent: What percentage of the immediate caller's time this represents
    - Line number: Line in the call tree file for reference

Example:
    # Focus on the async task completion subtree (skips benchmark overhead)
    ./scripts/parse-call-tree.py call_trees/tree.txt --subtree completeTaskWithClosure --top 30
"""

import sys
import re
import argparse
from dataclasses import dataclass
from typing import Optional


@dataclass
class CallTreeEntry:
    weight: float  # Total time in seconds
    self_weight: float  # Self time in seconds
    depth: int  # Indentation level
    symbol: str  # Function name
    line_number: int
    parent_index: Optional[int] = None  # Index of parent in entries list
    pct_of_parent: Optional[float] = None  # Percentage of parent's time


def parse_time(time_str: str) -> float:
    """Parse time string like '5.43 s' or '155.00 ms' or '329.00 µs' or '2.72 min' to seconds."""
    time_str = time_str.strip()
    match = re.match(r'([\d.]+)\s*(min|s|ms|µs|us)', time_str)
    if not match:
        return 0.0

    value = float(match.group(1))
    unit = match.group(2)

    if unit == 'min':
        return value * 60
    elif unit == 's':
        return value
    elif unit == 'ms':
        return value / 1000
    elif unit in ('µs', 'us'):
        return value / 1_000_000
    return 0.0


def parse_call_tree(filepath: str) -> list[CallTreeEntry]:
    """Parse a call tree file into structured entries."""
    entries = []

    with open(filepath, 'r') as f:
        lines = f.readlines()

    # Skip header line
    for i, line in enumerate(lines[1:], start=2):
        # Format: "Weight\tSelf Weight\tSymbol Names"
        # Weight looks like: "5.43 s  40.5%"
        # Symbol has leading whitespace indicating depth

        parts = line.split('\t')
        if len(parts) < 3:
            continue

        weight_part = parts[0]
        self_weight_part = parts[1]
        symbol_part = parts[2].rstrip('\n')

        # Extract time from weight (ignore percentage)
        weight_match = re.match(r'([\d.]+\s*(?:min|s|ms|µs|us))', weight_part)
        self_match = re.match(r'([\d.]+\s*(?:min|s|ms|µs|us))', self_weight_part)

        if not weight_match:
            continue

        weight = parse_time(weight_match.group(1))
        self_weight = parse_time(self_match.group(1)) if self_match else 0.0

        # Calculate depth from leading whitespace in symbol
        stripped = symbol_part.lstrip()
        depth = len(symbol_part) - len(stripped)
        symbol = stripped

        entries.append(CallTreeEntry(
            weight=weight,
            self_weight=self_weight,
            depth=depth,
            symbol=symbol,
            line_number=i
        ))

    return entries


def compute_parent_relationships(entries: list[CallTreeEntry]) -> None:
    """Compute parent indices and percentage of parent time for each entry."""
    # Stack of (depth, index) to track ancestors
    depth_stack: list[tuple[int, int]] = []

    for i, entry in enumerate(entries):
        # Pop entries from stack that aren't ancestors (same or greater depth)
        while depth_stack and depth_stack[-1][0] >= entry.depth:
            depth_stack.pop()

        # The top of stack (if any) is our parent
        if depth_stack:
            parent_idx = depth_stack[-1][1]
            entry.parent_index = parent_idx
            parent = entries[parent_idx]
            if parent.weight > 0:
                entry.pct_of_parent = (entry.weight / parent.weight) * 100

        # Push current entry onto stack
        depth_stack.append((entry.depth, i))


def format_time(seconds: float) -> str:
    """Format seconds into human-readable string."""
    if seconds >= 60:
        return f"{seconds / 60:.2f}min"
    elif seconds >= 1:
        return f"{seconds:.2f}s"
    elif seconds >= 0.001:
        return f"{seconds * 1000:.2f}ms"
    else:
        return f"{seconds * 1_000_000:.2f}µs"


def top_functions(entries: list[CallTreeEntry], n: int = 20, by_self: bool = False) -> None:
    """Show top N most expensive functions."""
    # Get total time from root
    total_time = max(e.weight for e in entries) if entries else 1.0

    # Aggregate by symbol name
    totals: dict[str, tuple[float, float]] = {}  # symbol -> (total_weight, total_self)

    for e in entries:
        if e.symbol in totals:
            old_weight, old_self = totals[e.symbol]
            totals[e.symbol] = (max(old_weight, e.weight), old_self + e.self_weight)
        else:
            totals[e.symbol] = (e.weight, e.self_weight)

    # Sort by chosen metric
    if by_self:
        sorted_funcs = sorted(totals.items(), key=lambda x: x[1][1], reverse=True)
    else:
        sorted_funcs = sorted(totals.items(), key=lambda x: x[1][0], reverse=True)

    print(f"\n{'='*80}")
    print(f"Top {n} functions by {'self time' if by_self else 'total time'}:")
    print(f"{'='*80}\n")

    for symbol, (weight, self_weight) in sorted_funcs[:n]:
        # Truncate long symbols
        display_symbol = symbol[:60] + "..." if len(symbol) > 60 else symbol
        pct_total = (weight / total_time) * 100
        pct_self = (self_weight / total_time) * 100
        print(f"  {format_time(weight):>10} ({pct_total:5.1f}%)  self: {format_time(self_weight):>10} ({pct_self:5.1f}%)  {display_symbol}")


def format_pct_parent(entry: CallTreeEntry, entries: list[CallTreeEntry]) -> str:
    """Format percentage of parent time, including parent symbol."""
    if entry.pct_of_parent is None:
        return "root"
    parent = entries[entry.parent_index]
    # Truncate parent symbol to keep output readable
    parent_short = parent.symbol[:30] + "..." if len(parent.symbol) > 30 else parent.symbol
    return f"{entry.pct_of_parent:5.1f}% of {parent_short}"


def search_functions(entries: list[CallTreeEntry], pattern: str) -> None:
    """Search for functions matching a pattern."""
    pattern_lower = pattern.lower()
    matches = [e for e in entries if pattern_lower in e.symbol.lower()]

    print(f"\n{'='*80}")
    print(f"Functions matching '{pattern}' ({len(matches)} matches):")
    print(f"{'='*80}\n")

    # Sort by weight descending
    matches.sort(key=lambda e: e.weight, reverse=True)

    for e in matches[:50]:  # Limit to 50 results
        display_symbol = e.symbol[:50] + "..." if len(e.symbol) > 50 else e.symbol
        pct_info = f"({e.pct_of_parent:5.1f}% of parent)" if e.pct_of_parent else "(root)"
        print(f"  {format_time(e.weight):>10}  (self: {format_time(e.self_weight):>10})  {pct_info:>20}  L{e.line_number:<5}  {display_symbol}")


def filter_by_threshold(entries: list[CallTreeEntry], threshold_ms: float) -> None:
    """Show functions taking at least threshold_ms milliseconds."""
    threshold_s = threshold_ms / 1000
    matches = [e for e in entries if e.weight >= threshold_s]

    print(f"\n{'='*80}")
    print(f"Functions taking >= {threshold_ms}ms ({len(matches)} matches):")
    print(f"{'='*80}\n")

    matches.sort(key=lambda e: e.weight, reverse=True)

    for e in matches[:100]:
        display_symbol = e.symbol[:60] + "..." if len(e.symbol) > 60 else e.symbol
        print(f"  {format_time(e.weight):>10}  (self: {format_time(e.self_weight):>10})  L{e.line_number:<5}  {display_symbol}")


def summary(entries: list[CallTreeEntry]) -> None:
    """Print a summary of the call tree."""
    if not entries:
        print("No entries found.")
        return

    total_time = max(e.weight for e in entries)
    total_self = sum(e.self_weight for e in entries)

    print(f"\n{'='*80}")
    print("Call Tree Summary")
    print(f"{'='*80}\n")
    print(f"  Total entries: {len(entries)}")
    print(f"  Total time: {format_time(total_time)}")
    print(f"  Total self time: {format_time(total_self)}")
    print(f"  Max depth: {max(e.depth for e in entries)}")


def show_children(entries: list[CallTreeEntry], line_number: int) -> None:
    """Show direct children of the entry at the given line number."""
    # Find the parent entry
    parent = None
    parent_idx = None
    for i, e in enumerate(entries):
        if e.line_number == line_number:
            parent = e
            parent_idx = i
            break

    if parent is None:
        print(f"No entry found at line {line_number}")
        return

    print(f"\n{'='*80}")
    print(f"Children of L{line_number}: {parent.symbol[:60]}")
    print(f"Parent total: {format_time(parent.weight)}")
    print(f"{'='*80}\n")

    # Find direct children (entries that have this as their parent)
    children = [e for e in entries if e.parent_index == parent_idx]

    # Sort by weight descending
    children.sort(key=lambda e: e.weight, reverse=True)

    total_child_time = sum(c.weight for c in children)
    accounted_pct = (total_child_time / parent.weight * 100) if parent.weight > 0 else 0

    for c in children:
        pct = (c.weight / parent.weight * 100) if parent.weight > 0 else 0
        display_symbol = c.symbol[:50] + "..." if len(c.symbol) > 50 else c.symbol
        print(f"  {format_time(c.weight):>10}  ({pct:5.1f}%)  L{c.line_number:<5}  {display_symbol}")

    print(f"\n  {'─'*70}")
    print(f"  Children total: {format_time(total_child_time)} ({accounted_pct:.1f}% of parent)")
    print(f"  Self time: {format_time(parent.self_weight)} ({parent.self_weight/parent.weight*100:.1f}% of parent)" if parent.weight > 0 else "")
    unaccounted = parent.weight - total_child_time - parent.self_weight
    if unaccounted > 0.001:  # More than 1ms unaccounted
        print(f"  Unaccounted: {format_time(unaccounted)} ({unaccounted/parent.weight*100:.1f}%)")


def filter_to_subtree(entries: list[CallTreeEntry], pattern: str) -> list[CallTreeEntry]:
    """Filter entries to only those within a subtree rooted at a function matching pattern."""
    pattern_lower = pattern.lower()

    # Find the subtree root (first match)
    root_idx = None
    root_depth = None
    for i, e in enumerate(entries):
        if pattern_lower in e.symbol.lower():
            root_idx = i
            root_depth = e.depth
            print(f"  Subtree root: {e.symbol[:70]}...")
            print(f"  Subtree time: {format_time(e.weight)}")
            break

    if root_idx is None:
        print(f"Warning: No function matching '{pattern}' found")
        return entries

    # Collect all entries within this subtree (root + all entries with greater depth until we hit same/lesser depth)
    subtree = [entries[root_idx]]
    for e in entries[root_idx + 1:]:
        if e.depth > root_depth:
            subtree.append(e)
        else:
            break  # Exited the subtree

    print(f"  Subtree entries: {len(subtree)} of {len(entries)}")

    return subtree


def main():
    parser = argparse.ArgumentParser(description="Parse and analyze Instruments call tree exports")
    parser.add_argument("file", help="Call tree file to analyze")
    parser.add_argument("--top", type=int, default=20, help="Show top N functions (default: 20)")
    parser.add_argument("--search", type=str, help="Search for functions matching pattern")
    parser.add_argument("--threshold", type=float, help="Only show functions >= N milliseconds")
    parser.add_argument("--self-time", action="store_true", help="Sort by self time instead of total")
    parser.add_argument("--children", type=int, metavar="LINE", help="Show direct children of entry at LINE")
    parser.add_argument("--subtree", type=str, metavar="PATTERN",
                        default="completeTaskWithClosure",
                        help="Focus analysis on subtree rooted at function matching PATTERN (default: completeTaskWithClosure)")
    parser.add_argument("--no-subtree", action="store_true",
                        help="Disable subtree filtering, analyze entire call tree")

    args = parser.parse_args()

    entries = parse_call_tree(args.file)
    compute_parent_relationships(entries)

    # Filter to subtree by default (use --no-subtree to disable)
    if args.subtree and not args.no_subtree:
        print(f"\n{'='*80}")
        print(f"Filtering to subtree: {args.subtree}")
        print(f"{'='*80}")
        entries = filter_to_subtree(entries, args.subtree)
        # Recompute parent relationships for filtered entries
        compute_parent_relationships(entries)

    summary(entries)

    if args.children:
        show_children(entries, args.children)
    elif args.search:
        search_functions(entries, args.search)
    elif args.threshold:
        filter_by_threshold(entries, args.threshold)
    else:
        top_functions(entries, args.top, args.self_time)


if __name__ == "__main__":
    main()
