#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="$PROJECT_ROOT/logs"

show_usage() {
	echo "Usage: $0 [flutter|backend|all] [-f]"
	echo ""
	echo "Options:"
	echo "  flutter Show Flutter app logs"
	echo "  backend Show backend logs"
	echo "  all     Show all logs (default)"
	echo "  -f      Follow logs in real-time (tail -f)"
	echo ""
	echo "Examples:"
	echo "  $0"
	echo "  $0 flutter"
	echo "  $0 backend -f"
}

TARGET="all"
FOLLOW=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		flutter|backend|all)
			TARGET="$1"
			shift
			;;
		-f)
			FOLLOW="-f"
			shift
			;;
		-h|--help)
			show_usage
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			show_usage
			exit 1
			;;
	esac
done

FLUTTER_LOG="$LOGS_DIR/flutter/dev.log"
BACKEND_LOG="$LOGS_DIR/backend/dev.log"

if [ ! -d "$LOGS_DIR" ]; then
	echo "No logs directory found. Run 'run-dev.sh' first."
	exit 1
fi

case "$TARGET" in
	flutter)
		if [ -f "$FLUTTER_LOG" ]; then
			tail $FOLLOW "$FLUTTER_LOG"
		else
			echo "Flutter log not found: $FLUTTER_LOG"
			exit 1
		fi
		;;
	backend)
		if [ -f "$BACKEND_LOG" ]; then
			tail $FOLLOW "$BACKEND_LOG"
		else
			echo "Backend log not found: $BACKEND_LOG"
			exit 1
		fi
		;;
	all)
		if [ -f "$FLUTTER_LOG" ] && [ -f "$BACKEND_LOG" ]; then
			echo "=== FLUTTER APP LOGS ==="
			tail $FOLLOW "$FLUTTER_LOG" &
			FLUTTER_TAIL_PID=$!
			echo "=== BACKEND LOGS ==="
			tail $FOLLOW "$BACKEND_LOG" &
			BACKEND_TAIL_PID=$!

			trap "kill $FLUTTER_TAIL_PID $BACKEND_TAIL_PID 2>/dev/null" EXIT
			wait
		else
			echo "Logs not found. Run 'run-dev.sh' first."
			exit 1
		fi
		;;
esac
