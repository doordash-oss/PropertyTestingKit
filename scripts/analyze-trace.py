#!/usr/bin/env python3
"""
Analyze Instruments trace files for Swift Concurrency data.

Usage:
    ./scripts/analyze-trace.py <trace-file>
    ./scripts/analyze-trace.py <trace-file> --table swift-task-lifetime
    ./scripts/analyze-trace.py <trace-file> --toc
    ./scripts/analyze-trace.py <trace-file> --all
"""

import subprocess
import sys
import xml.etree.ElementTree as ET
import argparse
from collections import defaultdict
from pathlib import Path


def run_xctrace(trace_path: str, xpath: str = None, toc: bool = False) -> str:
    """Run xctrace export and return the XML output."""
    cmd = ["xctrace", "export", "--input", trace_path]
    if toc:
        cmd.append("--toc")
    elif xpath:
        cmd.extend(["--xpath", xpath])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running xctrace: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def get_table_of_contents(trace_path: str) -> dict:
    """Get available tables from the trace."""
    xml_output = run_xctrace(trace_path, toc=True)
    root = ET.fromstring(xml_output)

    tables = {}
    for table in root.findall(".//table"):
        schema = table.get("schema")
        if schema:
            tables[schema] = dict(table.attrib)
    return tables


def export_table(trace_path: str, schema: str) -> ET.Element:
    """Export a specific table from the trace."""
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    xml_output = run_xctrace(trace_path, xpath=xpath)
    return ET.fromstring(xml_output)


def parse_duration(duration_str: str) -> float:
    """Parse duration string to seconds."""
    if not duration_str:
        return 0.0

    # Handle formats like "14.98 s", "123.45 ms", "1.23 µs"
    parts = duration_str.strip().split()
    if len(parts) != 2:
        # Try parsing as raw nanoseconds
        try:
            return float(duration_str) / 1_000_000_000
        except ValueError:
            return 0.0

    value, unit = parts
    value = float(value)

    if unit == "s":
        return value
    elif unit == "ms":
        return value / 1000
    elif unit == "µs" or unit == "us":
        return value / 1_000_000
    elif unit == "ns":
        return value / 1_000_000_000
    return value


def analyze_task_lifetime(root: ET.Element) -> None:
    """Analyze swift-task-lifetime table."""
    print("\n" + "=" * 70)
    print("SWIFT TASK LIFETIME ANALYSIS")
    print("=" * 70)

    tasks = []
    for row in root.findall(".//row"):
        duration_elem = row.find("duration")
        task_elem = row.find("swift-task")

        if duration_elem is not None and task_elem is not None:
            duration_fmt = duration_elem.get("fmt", "")
            task_name = task_elem.get("fmt", "unknown")
            duration_sec = parse_duration(duration_fmt)
            tasks.append((task_name, duration_sec, duration_fmt))

    # Sort by duration descending
    tasks.sort(key=lambda x: x[1], reverse=True)

    print(f"\nTotal tasks: {len(tasks)}")
    print(f"\nTop 20 longest-running tasks:")
    print("-" * 70)

    for i, (name, dur_sec, dur_fmt) in enumerate(tasks[:20], 1):
        # Truncate long names
        display_name = name[:50] + "..." if len(name) > 50 else name
        print(f"{i:3}. {dur_fmt:>12}  {display_name}")

    # Group by function name
    print(f"\n\nTasks grouped by function:")
    print("-" * 70)

    by_function = defaultdict(list)
    for name, dur_sec, dur_fmt in tasks:
        # Extract function name (before the task ID in parentheses)
        func_name = name.split(" (")[0] if " (" in name else name
        by_function[func_name].append(dur_sec)

    # Sort by total time
    func_stats = []
    for func, durations in by_function.items():
        total = sum(durations)
        count = len(durations)
        avg = total / count if count > 0 else 0
        func_stats.append((func, total, count, avg))

    func_stats.sort(key=lambda x: x[1], reverse=True)

    print(f"{'Function':<40} {'Total':>10} {'Count':>6} {'Avg':>10}")
    print("-" * 70)
    for func, total, count, avg in func_stats[:15]:
        display_func = func[:38] + ".." if len(func) > 40 else func
        print(f"{display_func:<40} {total:>9.3f}s {count:>6} {avg:>9.3f}s")


def analyze_task_state(root: ET.Element) -> None:
    """Analyze swift-task-state table."""
    print("\n" + "=" * 70)
    print("SWIFT TASK STATE ANALYSIS")
    print("=" * 70)

    states = defaultdict(lambda: {"count": 0, "total_duration": 0.0})

    for row in root.findall(".//row"):
        state_elem = row.find("swift-task-state")
        duration_elem = row.find("duration")

        if state_elem is not None:
            state = state_elem.get("fmt", "unknown")
            duration = parse_duration(duration_elem.get("fmt", "0") if duration_elem is not None else "0")
            states[state]["count"] += 1
            states[state]["total_duration"] += duration

    print(f"\n{'State':<20} {'Count':>8} {'Total Time':>12}")
    print("-" * 45)

    for state, data in sorted(states.items(), key=lambda x: x[1]["total_duration"], reverse=True):
        print(f"{state:<20} {data['count']:>8} {data['total_duration']:>11.3f}s")


def analyze_actor_execution(root: ET.Element) -> None:
    """Analyze swift-actor-execution table."""
    print("\n" + "=" * 70)
    print("SWIFT ACTOR EXECUTION ANALYSIS")
    print("=" * 70)

    actors = defaultdict(lambda: {"count": 0, "total_duration": 0.0})

    for row in root.findall(".//row"):
        actor_elem = row.find("swift-actor")
        duration_elem = row.find("duration")

        if actor_elem is not None:
            actor_name = actor_elem.get("fmt", "unknown")
            duration = parse_duration(duration_elem.get("fmt", "0") if duration_elem is not None else "0")
            actors[actor_name]["count"] += 1
            actors[actor_name]["total_duration"] += duration

    print(f"\nTotal actor execution periods: {sum(a['count'] for a in actors.values())}")
    print(f"\n{'Actor':<45} {'Count':>6} {'Total':>10}")
    print("-" * 65)

    for actor, data in sorted(actors.items(), key=lambda x: x[1]["total_duration"], reverse=True)[:15]:
        display_name = actor[:43] + ".." if len(actor) > 45 else actor
        print(f"{display_name:<45} {data['count']:>6} {data['total_duration']:>9.3f}s")


def analyze_task_creation(root: ET.Element) -> None:
    """Analyze swift-task-creation-event table."""
    print("\n" + "=" * 70)
    print("SWIFT TASK CREATION ANALYSIS")
    print("=" * 70)

    creators = defaultdict(int)
    total = 0

    for row in root.findall(".//row"):
        total += 1
        # Look for the creating task or backtrace
        backtrace = row.find(".//text-backtrace")
        if backtrace is not None:
            frames = backtrace.findall("frame")
            if frames:
                # Get the first non-runtime frame
                for frame in frames:
                    name = frame.get("name", "")
                    if name and "swift::" not in name and "libswift" not in name:
                        creators[name] += 1
                        break

    print(f"\nTotal task creations: {total}")
    print(f"\n{'Creator Function':<55} {'Count':>6}")
    print("-" * 65)

    for creator, count in sorted(creators.items(), key=lambda x: x[1], reverse=True)[:15]:
        display_name = creator[:53] + ".." if len(creator) > 55 else creator
        print(f"{display_name:<55} {count:>6}")


def analyze_running_task_count(root: ET.Element) -> None:
    """Analyze swift-running-task-count for concurrency patterns."""
    print("\n" + "=" * 70)
    print("SWIFT RUNNING TASK COUNT ANALYSIS")
    print("=" * 70)

    counts = []
    for row in root.findall(".//row"):
        count_elem = row.find("running-task-count")
        if count_elem is not None:
            try:
                count = int(count_elem.text or count_elem.get("fmt", "0"))
                counts.append(count)
            except ValueError:
                pass

    if counts:
        print(f"\nSamples: {len(counts)}")
        print(f"Max concurrent tasks: {max(counts)}")
        print(f"Min concurrent tasks: {min(counts)}")
        print(f"Avg concurrent tasks: {sum(counts) / len(counts):.2f}")

        # Distribution
        dist = defaultdict(int)
        for c in counts:
            dist[c] += 1

        print(f"\nDistribution of concurrent task counts:")
        print("-" * 30)
        for count in sorted(dist.keys()):
            pct = dist[count] / len(counts) * 100
            bar = "#" * int(pct / 2)
            print(f"{count:>3} tasks: {dist[count]:>5} ({pct:>5.1f}%) {bar}")


def analyze_thread_state(root: ET.Element, process_filter: str = None) -> None:
    """Analyze thread-state table from System Trace."""
    print("\n" + "=" * 70)
    print("THREAD STATE ANALYSIS")
    print("=" * 70)

    # Build reference lookup for elements with id attributes
    # The XML uses ref="id" to reference previously defined elements
    id_lookup = {}
    for elem in root.iter():
        elem_id = elem.get("id")
        if elem_id:
            id_lookup[elem_id] = elem

    def get_fmt(elem):
        """Get fmt attribute, following ref if needed."""
        if elem is None:
            return None
        if elem.get("fmt"):
            return elem.get("fmt")
        ref = elem.get("ref")
        if ref and ref in id_lookup:
            return id_lookup[ref].get("fmt")
        return None

    def get_process_from_thread(thread_elem):
        """Extract process name from nested thread element or its reference."""
        if thread_elem is None:
            return None
        # First check direct child
        process = thread_elem.find("process")
        if process is not None and process.get("fmt"):
            return process.get("fmt")
        # Check tid child which may have process
        tid = thread_elem.find("tid")
        if tid is not None:
            process = tid.find("process")
            if process is not None and process.get("fmt"):
                return process.get("fmt")
        # If thread has ref, look up the referenced thread
        ref = thread_elem.get("ref")
        if ref and ref in id_lookup:
            ref_thread = id_lookup[ref]
            process = ref_thread.find("process")
            if process is not None and process.get("fmt"):
                return process.get("fmt")
        return None

    # Collect thread state data
    thread_states = defaultdict(lambda: defaultdict(float))  # thread -> state -> duration
    state_totals = defaultdict(float)  # state -> total duration
    thread_process = {}  # thread -> process name

    for row in root.findall(".//row"):
        thread_elem = row.find("thread")
        state_elem = row.find("thread-state")
        duration_elem = row.find("duration")

        state = get_fmt(state_elem)
        if state is None:
            continue

        thread_name = get_fmt(thread_elem)

        # Get process - either from thread element or standalone process element
        process_name = get_process_from_thread(thread_elem)
        if process_name is None:
            process_elem = row.find("process")
            process_name = get_fmt(process_elem)

        # Filter by process if specified
        if process_filter:
            if process_name is None or process_filter.lower() not in process_name.lower():
                continue

        if thread_name is None:
            continue

        # Parse duration - can be in fmt attribute or raw nanoseconds in text
        duration = 0.0
        if duration_elem is not None:
            fmt = get_fmt(duration_elem)
            if fmt:
                duration = parse_duration(fmt)
            elif duration_elem.text:
                # Raw nanoseconds
                try:
                    duration = int(duration_elem.text) / 1_000_000_000
                except ValueError:
                    pass

        thread_states[thread_name][state] += duration
        state_totals[state] += duration
        if process_name:
            thread_process[thread_name] = process_name

    if not thread_states:
        print("\nNo thread state data found.")
        return

    # Overall state distribution
    total_time = sum(state_totals.values())
    print(f"\nOverall State Distribution (total: {total_time:.3f}s):")
    print("-" * 50)
    print(f"{'State':<25} {'Time':>10} {'%':>8}")
    print("-" * 50)

    for state in sorted(state_totals.keys(), key=lambda s: state_totals[s], reverse=True):
        dur = state_totals[state]
        pct = (dur / total_time * 100) if total_time > 0 else 0
        bar = "#" * int(pct / 2)
        print(f"{state:<25} {dur:>9.3f}s {pct:>7.1f}% {bar}")

    # Per-thread breakdown - focus on threads with significant blocked time
    print(f"\n\nPer-Thread Breakdown (threads with >100ms blocked/waiting):")
    print("-" * 70)

    blocked_threads = []
    for thread_id, states in thread_states.items():
        blocked_time = states.get("Blocked", 0) + states.get("Waiting", 0) + states.get("Preempted", 0)
        running_time = states.get("Running", 0)
        total = sum(states.values())
        if blocked_time > 0.1:  # More than 100ms blocked
            blocked_threads.append((thread_id, blocked_time, running_time, total, states))

    blocked_threads.sort(key=lambda x: x[1], reverse=True)

    for thread_id, blocked, running, total, states in blocked_threads[:20]:
        # Truncate thread name
        display_name = thread_id[:45] + "..." if len(thread_id) > 45 else thread_id
        blocked_pct = (blocked / total * 100) if total > 0 else 0
        running_pct = (running / total * 100) if total > 0 else 0
        print(f"\n{display_name}")
        print(f"  Running: {running:.3f}s ({running_pct:.1f}%)  Blocked: {blocked:.3f}s ({blocked_pct:.1f}%)")
        # Show state breakdown
        for state, dur in sorted(states.items(), key=lambda x: x[1], reverse=True):
            if dur > 0.01:  # Only show states with >10ms
                print(f"    {state}: {dur:.3f}s")


def print_toc(trace_path: str) -> None:
    """Print table of contents."""
    tables = get_table_of_contents(trace_path)

    print("\n" + "=" * 70)
    print("AVAILABLE TABLES")
    print("=" * 70)

    swift_tables = []
    other_tables = []

    for schema, attrs in sorted(tables.items()):
        if "swift" in schema.lower():
            swift_tables.append((schema, attrs))
        else:
            other_tables.append((schema, attrs))

    print("\nSwift Concurrency Tables:")
    print("-" * 40)
    for schema, attrs in swift_tables:
        print(f"  {schema}")

    print("\nOther Tables:")
    print("-" * 40)
    for schema, attrs in other_tables:
        extra = ""
        if "category" in attrs:
            extra = f" (category={attrs['category']})"
        print(f"  {schema}{extra}")


def main():
    parser = argparse.ArgumentParser(description="Analyze Instruments trace files")
    parser.add_argument("trace", help="Path to .trace file")
    parser.add_argument("--toc", action="store_true", help="Show table of contents")
    parser.add_argument("--table", help="Export specific table by schema name")
    parser.add_argument("--all", action="store_true", help="Run all analyses")
    parser.add_argument("--tasks", action="store_true", help="Analyze task lifetimes")
    parser.add_argument("--states", action="store_true", help="Analyze task states")
    parser.add_argument("--actors", action="store_true", help="Analyze actor execution")
    parser.add_argument("--creation", action="store_true", help="Analyze task creation")
    parser.add_argument("--concurrency", action="store_true", help="Analyze running task counts")
    parser.add_argument("--threads", action="store_true", help="Analyze thread states (System Trace)")
    parser.add_argument("--process", help="Filter thread analysis to specific process name")

    args = parser.parse_args()

    trace_path = args.trace
    if not Path(trace_path).exists():
        print(f"Error: Trace file not found: {trace_path}", file=sys.stderr)
        sys.exit(1)

    if args.toc:
        print_toc(trace_path)
        return

    if args.table:
        root = export_table(trace_path, args.table)
        # Pretty print the XML
        ET.dump(root)
        return

    # If --threads specified, run thread state analysis
    if args.threads:
        print(f"Analyzing: {trace_path}")
        try:
            root = export_table(trace_path, "thread-state")
            analyze_thread_state(root, args.process)
        except Exception as e:
            print(f"Could not analyze thread state: {e}")
        return

    # Default: run key analyses
    run_all = args.all or not any([args.tasks, args.states, args.actors, args.creation, args.concurrency])

    print(f"Analyzing: {trace_path}")

    if run_all or args.tasks:
        try:
            root = export_table(trace_path, "swift-task-lifetime")
            analyze_task_lifetime(root)
        except Exception as e:
            print(f"Could not analyze task lifetime: {e}")

    if run_all or args.states:
        try:
            root = export_table(trace_path, "swift-task-state")
            analyze_task_state(root)
        except Exception as e:
            print(f"Could not analyze task state: {e}")

    if run_all or args.actors:
        try:
            root = export_table(trace_path, "swift-actor-execution")
            analyze_actor_execution(root)
        except Exception as e:
            print(f"Could not analyze actor execution: {e}")

    if run_all or args.creation:
        try:
            root = export_table(trace_path, "swift-task-creation-event")
            analyze_task_creation(root)
        except Exception as e:
            print(f"Could not analyze task creation: {e}")

    if run_all or args.concurrency:
        try:
            root = export_table(trace_path, "swift-running-task-count")
            analyze_running_task_count(root)
        except Exception as e:
            print(f"Could not analyze running task count: {e}")


if __name__ == "__main__":
    main()
