#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCS_DIR="$PROJECT_ROOT/docs/current"
BUG_FILE="$DOCS_DIR/bug-report.md"
TEST_RESULTS_FILE="$DOCS_DIR/test-results.md"
BUGFIX_FILE="$DOCS_DIR/bugfix-status.md"
IMPLEMENTATION_FILE="$DOCS_DIR/implementation-status.md"

mkdir -p "$DOCS_DIR"

if [ ! -f "$BUG_FILE" ]; then
	echo "Missing bug report file: $BUG_FILE"
	exit 1
fi

if ! grep -q 'READY_FOR_BUGFIX' "$BUG_FILE"; then
	echo "Bug report file is not marked READY_FOR_BUGFIX."
	exit 1
fi

require_file() {
	local file="$1"
	if [ ! -f "$file" ]; then
		echo "Required file missing: $file"
		exit 1
	fi
}

require_marker() {
	local file="$1"
	local marker="$2"
	if ! grep -Eq "$marker" "$file"; then
		echo "Required marker '$marker' missing in $file"
		exit 1
	fi
}

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-tests-writer.md" \
	"Read docs/current/bug-report.md plus any existing docs/current/requirements.md and docs/current/technical-design.md. Add or update automated tests that reproduce the bug batch. Write docs/current/test-results.md with the commands you actually ran and the blockers you found."

require_file "$TEST_RESULTS_FILE"
require_marker "$TEST_RESULTS_FILE" "READY_FOR_DEV|BLOCKED_FOR_DEV"

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-dev.md" \
	"Read docs/current/bug-report.md plus any existing docs/current/technical-design.md and docs/current/test-results.md. Fix the reported bugs, rerun the relevant verification commands, and write docs/current/bugfix-status.md plus docs/current/implementation-status.md. Do not leave background processes running."

require_file "$BUGFIX_FILE"
require_file "$IMPLEMENTATION_FILE"
require_marker "$IMPLEMENTATION_FILE" "READY_FOR_APP_TESTING|BLOCKED_FOR_APP_TESTING"

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-tests-writer.md" \
	"Read docs/current/bug-report.md, docs/current/test-results.md, docs/current/bugfix-status.md, docs/current/implementation-status.md, and the current repository state. Verify whether the bugfixes are properly covered by tests. If not, fix tests or assumptions, rerun relevant commands, and rewrite docs/current/test-results.md. End with READY_FOR_DEV or BLOCKED_FOR_DEV."

require_file "$TEST_RESULTS_FILE"
require_marker "$TEST_RESULTS_FILE" "READY_FOR_DEV|BLOCKED_FOR_DEV"

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-dev.md" \
	"Read docs/current/bug-report.md, docs/current/test-results.md, docs/current/bugfix-status.md, docs/current/implementation-status.md, and the current repository state. Verify whether the bugfix implementation is complete. If not, fix remaining issues, rerun relevant commands, and rewrite docs/current/bugfix-status.md plus docs/current/implementation-status.md. End with READY_FOR_APP_TESTING or BLOCKED_FOR_APP_TESTING."

require_file "$BUGFIX_FILE"
require_file "$IMPLEMENTATION_FILE"
require_marker "$IMPLEMENTATION_FILE" "READY_FOR_APP_TESTING|BLOCKED_FOR_APP_TESTING"
