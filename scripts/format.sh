#!/bin/bash
set -e

# Format all Swift source files using swift-format
# Config lives in .swift-format at project root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v swift-format &> /dev/null; then
    echo "swift-format not found"
    echo "  Install with: brew install swift-format"
    exit 1
fi

cd "$PROJECT_DIR"

files=$(find Sources -name "*.swift" -not -name "*.h" -type f)
file_count=$(echo "$files" | wc -l | tr -d ' ')

echo "Formatting $file_count Swift files..."

for file in $files; do
    echo "  $file"
    swift-format format -i "$file"
done

echo "Done."
