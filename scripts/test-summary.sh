#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="$PROJECT_ROOT/logs"

mkdir -p "$LOGS_DIR/test"

show_usage() {
	echo "Usage: $0 [flutter|backend|all] [unit|integration]"
	echo ""
	echo "Options:"
	echo "  target: flutter | backend | all"
	echo "  type:   unit | integration | (default: all)"
	echo ""
	echo "Examples:"
	echo "  $0"
	echo "  $0 flutter"
	echo "  $0 backend integration"
	echo "  $0 flutter unit"
}

TARGET="${1:-all}"
TEST_TYPE="${2:-}"

cd "$PROJECT_ROOT"

echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Target: $TARGET"
if [ -n "$TEST_TYPE" ]; then
	echo "Type: $TEST_TYPE"
fi
echo "Time: $(date)"
echo "========================================"
echo ""

run_flutter_tests() {
	local type="$1"
	local exit_code=0

	echo ""
	echo "=== FLUTTER TESTS ==="
	echo ""

	cd "$PROJECT_ROOT/flutter"

	case "$type" in
		unit)
			flutter test 2>&1 | tee "$LOGS_DIR/test/flutter-unit.log" || exit_code=$?
			;;
		integration)
			if [ -d integration_test ]; then
				flutter test integration_test 2>&1 | tee "$LOGS_DIR/test/flutter-integration.log" || exit_code=$?
			else
				echo "No integration tests found." | tee "$LOGS_DIR/test/flutter-integration.log"
			fi
			;;
		*)
			flutter test 2>&1 | tee "$LOGS_DIR/test/flutter-unit.log" || exit_code=$?
			echo ""
			if [ -d integration_test ]; then
				flutter test integration_test 2>&1 | tee "$LOGS_DIR/test/flutter-integration.log" || exit_code=$?
			else
				echo "No integration tests found." | tee "$LOGS_DIR/test/flutter-integration.log"
			fi
			;;
	esac

	return ${exit_code}
}

run_backend_tests() {
	local type="$1"
	local exit_code=0

	echo ""
	echo "=== BACKEND TESTS ==="
	echo ""

	cd "$PROJECT_ROOT/backend"

	case "$type" in
		unit)
			npm run test:unit 2>&1 | tee "$LOGS_DIR/test/backend-unit.log" || exit_code=$?
			;;
		integration)
			npm run test:integration 2>&1 | tee "$LOGS_DIR/test/backend-integration.log" || exit_code=$?
			;;
		*)
			npm run test 2>&1 | tee "$LOGS_DIR/test/backend-all.log" || exit_code=$?
			;;
	esac

	return ${exit_code}
}

parse_flutter_results() {
	local log_file="$1"
	local test_name="$2"

	if [ ! -f "$log_file" ]; then
		echo "$test_name: NO LOG FILE"
		return
	fi

	if grep -q "No integration tests found." "$log_file"; then
		echo "⚠️  $test_name: No tests run"
		return
	fi

	if grep -q "All tests passed!" "$log_file"; then
		local total
		total="$(grep -oE '\+[0-9]+' "$log_file" | tail -1 | tr -d '+')"
		if [ -n "$total" ]; then
			echo "✅ $test_name: $total tests passed"
		else
			echo "✅ $test_name: Passed"
		fi
		return
	fi

	echo "❌ $test_name: Failed (see log)"
}

parse_backend_results() {
	local log_file="$1"
	local test_name="$2"

	if [ ! -f "$log_file" ]; then
		echo "$test_name: NO LOG FILE"
		return
	fi

	local passed
	local failed

	passed="$(grep -oE '[0-9]+ passed' "$log_file" | grep -oE '[0-9]+' | tail -1)"
	failed="$(grep -oE '[0-9]+ failed' "$log_file" | grep -oE '[0-9]+' | tail -1)"

	[ -z "$passed" ] && passed=0
	[ -z "$failed" ] && failed=0

	if [ "$failed" -gt 0 ]; then
		echo "❌ $test_name: $passed passed, $failed failed"
	elif [ "$passed" -gt 0 ]; then
		echo "✅ $test_name: $passed passed"
	else
		echo "⚠️  $test_name: No tests run"
	fi
}

show_summary() {
	echo ""
	echo "========================================"
	echo "TEST RESULTS SUMMARY"
	echo "========================================"
	echo ""

	parse_flutter_results "$LOGS_DIR/test/flutter-unit.log" "Flutter Unit"
	parse_flutter_results "$LOGS_DIR/test/flutter-integration.log" "Flutter Integration"

	if [ -f "$LOGS_DIR/test/backend-unit.log" ]; then
		parse_backend_results "$LOGS_DIR/test/backend-unit.log" "Backend Unit"
	elif [ -f "$LOGS_DIR/test/backend-all.log" ]; then
		parse_backend_results "$LOGS_DIR/test/backend-all.log" "Backend Unit"
	else
		echo "Backend Unit: NO LOG FILE"
	fi

	parse_backend_results "$LOGS_DIR/test/backend-integration.log" "Backend Integration"

	echo ""
	echo "Log files saved to: $LOGS_DIR/test/"
	echo ""
	echo "To view detailed logs:"
	echo "  cat $LOGS_DIR/test/flutter-unit.log"
	echo "  cat $LOGS_DIR/test/backend-integration.log"
}

case "$TARGET" in
	flutter)
		run_flutter_tests "$TEST_TYPE"
		;;
	backend)
		run_backend_tests "$TEST_TYPE"
		;;
	all)
		run_flutter_tests "$TEST_TYPE" || true
		run_backend_tests "$TEST_TYPE" || true
		;;
	*)
		show_usage
		exit 1
		;;
esac

show_summary
