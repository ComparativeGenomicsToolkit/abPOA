#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
ERRORS=""

run_test() {
    local name="$1"
    local script="$2"
    printf "  %-45s " "$name"
    if bash "$script" >/dev/null 2>&1; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n  - $name"
    fi
}

echo "=== abPOA test suite ==="
echo ""

# Regression tests (always run if binary exists)
if [ -f bin/abpoa ]; then
    echo "Regression tests:"
    printf "  %-45s " "consensus output matches reference"
    if ./bin/abpoa test_data/seq.fa 2>/dev/null | diff -q - tests/ref_consensus.txt >/dev/null 2>&1; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - consensus regression"
    fi

    printf "  %-45s " "MSA output matches reference"
    if ./bin/abpoa test_data/seq.fa -a1 2>/dev/null | diff -q - tests/ref_msa.txt >/dev/null 2>&1; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - MSA regression"
    fi

    printf "  %-45s " "heterozygous output matches reference"
    if ./bin/abpoa test_data/heter.fa -d2 2>/dev/null | diff -q - tests/ref_heter.txt >/dev/null 2>&1; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - heter regression"
    fi

    # a trained model with gap extension 60, which the 16-bit DP could not hold ("Error in
    # cg_backtrack"): every score halved is the same model, so the output must not change
    printf "  %-45s " "large scores match the same scores halved"
    ok=1
    for opts in "-r1" "-r1 -b -1" "-r1 -b 1000 -f 0.1 -p"; do
        a=$(./bin/abpoa test_data/seq.fa $opts -M 210 -X 1020 -O 1290,3870 -E 60,2 2>/dev/null) || ok=0
        b=$(./bin/abpoa test_data/seq.fa $opts -M 105 -X 510 -O 645,1935 -E 30,1 2>/dev/null) || ok=0
        [ -n "$a" ] && [ "$a" = "$b" ] || ok=0
    done
    if [ $ok = 1 ]; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - large score regression"
    fi
    echo ""
fi

# Feature tests (run if test scripts exist)
echo "Feature tests:"
for test_script in "$SCRIPT_DIR"/test_*.sh; do
    [ -f "$test_script" ] || continue
    name="$(basename "$test_script" .sh)"
    run_test "$name" "$test_script"
done
echo ""

# Summary
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
    echo -e "Failed tests:$ERRORS"
    exit 1
fi
exit 0
