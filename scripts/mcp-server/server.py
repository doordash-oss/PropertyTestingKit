#!/usr/bin/env python3
"""
MCP server for PropertyTestingKit development tools.

Provides tools for building, testing, and refactoring the PropertyTestingKit codebase.
"""

import asyncio
import json
import os
import re
import shutil
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

# Project root is two levels up from this script
PROJECT_ROOT = Path(__file__).parent.parent.parent.resolve()

server = Server("propertytestingkit")


@dataclass
class ScriptResult:
    """Result from running a script."""
    stdout: str
    stderr: str
    returncode: int
    timed_out: bool = False


def kill_process_tree(pid: int):
    """Kill a process and all its children using process group."""
    try:
        # Try to kill the entire process group
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        # Process already dead or we don't have permission
        pass


async def run_script_async(args: list[str], timeout: int = 300, stream_output: bool = False) -> ScriptResult:
    """Run a script asynchronously with proper cancellation support.

    When the async task is cancelled, the subprocess and all its children are killed.
    If stream_output is True, output is printed to stderr as it arrives.
    """
    # Start process in its own process group so we can kill all children
    process = await asyncio.create_subprocess_exec(
        *args,
        cwd=PROJECT_ROOT,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,  # Creates new process group
    )

    def cleanup():
        """Kill the process tree."""
        if process.returncode is None:
            kill_process_tree(process.pid)

    try:
        if stream_output:
            # Stream output to stderr as it arrives
            stdout_lines = []
            stderr_lines = []

            async def read_stream(stream, lines_list, prefix=""):
                while True:
                    try:
                        line = await asyncio.wait_for(stream.readline(), timeout=timeout)
                    except asyncio.TimeoutError:
                        return  # Stop reading this stream
                    if not line:
                        break
                    decoded = line.decode("utf-8", errors="replace")
                    lines_list.append(decoded)
                    # Print to stderr so user can see progress
                    print(f"{prefix}{decoded}", end="", file=sys.stderr, flush=True)

            try:
                await asyncio.gather(
                    read_stream(process.stdout, stdout_lines),
                    read_stream(process.stderr, stderr_lines, "[stderr] "),
                )
            except asyncio.TimeoutError:
                cleanup()
                await process.wait()
                return ScriptResult(
                    stdout="".join(stdout_lines),
                    stderr="".join(stderr_lines),
                    returncode=-1,
                    timed_out=True
                )

            await process.wait()
            return ScriptResult(
                stdout="".join(stdout_lines),
                stderr="".join(stderr_lines),
                returncode=process.returncode or 0,
            )
        else:
            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=timeout
            )
            return ScriptResult(
                stdout=stdout.decode("utf-8", errors="replace"),
                stderr=stderr.decode("utf-8", errors="replace"),
                returncode=process.returncode or 0,
            )
    except asyncio.TimeoutError:
        # Timeout - kill the process tree
        cleanup()
        await process.wait()
        return ScriptResult(stdout="", stderr="", returncode=-1, timed_out=True)
    except asyncio.CancelledError:
        # Task was cancelled (e.g., MCP tool aborted) - kill the process tree immediately
        print(f"[MCP] Cancellation received, killing process {process.pid}...", file=sys.stderr, flush=True)
        cleanup()
        try:
            await asyncio.wait_for(process.wait(), timeout=2.0)
        except asyncio.TimeoutError:
            pass  # Process should be dead after SIGKILL
        print(f"[MCP] Process {process.pid} killed.", file=sys.stderr, flush=True)
        raise  # Re-raise CancelledError


def parse_test_output(output: str) -> dict:
    """Parse test output to extract summary."""
    result = {
        "passed": True,
        "test_count": 0,
        "suite_count": 0,
        "failed_count": 0,
        "duration": 0.0,
        "known_issues": 0,
    }

    # Look for the summary line like:
    # "Test run with 265 tests in 47 suites passed after 2.023 seconds with 152 known issues."
    summary_match = re.search(
        r"Test run with (\d+) tests? in (\d+) suites? (passed|failed) after ([\d.]+) seconds?(?: with (\d+) known issues)?",
        output
    )
    if summary_match:
        result["test_count"] = int(summary_match.group(1))
        result["suite_count"] = int(summary_match.group(2))
        result["passed"] = summary_match.group(3) == "passed"
        result["duration"] = float(summary_match.group(4))
        if summary_match.group(5):
            result["known_issues"] = int(summary_match.group(5))

    # Count failures in output
    result["failed_count"] = len(re.findall(r"✘|failed|FAILED", output))

    return result


@server.list_tools()
async def list_tools() -> list[Tool]:
    """List available tools."""
    return [
        Tool(
            name="build",
            description="Build the project using the local Swift toolchain. Use target='release' for optimized builds.",
            inputSchema={
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Build target: 'debug' (default) or 'release'",
                        "enum": ["debug", "release"],
                        "default": "debug",
                    },
                },
            },
        ),
        Tool(
            name="test",
            description="Run tests using the local Swift toolchain. Returns structured results with pass/fail counts.",
            inputSchema={
                "type": "object",
                "properties": {
                    "filter": {
                        "type": "string",
                        "description": "Test filter pattern (e.g., 'PropertyTestingKitTests', 'testFuzzEngine')",
                        "default": "",
                    },
                    "timeout": {
                        "type": "integer",
                        "description": "Timeout in seconds",
                        "default": 180,
                    },
                },
            },
        ),
        Tool(
            name="test_until_failure",
            description="Run tests repeatedly until they fail, useful for finding flaky tests. Output is written to /tmp/test-failure-run{N}.log",
            inputSchema={
                "type": "object",
                "properties": {
                    "filter": {
                        "type": "string",
                        "description": "Test filter pattern (e.g., 'PropertyTestingKitTests')",
                    },
                    "max_runs": {
                        "type": "integer",
                        "description": "Maximum number of runs before giving up",
                        "default": 100,
                    },
                },
                "required": ["filter"],
            },
        ),
        Tool(
            name="bulk_rename",
            description="Rename symbols across the codebase. Handles file renames and content replacements. Always use dry_run=true first to preview changes.",
            inputSchema={
                "type": "object",
                "properties": {
                    "replacements": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "List of replacements in 'Old=New' format",
                    },
                    "dry_run": {
                        "type": "boolean",
                        "description": "If true, preview changes without applying",
                        "default": True,
                    },
                    "extensions": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "File extensions to process (e.g., ['.swift', '.md'])",
                    },
                },
                "required": ["replacements"],
            },
        ),
        Tool(
            name="run_benchmarks",
            description="Run performance benchmarks. Output includes timing data and can be analyzed with parse_call_tree.",
            inputSchema={
                "type": "object",
                "properties": {
                    "filter": {
                        "type": "string",
                        "description": "Benchmark filter (must match full benchmark name exactly)",
                        "default": "",
                    },
                },
            },
        ),
        Tool(
            name="parse_call_tree",
            description="Parse and analyze a call tree file from benchmarking. Summarizes hot paths and time distribution.",
            inputSchema={
                "type": "object",
                "properties": {
                    "file_path": {
                        "type": "string",
                        "description": "Path to call tree file (default: call_trees/tree.txt)",
                        "default": "call_trees/tree.txt",
                    },
                    "top": {
                        "type": "integer",
                        "description": "Number of top functions to show",
                        "default": 20,
                    },
                    "subtree": {
                        "type": "string",
                        "description": "Focus on subtree matching this pattern",
                    },
                    "no_subtree": {
                        "type": "boolean",
                        "description": "Disable default subtree filtering",
                        "default": False,
                    },
                    "search": {
                        "type": "string",
                        "description": "Search for functions matching this pattern",
                    },
                    "self_time": {
                        "type": "boolean",
                        "description": "Sort by self time instead of total time",
                        "default": False,
                    },
                    "children": {
                        "type": "integer",
                        "description": "Show direct children of entry at this line number",
                    },
                },
            },
        ),
        Tool(
            name="debug_tests",
            description="""Prepare for debugging tests with LLDB. Builds the project and returns paths and commands needed.

IMPORTANT: xctest bundles cannot be launched directly. Use the returned xctest_binary as the executable
and test_bundle as the run argument. Always use '-X false' when launching to avoid macOS security issues.""",
            inputSchema={
                "type": "object",
                "properties": {
                    "build": {
                        "type": "boolean",
                        "description": "Whether to build the project first (recommended)",
                        "default": True,
                    },
                },
            },
        ),
        Tool(
            name="profile",
            description="""Profile a benchmark with Instruments and extract the call tree automatically.

This tool:
1. Builds the benchmark (if requested)
2. Records with Instruments using the SimpleTime template
3. Extracts the call tree from the trace file
4. Analyzes the call tree and returns hot paths

Returns the profiling analysis without needing manual Instruments interaction.""",
            inputSchema={
                "type": "object",
                "properties": {
                    "benchmark": {
                        "type": "string",
                        "description": "Benchmark name to profile",
                        "default": "ProfiledBenchmark",
                    },
                    "time_limit": {
                        "type": "string",
                        "description": "Recording duration (e.g., '30s', '60s')",
                        "default": "30s",
                    },
                    "build": {
                        "type": "boolean",
                        "description": "Whether to build before profiling",
                        "default": True,
                    },
                    "subtree": {
                        "type": "string",
                        "description": "Focus on subtree matching this pattern (default: 'completeTaskWithClosure')",
                        "default": "completeTaskWithClosure",
                    },
                    "top": {
                        "type": "integer",
                        "description": "Number of top functions to show",
                        "default": 30,
                    },
                },
            },
        ),
        Tool(
            name="analyze_trace",
            description="""Analyze Instruments trace files for Swift Concurrency data.

Extracts and summarizes:
- Task lifetimes (how long each async task ran)
- Task states (running, waiting, suspended, etc.)
- Actor execution periods
- Task creation events
- Running task counts (concurrency level)

Use --toc to list available tables, or specific flags to analyze subsets.""",
            inputSchema={
                "type": "object",
                "properties": {
                    "trace_path": {
                        "type": "string",
                        "description": "Path to .trace file (Instruments trace directory)",
                    },
                    "toc": {
                        "type": "boolean",
                        "description": "Show table of contents (available data tables)",
                        "default": False,
                    },
                    "table": {
                        "type": "string",
                        "description": "Export specific table by schema name (e.g., 'swift-task-lifetime')",
                    },
                    "analysis": {
                        "type": "string",
                        "description": "Run specific analysis: 'all', 'tasks', 'states', 'actors', 'creation', 'concurrency'",
                        "enum": ["all", "tasks", "states", "actors", "creation", "concurrency"],
                        "default": "all",
                    },
                },
                "required": ["trace_path"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    """Execute a tool."""

    if name == "build":
        target = arguments.get("target", "debug")
        args = ["./scripts/build-local-toolchain.sh"]
        if target == "release":
            args.append("release")

        # Stream output so user can see build progress
        result = await run_script_async(args, timeout=300, stream_output=True)
        if result.timed_out:
            return [TextContent(type="text", text=json.dumps({"success": False, "error": "Build timed out"}))]

        output = result.stdout + result.stderr
        success = result.returncode == 0

        return [TextContent(
            type="text",
            text=json.dumps({
                "success": success,
                "return_code": result.returncode,
                "output": output[-5000:] if len(output) > 5000 else output,  # Truncate if too long
            }, indent=2)
        )]

    elif name == "test":
        filter_pattern = arguments.get("filter", "")
        timeout = arguments.get("timeout", 180)

        args = ["./scripts/build-local-toolchain.sh", "test"]
        if filter_pattern:
            args.extend(["--filter", filter_pattern])

        # Stream output so user can see test progress in real-time
        result = await run_script_async(args, timeout=timeout, stream_output=True)
        if result.timed_out:
            return [TextContent(type="text", text=json.dumps({"passed": False, "error": f"Tests timed out after {timeout}s"}))]

        output = result.stdout + result.stderr
        parsed = parse_test_output(output)
        parsed["return_code"] = result.returncode
        parsed["output_tail"] = output[-3000:] if len(output) > 3000 else output

        return [TextContent(type="text", text=json.dumps(parsed, indent=2))]

    elif name == "test_until_failure":
        filter_pattern = arguments["filter"]
        max_runs = arguments.get("max_runs", 100)

        args = ["./scripts/test-until-failure.sh", filter_pattern, str(max_runs)]

        result = await run_script_async(args, timeout=max_runs * 60)  # Rough estimate
        if result.timed_out:
            return [TextContent(type="text", text=json.dumps({"error": "Test run timed out"}))]

        output = result.stdout + result.stderr

        # Check if a failure was found
        failure_found = "FAILURE DETECTED" in output or result.returncode != 0

        return [TextContent(
            type="text",
            text=json.dumps({
                "failure_found": failure_found,
                "return_code": result.returncode,
                "output_tail": output[-2000:] if len(output) > 2000 else output,
                "log_location": "/tmp/test-failure-run*.log",
            }, indent=2)
        )]

    elif name == "bulk_rename":
        replacements = arguments["replacements"]
        dry_run = arguments.get("dry_run", True)
        extensions = arguments.get("extensions")

        args = ["python3", "./scripts/bulk-rename.py"]
        args.append("--dry-run" if dry_run else "--apply")

        if extensions:
            args.extend(["--ext"] + extensions)

        args.extend(replacements)

        result = await run_script_async(args, timeout=60)
        if result.timed_out:
            return [TextContent(type="text", text=json.dumps({"error": "Bulk rename timed out"}))]

        output = result.stdout + result.stderr

        # Parse summary from output
        summary = {"dry_run": dry_run, "output": output}

        files_match = re.search(r"Files to rename: (\d+)", output)
        content_match = re.search(r"Files with content changes: (\d+)", output)
        total_match = re.search(r"Total text replacements: (\d+)", output)

        if files_match:
            summary["files_to_rename"] = int(files_match.group(1))
        if content_match:
            summary["files_with_changes"] = int(content_match.group(1))
        if total_match:
            summary["total_replacements"] = int(total_match.group(1))

        return [TextContent(type="text", text=json.dumps(summary, indent=2))]

    elif name == "run_benchmarks":
        filter_pattern = arguments.get("filter", "")

        args = ["./scripts/run-benchmarks.sh"]
        if filter_pattern:
            args.extend(["--filter", filter_pattern])

        # Stream output so user can see benchmark progress
        result = await run_script_async(args, timeout=600, stream_output=True)
        if result.timed_out:
            return [TextContent(type="text", text=json.dumps({"error": "Benchmarks timed out"}))]

        output = result.stdout + result.stderr

        return [TextContent(
            type="text",
            text=json.dumps({
                "success": result.returncode == 0,
                "output": output[-5000:] if len(output) > 5000 else output,
                "call_tree_location": "~/Downloads/call_tree.txt",
            }, indent=2)
        )]

    elif name == "parse_call_tree":
        file_path = arguments.get("file_path", "call_trees/tree.txt")
        file_path = os.path.expanduser(file_path)
        top = arguments.get("top", 20)
        subtree = arguments.get("subtree")
        no_subtree = arguments.get("no_subtree", False)
        search = arguments.get("search")
        self_time = arguments.get("self_time", False)
        children = arguments.get("children")

        args = ["python3", "./scripts/parse-call-tree.py", file_path, "--top", str(top)]

        if subtree:
            args.extend(["--subtree", subtree])
        if no_subtree:
            args.append("--no-subtree")
        if search:
            args.extend(["--search", search])
        if self_time:
            args.append("--self-time")
        if children:
            args.extend(["--children", str(children)])

        result = await run_script_async(args, timeout=30)
        if result.timed_out:
            return [TextContent(type="text", text=json.dumps({"error": "Parse timed out"}))]

        output = result.stdout + result.stderr

        return [TextContent(
            type="text",
            text=json.dumps({
                "success": result.returncode == 0,
                "analysis": output,
            }, indent=2)
        )]

    elif name == "profile":
        benchmark = arguments.get("benchmark", "ProfiledBenchmark")
        time_limit = arguments.get("time_limit", "30s")
        should_build = arguments.get("build", True)
        subtree = arguments.get("subtree", "completeTaskWithClosure")
        top = arguments.get("top", 30)

        trace_path = PROJECT_ROOT / "traces" / f"{benchmark}.trace"
        calltree_path = PROJECT_ROOT / "call_trees" / f"{benchmark}.txt"

        # Step 1: Build if requested
        if should_build:
            print("[MCP Profile] Building benchmark...", file=sys.stderr, flush=True)
            build_result = await run_script_async(
                ["./scripts/build-local-toolchain.sh", "build", "--product", benchmark],
                timeout=300,
                stream_output=True
            )
            if build_result.returncode != 0:
                return [TextContent(
                    type="text",
                    text=json.dumps({
                        "success": False,
                        "stage": "build",
                        "error": "Build failed",
                        "output": build_result.stdout + build_result.stderr,
                    }, indent=2)
                )]

        # Step 2: Run profiling with Instruments
        print(f"[MCP Profile] Recording with Instruments for {time_limit}...", file=sys.stderr, flush=True)

        # Create directories
        (PROJECT_ROOT / "traces").mkdir(exist_ok=True)
        (PROJECT_ROOT / "call_trees").mkdir(exist_ok=True)

        # Remove old trace
        if trace_path.exists():
            shutil.rmtree(trace_path)

        executable = PROJECT_ROOT / ".build" / "debug" / benchmark

        # Check if executable exists
        if not executable.exists():
            return [TextContent(
                type="text",
                text=json.dumps({
                    "success": False,
                    "stage": "profile",
                    "error": f"Executable not found: {executable}",
                }, indent=2)
            )]

        # Run xctrace record
        # --quiet true is passed to the benchmark to prevent early exit when no TTY is available
        profile_result = await run_script_async(
            [
                "xcrun", "xctrace", "record",
                "--template", "SimpleTime",
                "--output", str(trace_path),
                "--time-limit", time_limit,
                "--launch", "--", str(executable), "--quiet", "true"
            ],
            timeout=int(time_limit.rstrip('s')) + 60,  # Extra time for setup
            stream_output=True
        )

        if profile_result.returncode != 0 and not trace_path.exists():
            return [TextContent(
                type="text",
                text=json.dumps({
                    "success": False,
                    "stage": "profile",
                    "error": "Profiling failed",
                    "output": profile_result.stdout + profile_result.stderr,
                }, indent=2)
            )]

        # Step 3: Extract call tree from trace
        print("[MCP Profile] Extracting call tree from trace...", file=sys.stderr, flush=True)
        extract_result = await run_script_async(
            ["python3", "./scripts/extract-calltree.py", str(trace_path), "-o", str(calltree_path)],
            timeout=120
        )

        if extract_result.returncode != 0:
            return [TextContent(
                type="text",
                text=json.dumps({
                    "success": False,
                    "stage": "extract",
                    "error": "Call tree extraction failed",
                    "output": extract_result.stdout + extract_result.stderr,
                    "trace_path": str(trace_path),
                }, indent=2)
            )]

        # Step 4: Analyze call tree
        print("[MCP Profile] Analyzing call tree...", file=sys.stderr, flush=True)
        analyze_args = ["python3", "./scripts/parse-call-tree.py", str(calltree_path), "--top", str(top)]
        if subtree:
            analyze_args.extend(["--subtree", subtree])

        analyze_result = await run_script_async(analyze_args, timeout=30)

        return [TextContent(
            type="text",
            text=json.dumps({
                "success": analyze_result.returncode == 0,
                "trace_path": str(trace_path),
                "calltree_path": str(calltree_path),
                "analysis": analyze_result.stdout + analyze_result.stderr,
            }, indent=2)
        )]

    elif name == "debug_tests":
        should_build = arguments.get("build", True)

        # Build first if requested
        if should_build:
            build_result = await run_script_async(["./scripts/build-local-toolchain.sh"], timeout=300)
            if build_result.returncode != 0:
                return [TextContent(
                    type="text",
                    text=json.dumps({
                        "success": False,
                        "error": "Build failed",
                        "output": build_result.stdout + build_result.stderr,
                    }, indent=2)
                )]

        # Find xctest binary
        xctest_result = subprocess.run(
            ["xcrun", "--find", "xctest"],
            capture_output=True,
            text=True,
        )
        xctest_binary = xctest_result.stdout.strip() if xctest_result.returncode == 0 else None

        # Test bundle path
        test_bundle = str(PROJECT_ROOT / ".build" / "arm64-apple-macosx" / "debug" / "PropertyTestingKitPackageTests.xctest")

        # Check if test bundle exists
        test_bundle_exists = Path(test_bundle).exists()

        # Build the LLDB commands
        lldb_commands = [
            f'file {xctest_binary}',
            f'settings set -- target.run-args "{test_bundle}"',
            'process launch -X false -s',
            '# Set breakpoints here, e.g.: breakpoint set --name FuzzEngine.run',
            'continue',
        ]

        return [TextContent(
            type="text",
            text=json.dumps({
                "success": test_bundle_exists and xctest_binary is not None,
                "xctest_binary": xctest_binary,
                "test_bundle": test_bundle,
                "test_bundle_exists": test_bundle_exists,
                "project_root": str(PROJECT_ROOT),
                "lldb_commands": lldb_commands,
                "usage": {
                    "with_lldb_mcp": [
                        "1. Call mcp__lldb-mcp__lldb_start to start a session",
                        f'2. Call mcp__lldb-mcp__lldb_load with program="{xctest_binary}"',
                        f'3. Call mcp__lldb-mcp__lldb_command with command=\'settings set -- target.run-args "{test_bundle}"\'',
                        "4. Call mcp__lldb-mcp__lldb_set_breakpoint with your breakpoint location",
                        "5. Call mcp__lldb-mcp__lldb_command with command='process launch -X false'",
                        "6. Use mcp__lldb-mcp__lldb_continue, lldb_step, lldb_print, etc. to debug",
                    ],
                    "manual": [
                        "1. Run: lldb",
                        *[f"{i}. {cmd}" for i, cmd in enumerate(lldb_commands, 2)],
                    ],
                },
            }, indent=2)
        )]

    elif name == "analyze_trace":
        trace_path = arguments["trace_path"]
        trace_path = os.path.expanduser(trace_path)
        show_toc = arguments.get("toc", False)
        table = arguments.get("table")
        analysis = arguments.get("analysis", "all")

        # Check if trace exists
        if not Path(trace_path).exists():
            return [TextContent(type="text", text=json.dumps({"error": f"Trace not found: {trace_path}"}))]

        args = ["python3", "./scripts/analyze-trace.py", trace_path]

        if show_toc:
            args.append("--toc")
        elif table:
            args.extend(["--table", table])
        elif analysis == "all":
            args.append("--all")
        elif analysis == "tasks":
            args.append("--tasks")
        elif analysis == "states":
            args.append("--states")
        elif analysis == "actors":
            args.append("--actors")
        elif analysis == "creation":
            args.append("--creation")
        elif analysis == "concurrency":
            args.append("--concurrency")

        result = await run_script_async(args, timeout=120)
        if result.timed_out:
            return [TextContent(type="text", text=json.dumps({"error": "Trace analysis timed out"}))]

        output = result.stdout + result.stderr

        return [TextContent(
            type="text",
            text=json.dumps({
                "success": result.returncode == 0,
                "trace_path": trace_path,
                "analysis": output,
            }, indent=2)
        )]

    else:
        return [TextContent(type="text", text=json.dumps({"error": f"Unknown tool: {name}"}))]


async def main():
    """Run the MCP server."""
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
