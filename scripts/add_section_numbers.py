#!/usr/bin/env python3
"""Add hierarchical section numbers to markdown headings."""

import re
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor
from typing import List, Tuple, Optional

# Files to skip
SKIP_FILES = {'Overview.md', 'Glossary.md'}

def parse_heading(line: str) -> Optional[Tuple[int, str]]:
    """Parse a heading line and return (level, text) or None."""
    match = re.match(r'^(#{1,6})\s+(.+)$', line)
    if not match:
        return None
    hashes, text = match.groups()
    return len(hashes), text

def has_section_number(text: str) -> bool:
    """Check if heading already has a section number."""
    # Match patterns like "1.", "1.2.", "1.2.3.", etc at start
    return bool(re.match(r'^\d+(\.\d+)*\.\s+', text))

def add_section_numbers(content: str) -> Tuple[str, int]:
    """Add section numbers to all headings. Returns (new_content, num_modified)."""
    lines = content.split('\n')
    result = []

    # Track section numbers at each level
    counters = [0] * 6  # h1-h6
    modified_count = 0

    for line in lines:
        heading = parse_heading(line)

        if heading:
            level, text = heading

            # Skip if already numbered
            if has_section_number(text):
                result.append(line)
                continue

            # Increment counter at this level
            counters[level - 1] += 1

            # Reset all deeper level counters
            for i in range(level, 6):
                counters[i] = 0

            # Build section number (e.g., "1.2.3.")
            section_parts = [str(counters[i]) for i in range(level) if counters[i] > 0]
            section_number = '.'.join(section_parts) + '.'

            # Create new heading with section number
            hashes = '#' * level
            new_line = f"{hashes} {section_number} {text}"
            result.append(new_line)
            modified_count += 1
        else:
            result.append(line)

    return '\n'.join(result), modified_count

def process_file(file_path: Path) -> Tuple[str, int, int, str]:
    """Process a single file. Returns (filename, num_headings_modified, success, error_msg)."""
    try:
        # Skip special files
        if file_path.name in SKIP_FILES:
            return (str(file_path.relative_to(file_path.parents[1])), 0, 2, '')  # 2 = skipped

        # Read file - try different encodings
        content = None
        for encoding in ['utf-8', 'latin-1', 'cp1252']:
            try:
                content = file_path.read_text(encoding=encoding)
                break
            except UnicodeDecodeError:
                continue

        if content is None:
            raise ValueError("Could not decode file with any standard encoding")

        # Add section numbers
        new_content, modified_count = add_section_numbers(content)

        # Write back if modified
        if modified_count > 0:
            file_path.write_text(new_content, encoding='utf-8')

        return (str(file_path.relative_to(file_path.parents[1])), modified_count, 1, '')  # 1 = success
    except Exception as e:
        return (str(file_path), 0, 0, str(e))  # 0 = error

def main():
    """Process all markdown files in docs directory."""
    docs_dir = Path('/Users/derpa/Work/btr/dex/docs')

    # Find all markdown files
    md_files = list(docs_dir.rglob('*.md'))

    # Process files in parallel
    with ProcessPoolExecutor() as executor:
        results = list(executor.map(process_file, md_files))

    # Summarize results
    total_files = len(results)
    skipped = sum(1 for _, _, status, _ in results if status == 2)
    errors = sum(1 for _, _, status, _ in results if status == 0)
    processed = sum(1 for _, _, status, _ in results if status == 1)
    total_headings = sum(count for _, count, status, _ in results if status == 1)

    print(f"Processed {processed} files")
    print(f"Skipped {skipped} files (special files)")
    print(f"Errors: {errors} files")
    print(f"Total headings modified: {total_headings}")

    # Show errors
    error_files = [(name, err) for name, _, status, err in results if status == 0]
    if error_files:
        print("\nErrors:")
        for name, err in error_files:
            print(f"  {name}: {err}")

    # Show files with modifications
    modified_files = [(name, count) for name, count, status, _ in results if count > 0]
    if modified_files:
        print("\nModified files:")
        for name, count in sorted(modified_files):
            print(f"  {name}: {count} headings")

if __name__ == '__main__':
    main()
