#!/usr/bin/env python3
"""
Apple App Store Metadata Validator

Validates App Store metadata against Apple's character limits.
Can be used interactively or with command-line arguments.
"""

import sys
import argparse
from typing import Dict, Tuple

# Apple App Store character limits
LIMITS = {
    'app_name': 30,
    'subtitle': 30,
    'promotional_text': 170,
    'description': 4000,
    'keywords': 100,
    'whats_new': 4000
}

FIELD_LABELS = {
    'app_name': 'App Name',
    'subtitle': 'Subtitle',
    'promotional_text': 'Promotional Text',
    'description': 'Description',
    'keywords': 'Keywords',
    'whats_new': "What's New"
}


def validate_field(text: str, limit: int) -> Tuple[bool, int, int]:
    """
    Validate a text field against its character limit.

    Returns:
        Tuple of (is_valid, char_count, remaining_chars)
    """
    char_count = len(text)
    remaining = limit - char_count
    is_valid = char_count <= limit
    return is_valid, char_count, remaining


def format_validation_result(field_name: str, text: str, limit: int) -> str:
    """Format a validation result with emoji indicators."""
    is_valid, count, remaining = validate_field(text, limit)
    status = "✅" if is_valid else "❌"

    result = f"{status} {FIELD_LABELS[field_name]}: {count}/{limit} characters"

    if is_valid:
        result += f" ({remaining} remaining)"
    else:
        result += f" (EXCEEDS by {abs(remaining)})"

    return result


def validate_all(metadata: Dict[str, str]) -> Dict[str, Tuple[bool, int, int]]:
    """Validate all metadata fields."""
    results = {}
    for field, text in metadata.items():
        if field in LIMITS:
            results[field] = validate_field(text, LIMITS[field])
    return results


def print_validation_results(metadata: Dict[str, str]):
    """Print formatted validation results."""
    print("\n" + "="*60)
    print("📱 APPLE APP STORE METADATA VALIDATION")
    print("="*60 + "\n")

    all_valid = True

    for field, text in metadata.items():
        if field in LIMITS:
            print(format_validation_result(field, text, LIMITS[field]))
            is_valid, _, _ = validate_field(text, LIMITS[field])
            if not is_valid:
                all_valid = False

    print("\n" + "="*60)
    if all_valid:
        print("✅ All fields pass validation!")
    else:
        print("❌ Some fields exceed character limits - please revise")
    print("="*60 + "\n")


def interactive_mode():
    """Run in interactive mode, prompting for each field."""
    print("\n🍎 Apple App Store Metadata Validator")
    print("="*60)
    print("Enter metadata for validation. Press Ctrl+D (Unix) or Ctrl+Z (Windows) when done.\n")

    metadata = {}

    for field, label in FIELD_LABELS.items():
        print(f"\n{label} (max {LIMITS[field]} chars):")
        try:
            if field in ['description', 'whats_new']:
                print("(Multi-line input - press Ctrl+D/Ctrl+Z on a new line when done)")
                lines = []
                while True:
                    try:
                        line = input()
                        lines.append(line)
                    except EOFError:
                        break
                text = '\n'.join(lines)
            else:
                text = input("> ")

            metadata[field] = text

        except (EOFError, KeyboardInterrupt):
            print("\n\nValidation interrupted.")
            sys.exit(0)

    print_validation_results(metadata)


def main():
    parser = argparse.ArgumentParser(
        description='Validate Apple App Store metadata against character limits'
    )
    parser.add_argument('--app-name', help='App name (max 30 chars)')
    parser.add_argument('--subtitle', help='Subtitle (max 30 chars)')
    parser.add_argument('--promotional-text', help='Promotional text (max 170 chars)')
    parser.add_argument('--description', help='Description (max 4000 chars)')
    parser.add_argument('--keywords', help='Keywords (max 100 chars, comma-separated)')
    parser.add_argument('--whats-new', help="What's New text (max 4000 chars)")

    args = parser.parse_args()

    # Check if any arguments were provided
    has_args = any([
        args.app_name, args.subtitle, args.promotional_text,
        args.description, args.keywords, args.whats_new
    ])

    if not has_args:
        # No arguments provided, run in interactive mode
        interactive_mode()
    else:
        # Validate provided arguments
        metadata = {}
        if args.app_name:
            metadata['app_name'] = args.app_name
        if args.subtitle:
            metadata['subtitle'] = args.subtitle
        if args.promotional_text:
            metadata['promotional_text'] = args.promotional_text
        if args.description:
            metadata['description'] = args.description
        if args.keywords:
            metadata['keywords'] = args.keywords
        if args.whats_new:
            metadata['whats_new'] = args.whats_new

        print_validation_results(metadata)


if __name__ == '__main__':
    main()
