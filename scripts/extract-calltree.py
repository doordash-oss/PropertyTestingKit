#!/usr/bin/env python3
"""
Extract call tree from Instruments .trace file and convert to text format.

Usage:
    ./scripts/extract-calltree.py <recording.trace> [--output <output.txt>]

This extracts the Time Profiler samples from an Instruments trace file,
aggregates them into a call tree, and outputs in the tab-separated format
expected by parse-call-tree.py.
"""

import subprocess
import sys
import xml.etree.ElementTree as ET
import argparse
import os
import re
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class CallTreeNode:
    """A node in the aggregated call tree."""
    name: str
    weight: float = 0.0  # Total time (includes children)
    self_weight: float = 0.0  # Self time (excludes children)
    children: dict = field(default_factory=dict)  # name -> CallTreeNode


def get_trace_toc(trace_path: str) -> str:
    """Get the table of contents from a trace file."""
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace_path, "--toc"],
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        print(f"Error getting TOC: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def find_time_profile_xpath(toc_xml: str) -> str:
    """Find the XPath to the time profile data in the TOC."""
    root = ET.fromstring(toc_xml)

    # Look for time-profile schema in any run
    for run in root.findall(".//run"):
        run_num = run.get("number", "1")
        for table in run.findall(".//table"):
            schema = table.get("schema", "")
            if "time-profile" in schema.lower():
                target_id = table.get("target-pid") or table.get("target")
                if target_id:
                    return f'/trace-toc/run[@number="{run_num}"]/data/table[@schema="{schema}"][@target-pid="{target_id}"]'
                return f'/trace-toc/run[@number="{run_num}"]/data/table[@schema="{schema}"]'

    return None


def export_samples(trace_path: str, xpath: str) -> str:
    """Export sample data using the given XPath."""
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", trace_path, "--xpath", xpath],
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        print(f"Error exporting: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def parse_weight(weight_str: str) -> float:
    """Parse weight string like '5.00 ms' to seconds."""
    if not weight_str:
        return 0.0

    match = re.match(r'([\d.]+)\s*(s|ms|µs|us|ns|min)?', weight_str)
    if not match:
        # Try parsing as raw nanoseconds
        try:
            return int(weight_str) / 1_000_000_000
        except:
            return 0.0

    num = float(match.group(1))
    unit = match.group(2) or 'ns'

    if unit == 'min':
        return num * 60
    elif unit == 's':
        return num
    elif unit == 'ms':
        return num / 1000
    elif unit in ('µs', 'us'):
        return num / 1_000_000
    elif unit == 'ns':
        return num / 1_000_000_000
    return num


def format_time(seconds: float) -> str:
    """Format seconds into human-readable string."""
    if seconds >= 60:
        return f"{seconds/60:.2f} min"
    elif seconds >= 1:
        return f"{seconds:.2f} s"
    elif seconds >= 0.001:
        return f"{seconds * 1000:.2f} ms"
    elif seconds >= 0.000001:
        return f"{seconds * 1_000_000:.2f} µs"
    else:
        return f"{seconds * 1_000_000_000:.2f} ns"


def aggregate_samples(xml_data: str, verbose: bool = False) -> CallTreeNode:
    """Parse samples and aggregate into a call tree."""
    root = ET.fromstring(xml_data)

    # Build caches for ID references (xctrace uses refs to avoid duplication)
    frame_names = {}
    weight_values = {}  # id -> weight in seconds

    # Root of our aggregated tree
    tree_root = CallTreeNode(name="root")

    # Find all rows (samples)
    rows = root.findall(".//row")
    if verbose:
        print(f"Found {len(rows)} samples", file=sys.stderr)

    for row in rows:
        # Get the weight for this sample
        weight_elem = row.find(".//weight")
        if weight_elem is None:
            continue

        # Handle weight refs - xctrace uses id/ref pattern to avoid duplication
        weight_id = weight_elem.get("id")
        weight_ref = weight_elem.get("ref")

        if weight_id:
            # This weight defines a new ID - get value from text content (nanoseconds)
            weight_text = weight_elem.text
            if weight_text:
                weight = int(weight_text) / 1_000_000_000  # Convert ns to seconds
            else:
                weight_str = weight_elem.get("fmt", "0")
                weight = parse_weight(weight_str)
            weight_values[weight_id] = weight
        elif weight_ref and weight_ref in weight_values:
            # This weight references a previously defined weight
            weight = weight_values[weight_ref]
        else:
            # Fallback to parsing fmt attribute
            weight_str = weight_elem.get("fmt", "0")
            weight = parse_weight(weight_str)

        # Get the backtrace
        backtrace = row.find(".//backtrace")
        if backtrace is None:
            continue

        # Extract frame names (in reverse order - leaf to root)
        frames = []
        for frame in backtrace.findall("frame"):
            frame_id = frame.get("id") or frame.get("ref")
            name = frame.get("name")

            if name:
                frame_names[frame_id] = name
            elif frame_id and frame_id in frame_names:
                name = frame_names[frame_id]
            else:
                name = f"frame_{frame_id}"

            frames.append(name)

        # Reverse to get root-to-leaf order
        frames = list(reversed(frames))

        if not frames:
            continue

        # Add this sample to the tree
        current = tree_root
        current.weight += weight

        for i, frame_name in enumerate(frames):
            if frame_name not in current.children:
                current.children[frame_name] = CallTreeNode(name=frame_name)

            child = current.children[frame_name]
            child.weight += weight

            # Last frame gets self weight
            if i == len(frames) - 1:
                child.self_weight += weight

            current = child

    return tree_root


def tree_to_text(node: CallTreeNode, depth: int = 0, lines: list = None) -> list:
    """Convert call tree to tab-separated text format."""
    if lines is None:
        lines = ["Weight\tSelf Weight\tSymbol Names"]

    if depth > 0:  # Skip the artificial root
        indent = " " * depth
        weight_str = format_time(node.weight)
        self_str = format_time(node.self_weight)
        lines.append(f"{weight_str}\t{self_str}\t{indent}{node.name}")

    # Sort children by weight descending
    sorted_children = sorted(
        node.children.values(),
        key=lambda n: n.weight,
        reverse=True
    )

    for child in sorted_children:
        tree_to_text(child, depth + 1, lines)

    return lines


def main():
    parser = argparse.ArgumentParser(
        description="Extract call tree from Instruments .trace file"
    )
    parser.add_argument("trace", help="Path to .trace file")
    parser.add_argument("--output", "-o", help="Output file (default: stdout)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")

    args = parser.parse_args()

    if not os.path.exists(args.trace):
        print(f"Error: {args.trace} not found", file=sys.stderr)
        sys.exit(1)

    # Get TOC to find the right XPath
    if args.verbose:
        print(f"Getting TOC from {args.trace}...", file=sys.stderr)

    toc = get_trace_toc(args.trace)

    if args.verbose:
        print(f"TOC:\n{toc[:1000]}...", file=sys.stderr)

    xpath = find_time_profile_xpath(toc)

    if not xpath:
        print("Could not find time profile data in trace.", file=sys.stderr)
        sys.exit(1)

    if args.verbose:
        print(f"Using XPath: {xpath}", file=sys.stderr)

    # Export the sample data
    xml_data = export_samples(args.trace, xpath)

    if args.verbose:
        print(f"Got {len(xml_data)} bytes of XML", file=sys.stderr)

    # Aggregate samples into call tree
    tree = aggregate_samples(xml_data, args.verbose)

    if args.verbose:
        print(f"Total weight: {format_time(tree.weight)}", file=sys.stderr)

    # Convert to text format
    lines = tree_to_text(tree)
    output = "\n".join(lines)

    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
        print(f"Written to {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
