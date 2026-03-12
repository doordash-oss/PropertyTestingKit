#!/usr/bin/env python3
"""
Analyze macOS sample output to find spinning/hanging threads.

Usage:
    ./scripts/analyze-sample.py [sample-file]

If no file is provided, samples the first matching test process.
"""

import sys
import re
import subprocess
import tempfile
from collections import defaultdict

def sample_process():
    """Sample the running test process and return the output file path."""
    # Find the test process
    result = subprocess.run(
        ["pgrep", "-f", "PropertyTestingKitPackageTests"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("No test process found")
        sys.exit(1)

    pid = result.stdout.strip().split('\n')[0]
    print(f"Sampling process {pid}...")

    output_file = tempfile.mktemp(suffix='.txt')
    subprocess.run(
        ["sample", pid, "-f", output_file],
        capture_output=True
    )
    return output_file

def parse_sample(filepath):
    """Parse sample output into thread data."""
    with open(filepath, 'r') as f:
        content = f.read()

    # Split into threads
    thread_pattern = r'(\d+)\s+(Thread_\d+).*?\n((?:\s+\+.*\n)*)'
    threads = []

    for match in re.finditer(thread_pattern, content):
        samples = int(match.group(1))
        thread_id = match.group(2)
        stack = match.group(3)
        threads.append({
            'samples': samples,
            'thread_id': thread_id,
            'stack': stack,
            'stack_lines': [l.strip() for l in stack.split('\n') if l.strip()]
        })

    return threads

def analyze_thread(thread):
    """Analyze a thread's stack to determine what it's doing."""
    stack = thread['stack']
    stack_lower = stack.lower()

    info = {
        'is_spinning': False,
        'operation': None,
        'queue_type': None,
        'location': None,
        'key_frames': []
    }

    # Check for queue operations
    queue_types = ['KFifoQueue', 'RCQSQueue', 'SegmentQueue', 'RelaxedBoundedChannel',
                   'VyukovBoundedChannel', 'MultiQueue']
    for qt in queue_types:
        if qt in stack:
            info['queue_type'] = qt
            break

    # Check for send/recv
    if '.send(' in stack or 'send(_:)' in stack:
        info['operation'] = 'send'
    elif '.recv()' in stack or '.tryRecv()' in stack:
        info['operation'] = 'recv'

    # Check if it's in test code
    if 'messageAccountingConcurrent' in stack:
        info['in_test'] = True

    # Check for spinning indicators (high sample count + in atomic/load operations)
    spinning_indicators = ['load(ordering:', 'weakCompareExchange', 'ManagedAtomic']
    for indicator in spinning_indicators:
        if indicator in stack:
            info['is_spinning'] = True
            break

    # Extract key frames (filter out noise)
    interesting_patterns = ['Queue', 'Channel', 'send', 'recv', 'Test', 'closure']
    for line in thread['stack_lines']:
        for pattern in interesting_patterns:
            if pattern in line:
                # Clean up the line
                clean = re.sub(r'\[0x[0-9a-f]+\]', '', line)
                clean = re.sub(r'\+ \d+\s+', '', clean)
                info['key_frames'].append(clean.strip())
                break

    return info

def main():
    if len(sys.argv) > 1:
        filepath = sys.argv[1]
    else:
        filepath = sample_process()

    print(f"Analyzing {filepath}...\n")

    threads = parse_sample(filepath)

    # Sort by sample count (most active first)
    threads.sort(key=lambda t: t['samples'], reverse=True)

    print("=" * 80)
    print("THREAD ANALYSIS")
    print("=" * 80)

    interesting_threads = []

    for thread in threads:
        info = analyze_thread(thread)

        # Filter to interesting threads (queue operations or high sample count)
        if info['queue_type'] or info['operation'] or thread['samples'] > 100:
            interesting_threads.append((thread, info))

    if not interesting_threads:
        print("No interesting threads found. Showing top 5 by sample count:\n")
        for thread in threads[:5]:
            print(f"Thread: {thread['thread_id']} ({thread['samples']} samples)")
            for line in thread['stack_lines'][:10]:
                print(f"  {line}")
            print()
        return

    print(f"\nFound {len(interesting_threads)} interesting threads:\n")

    for thread, info in interesting_threads:
        print("-" * 60)
        print(f"Thread: {thread['thread_id']}")
        print(f"Samples: {thread['samples']} (higher = more time spent here)")

        if info['queue_type']:
            print(f"Queue Type: {info['queue_type']}")
        if info['operation']:
            print(f"Operation: {info['operation']}")
        if info['is_spinning']:
            print("⚠️  SPINNING (in atomic operations)")

        print("\nKey stack frames:")
        for frame in info['key_frames'][:15]:
            print(f"  {frame}")

        print()

    # Summary
    print("=" * 80)
    print("SUMMARY")
    print("=" * 80)

    spinning_ops = defaultdict(list)
    for thread, info in interesting_threads:
        if info['is_spinning'] and info['operation']:
            key = f"{info['queue_type'] or 'Unknown'}::{info['operation']}"
            spinning_ops[key].append(thread['samples'])

    if spinning_ops:
        print("\n⚠️  POTENTIAL DEADLOCK/LIVELOCK DETECTED:")
        for op, samples in spinning_ops.items():
            print(f"  - {op}: {sum(samples)} total samples across {len(samples)} thread(s)")

        print("\nThis suggests threads are spinning without making progress.")
        print("Check that send() and recv() are properly coordinating.")
    else:
        print("\nNo obvious spinning detected in queue operations.")

if __name__ == '__main__':
    main()
