#!/bin/bash

set -euo pipefail

if [ "$#" -lt 2 ]; then
	echo "Usage: $0 <system-md> <prompt>"
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SYSTEM_MD="$1"
shift
ROLE_NAME="$(basename "$SYSTEM_MD" .md)"
LOG_DIR="$PROJECT_ROOT/logs/ai"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/${TIMESTAMP}-${ROLE_NAME}.stream.jsonl"
IDLE_TIMEOUT_SECONDS="${GEMINI_IDLE_TIMEOUT_SECONDS:-300}"

export GEMINI_SYSTEM_MD="$PROJECT_ROOT/.gemini/$SYSTEM_MD"
mkdir -p "$LOG_DIR"

cd "$PROJECT_ROOT"
python3 "$SCRIPT_DIR/stream_gemini_with_idle_timeout.py" \
	"$IDLE_TIMEOUT_SECONDS" \
	"$LOG_FILE" \
	gemini \
	-y \
	--output-format "${GEMINI_OUTPUT_FORMAT:-stream-json}" \
	-p "$*"
