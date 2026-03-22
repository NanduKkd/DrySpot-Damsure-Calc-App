#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="$PROJECT_ROOT/logs"
PID_DIR="$LOGS_DIR/.pids"

mkdir -p "$LOGS_DIR/flutter"
mkdir -p "$LOGS_DIR/backend"
mkdir -p "$PID_DIR"

FLUTTER_LOG="$LOGS_DIR/flutter/dev.log"
BACKEND_LOG="$LOGS_DIR/backend/dev.log"
FLUTTER_PID_FILE="$PID_DIR/flutter.pid"
BACKEND_PID_FILE="$PID_DIR/backend.pid"

show_usage() {
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  --detach    Run services in background (detached)"
	echo "  --stop      Stop detached services"
	echo "  (none)      Run services in foreground (blocks terminal)"
	echo ""
	echo "Environment:"
	echo "  FLUTTER_DEVICE=<id>  Optional device identifier passed to 'flutter run -d'"
	echo ""
	echo "Examples:"
	echo "  $0"
	echo "  FLUTTER_DEVICE=emulator-5554 $0 --detach"
	echo "  $0 --stop"
}

start_flutter() {
	cd "$PROJECT_ROOT/flutter"

	if [ -n "${FLUTTER_DEVICE:-}" ]; then
		flutter run -d "$FLUTTER_DEVICE" > "$FLUTTER_LOG" 2>&1 &
	else
		flutter run > "$FLUTTER_LOG" 2>&1 &
	fi

	FLUTTER_PID=$!
	echo "$FLUTTER_PID" > "$FLUTTER_PID_FILE"
	echo "Flutter app started (PID: $FLUTTER_PID)"
}

start_flutter_detached() {
	cd "$PROJECT_ROOT/flutter"

	if [ -n "${FLUTTER_DEVICE:-}" ]; then
		nohup flutter run -d "$FLUTTER_DEVICE" > "$FLUTTER_LOG" 2>&1 &
	else
		nohup flutter run > "$FLUTTER_LOG" 2>&1 &
	fi

	FLUTTER_PID=$!
	echo "$FLUTTER_PID" > "$FLUTTER_PID_FILE"
	echo "Flutter app started (PID: $FLUTTER_PID)"
}

start_backend() {
	cd "$PROJECT_ROOT/backend"
	npm run dev > "$BACKEND_LOG" 2>&1 &
	BACKEND_PID=$!
	echo "$BACKEND_PID" > "$BACKEND_PID_FILE"
	echo "Backend server started (PID: $BACKEND_PID)"
}

start_backend_detached() {
	cd "$PROJECT_ROOT/backend"
	nohup npm run dev > "$BACKEND_LOG" 2>&1 &
	BACKEND_PID=$!
	echo "$BACKEND_PID" > "$BACKEND_PID_FILE"
	echo "Backend server started (PID: $BACKEND_PID)"
}

start_services() {
	echo "Starting development services..."
	echo "Logs will be written to:"
	echo "  Flutter: $FLUTTER_LOG"
	echo "  Backend: $BACKEND_LOG"
	if [ -n "${FLUTTER_DEVICE:-}" ]; then
		echo "Using Flutter device: $FLUTTER_DEVICE"
	else
		echo "Using Flutter default device selection."
	fi
	echo ""

	start_flutter
	start_backend

	echo ""
	echo "Services running. Use './scripts/view-logs.sh' to view logs."
	echo "Press Ctrl+C to stop both services."
}

start_services_detached() {
	echo "Starting development services in background..."
	echo "Logs will be written to:"
	echo "  Flutter: $FLUTTER_LOG"
	echo "  Backend: $BACKEND_LOG"
	if [ -n "${FLUTTER_DEVICE:-}" ]; then
		echo "Using Flutter device: $FLUTTER_DEVICE"
	else
		echo "Using Flutter default device selection."
	fi
	echo ""

	start_flutter_detached
	start_backend_detached

	sleep 2

	echo ""
	echo "Services running in background."
	echo "Use 'npm run logs:flutter' or 'npm run logs:backend' to view logs."
	echo "Use 'npm run dev:stop' to stop them."
}

stop_service() {
	local name="$1"
	local pid_file="$2"

	if [ -f "$pid_file" ]; then
		local pid
		pid="$(cat "$pid_file")"
		if kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			echo "$name stopped (was PID: $pid)"
		else
			echo "$name not running (stale PID: $pid)"
		fi
		rm -f "$pid_file"
	fi
}

stop_services() {
	echo "Stopping development services..."
	stop_service "Flutter app" "$FLUTTER_PID_FILE"
	stop_service "Backend server" "$BACKEND_PID_FILE"
	echo "Done."
}

cleanup() {
	echo ""
	echo "Shutting down services..."
	kill "${FLUTTER_PID:-}" "${BACKEND_PID:-}" 2>/dev/null || true
	rm -f "$FLUTTER_PID_FILE" "$BACKEND_PID_FILE"
	exit 0
}

case "${1:-}" in
	--detach)
		start_services_detached
		;;
	--stop)
		stop_services
		;;
	-h|--help)
		show_usage
		exit 0
		;;
	"")
		trap cleanup SIGINT SIGTERM
		start_services
		wait
		;;
	*)
		echo "Unknown option: $1"
		show_usage
		exit 1
		;;
esac
