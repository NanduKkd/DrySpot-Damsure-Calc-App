#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCS_DIR="$PROJECT_ROOT/docs/current"
REQUIREMENTS_FILE="$DOCS_DIR/requirements.md"
DESIGN_FILE="$DOCS_DIR/technical-design.md"
TEST_RESULTS_FILE="$DOCS_DIR/test-results.md"
IMPLEMENTATION_FILE="$DOCS_DIR/implementation-status.md"

mkdir -p "$DOCS_DIR"

if [ ! -f "$REQUIREMENTS_FILE" ]; then
	echo "Missing requirements file: $REQUIREMENTS_FILE"
	exit 1
fi

if ! grep -q 'READY_FOR_IMPLEMENTATION' "$REQUIREMENTS_FILE"; then
	echo "Requirements file is not marked READY_FOR_IMPLEMENTATION."
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
	"system-architect.md" \
	"Read docs/current/requirements.md. Write or update docs/current/technical-design.md using the deterministic file contracts from the system instructions. Do not ask the user questions."

require_file "$DESIGN_FILE"
require_marker "$DESIGN_FILE" "READY_FOR_TESTS_AND_DEV"

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-tests-writer.md" \
	"Read docs/current/requirements.md and docs/current/technical-design.md. Create or update tests and write docs/current/test-plan.md plus docs/current/test-results.md. Run the fastest relevant verification commands and record actual results."

require_file "$TEST_RESULTS_FILE"
require_marker "$TEST_RESULTS_FILE" "READY_FOR_DEV|BLOCKED_FOR_DEV"

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-dev.md" \
	"Read docs/current/requirements.md, docs/current/technical-design.md, docs/current/test-plan.md, and docs/current/test-results.md. Implement the feature, run the required verification commands, and write docs/current/implementation-status.md. Do not leave background processes running."

require_file "$IMPLEMENTATION_FILE"
require_marker "$IMPLEMENTATION_FILE" "READY_FOR_APP_TESTING|BLOCKED_FOR_APP_TESTING"

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-tests-writer.md" \
	"Read docs/current/requirements.md, docs/current/technical-design.md, docs/current/test-plan.md, docs/current/test-results.md, docs/current/implementation-status.md, and the current repository state. Verify whether everything has been tested properly. If not, fix the tests or test assumptions, rerun relevant commands, and rewrite docs/current/test-results.md. End with READY_FOR_DEV or BLOCKED_FOR_DEV."

require_file "$TEST_RESULTS_FILE"
require_marker "$TEST_RESULTS_FILE" "READY_FOR_DEV|BLOCKED_FOR_DEV"

"$SCRIPT_DIR/run-gemini-role.sh" \
	"system-dev.md" \
	"Read docs/current/requirements.md, docs/current/technical-design.md, docs/current/test-plan.md, docs/current/test-results.md, docs/current/implementation-status.md, and the current repository state. Verify whether implementation and verification are complete. If not, fix the repo, rerun relevant commands, and rewrite docs/current/implementation-status.md. End with READY_FOR_APP_TESTING or BLOCKED_FOR_APP_TESTING."

require_file "$IMPLEMENTATION_FILE"
require_marker "$IMPLEMENTATION_FILE" "READY_FOR_APP_TESTING|BLOCKED_FOR_APP_TESTING"
