#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_DIR="$ROOT_DIR/content/projects"
TEMPLATE="$ROOT_DIR/contributing/templates/project-template.md"

usage() {
    echo "Usage:"
    echo "  $0 <project-name>"
    echo "  $0 <project-name> <markdown-file>"
    exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
fi

PROJECT_NAME="$1"
PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"
DESTINATION="$PROJECT_DIR/index.md"

if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: project name can only contain letters, numbers, _ and -."
    exit 1
fi

if [[ -d "$PROJECT_DIR" ]]; then
    echo "Error: project already exists: $PROJECT_DIR"
    exit 1
fi

if [[ $# -eq 2 ]]; then
    SOURCE_FILE="$2"

    if [[ ! -f "$SOURCE_FILE" ]]; then
        echo "Error: source file not found: $SOURCE_FILE"
        exit 1
    fi
else
    SOURCE_FILE="$TEMPLATE"

    if [[ ! -f "$TEMPLATE" ]]; then
        echo "Error: template not found: $TEMPLATE"
        exit 1
    fi
fi

mkdir -p "$PROJECT_DIR"
cp "$SOURCE_FILE" "$DESTINATION"

echo "Project created successfully:"
echo "$PROJECT_DIR"
echo "Markdown file: $DESTINATION"