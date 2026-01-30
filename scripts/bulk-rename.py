#!/usr/bin/env python3
"""
Bulk rename tool for refactoring codebases.

Performs find-and-replace across file contents and renames files matching patterns.
Longer patterns are matched first to handle overlapping replacements correctly.

Usage:
    # Preview changes (dry run)
    ./scripts/bulk-rename.py --dry-run OldName=NewName AnotherOld=AnotherNew

    # Apply changes
    ./scripts/bulk-rename.py --apply OldName=NewName AnotherOld=AnotherNew

    # Load replacements from a file (one per line: OldName=NewName)
    ./scripts/bulk-rename.py --dry-run --file replacements.txt

    # Specify custom extensions to process
    ./scripts/bulk-rename.py --dry-run --ext .swift .md .txt OldName=NewName

    # Specify project root (defaults to current directory)
    ./scripts/bulk-rename.py --dry-run --root /path/to/project OldName=NewName

Examples:
    # Rename a class and its file
    ./scripts/bulk-rename.py --apply MyOldClass=MyNewClass

    # Remove a prefix from multiple types
    ./scripts/bulk-rename.py --apply \\
        EventBasedPlugin=FuzzPlugin \\
        EventBasedDispatcher=Dispatcher

    # Case-sensitive replacements (handles comments too)
    ./scripts/bulk-rename.py --apply \\
        "event-based plugin=plugin" \\
        "Event-based plugins=Plugins"
"""

import os
import re
import sys
import argparse
from pathlib import Path
from typing import Dict, List, Tuple, Optional


# Default file extensions to process for content changes
DEFAULT_EXTENSIONS = {".swift", ".md", ".txt", ".json", ".yaml", ".yml", ".h", ".c", ".m"}

# Directories to skip
SKIP_DIRS = {".git", ".build", "DerivedData", ".swiftpm", "node_modules", "__pycache__", ".venv"}

# Files to skip
SKIP_FILES = {"bulk-rename.py", "rename-event-based.py"}


def parse_replacements(args: List[str], file_path: Optional[str] = None) -> Dict[str, str]:
    """Parse replacement pairs from command line args and/or file."""
    replacements = {}

    # Load from file if specified
    if file_path:
        path = Path(file_path)
        if not path.exists():
            print(f"Error: Replacement file not found: {file_path}", file=sys.stderr)
            sys.exit(1)
        for line in path.read_text().strip().split("\n"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                old, new = line.split("=", 1)
                replacements[old] = new

    # Parse command line args
    for arg in args:
        if "=" in arg:
            old, new = arg.split("=", 1)
            replacements[old] = new
        else:
            print(f"Warning: Skipping invalid replacement (no '='): {arg}", file=sys.stderr)

    return replacements


def find_files(root: Path, skip_dirs: set = SKIP_DIRS, skip_files: set = SKIP_FILES):
    """Find all files that might need renaming or content changes."""
    for path in root.rglob("*"):
        if path.is_file():
            # Skip certain directories
            if any(skip in path.parts for skip in skip_dirs):
                continue
            # Skip certain files
            if path.name in skip_files:
                continue
            yield path


def get_sorted_replacements(replacements: Dict[str, str]) -> List[Tuple[str, str]]:
    """Sort replacements by length descending to match longer patterns first."""
    return sorted(replacements.items(), key=lambda x: len(x[0]), reverse=True)


def get_file_renames(root: Path, replacements: Dict[str, str]) -> List[Tuple[Path, Path]]:
    """Get list of files that need to be renamed."""
    renames = []
    sorted_replacements = get_sorted_replacements(replacements)

    for path in find_files(root):
        old_name = path.name
        new_name = old_name
        for old, new in sorted_replacements:
            new_name = new_name.replace(old, new)
        if old_name != new_name:
            new_path = path.parent / new_name
            renames.append((path, new_path))

    return renames


def get_content_changes(
    root: Path,
    replacements: Dict[str, str],
    extensions: set
) -> List[Tuple[Path, str, str, List[Tuple[str, str, int]]]]:
    """Get list of files with content that needs to change."""
    changes = []
    sorted_replacements = get_sorted_replacements(replacements)

    for path in find_files(root):
        if path.suffix not in extensions:
            continue
        try:
            content = path.read_text()
        except (UnicodeDecodeError, PermissionError):
            continue

        new_content = content
        file_replacements = []

        for old, new in sorted_replacements:
            if old in new_content:
                count = new_content.count(old)
                new_content = new_content.replace(old, new)
                file_replacements.append((old, new, count))

        if file_replacements:
            changes.append((path, content, new_content, file_replacements))

    return changes


def preview_changes(
    root: Path,
    replacements: Dict[str, str],
    extensions: set
):
    """Show what changes would be made."""
    print("=" * 60)
    print("REPLACEMENTS")
    print("=" * 60)
    sorted_replacements = get_sorted_replacements(replacements)
    for old, new in sorted_replacements:
        print(f"  '{old}' -> '{new}'")

    print()
    print("=" * 60)
    print("FILE RENAMES")
    print("=" * 60)

    file_renames = get_file_renames(root, replacements)
    if file_renames:
        for old_path, new_path in file_renames:
            rel_old = old_path.relative_to(root)
            rel_new = new_path.relative_to(root)
            print(f"  {rel_old}")
            print(f"    -> {rel_new}")
            print()
    else:
        print("  (no file renames needed)")

    print()
    print("=" * 60)
    print("CONTENT CHANGES")
    print("=" * 60)

    content_changes = get_content_changes(root, replacements, extensions)
    if content_changes:
        for path, old_content, new_content, file_replacements in content_changes:
            rel_path = path.relative_to(root)
            print(f"\n  {rel_path}:")
            for old, new, count in file_replacements:
                print(f"    '{old}' -> '{new}' ({count} occurrences)")
    else:
        print("  (no content changes needed)")

    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Files to rename: {len(file_renames)}")
    print(f"  Files with content changes: {len(content_changes)}")
    total_replacements = sum(
        sum(r[2] for r in file_replacements)
        for _, _, _, file_replacements in content_changes
    )
    print(f"  Total text replacements: {total_replacements}")


def apply_changes(
    root: Path,
    replacements: Dict[str, str],
    extensions: set
):
    """Apply the changes."""
    # First, apply content changes (before renaming files)
    content_changes = get_content_changes(root, replacements, extensions)
    for path, old_content, new_content, file_replacements in content_changes:
        rel_path = path.relative_to(root)
        print(f"Updating content: {rel_path}")
        path.write_text(new_content)

    # Then rename files
    file_renames = get_file_renames(root, replacements)
    for old_path, new_path in file_renames:
        rel_old = old_path.relative_to(root)
        rel_new = new_path.relative_to(root)
        print(f"Renaming: {rel_old} -> {rel_new}")
        # Try git mv first, fall back to regular rename
        if (root / ".git").exists():
            result = os.system(f'cd "{root}" && git mv "{old_path}" "{new_path}" 2>/dev/null')
            if result != 0:
                # git mv failed (file not tracked), use regular rename
                old_path.rename(new_path)
        else:
            old_path.rename(new_path)

    print()
    print(f"Applied {len(content_changes)} content changes and {len(file_renames)} file renames.")


def main():
    parser = argparse.ArgumentParser(
        description="Bulk rename tool for refactoring codebases",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --dry-run OldClass=NewClass
  %(prog)s --apply "old_function=new_function" "OldType=NewType"
  %(prog)s --dry-run --file replacements.txt
  %(prog)s --apply --ext .swift .h .m OldPrefix=NewPrefix
        """
    )

    # Action (required, mutually exclusive)
    action_group = parser.add_mutually_exclusive_group(required=True)
    action_group.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes without applying"
    )
    action_group.add_argument(
        "--apply",
        action="store_true",
        help="Apply changes"
    )

    # Options
    parser.add_argument(
        "--root",
        type=str,
        default=".",
        help="Project root directory (default: current directory)"
    )
    parser.add_argument(
        "--file", "-f",
        type=str,
        help="Load replacements from file (one per line: Old=New)"
    )
    parser.add_argument(
        "--ext",
        nargs="+",
        help=f"File extensions to process (default: {' '.join(sorted(DEFAULT_EXTENSIONS))})"
    )

    # Positional arguments (replacements)
    parser.add_argument(
        "replacements",
        nargs="*",
        help="Replacement pairs in format Old=New"
    )

    args = parser.parse_args()

    # Parse replacements
    replacements = parse_replacements(args.replacements, args.file)

    if not replacements:
        print("Error: No replacements specified", file=sys.stderr)
        print("Provide replacements as arguments (Old=New) or via --file", file=sys.stderr)
        sys.exit(1)

    # Determine extensions
    if args.ext:
        extensions = set(ext if ext.startswith(".") else f".{ext}" for ext in args.ext)
    else:
        extensions = DEFAULT_EXTENSIONS

    # Resolve root
    root = Path(args.root).resolve()
    if not root.exists():
        print(f"Error: Root directory not found: {root}", file=sys.stderr)
        sys.exit(1)

    # Execute
    if args.dry_run:
        preview_changes(root, replacements, extensions)
    elif args.apply:
        apply_changes(root, replacements, extensions)


if __name__ == "__main__":
    main()
