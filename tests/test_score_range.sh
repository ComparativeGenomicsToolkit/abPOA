#!/bin/bash
# Score width (simd_abpoa_score_range in src/abpoa_align_simd.c): the choice between 16- and 32-bit
# DP, the checks on every 16-bit alignment that is not proven safe, and the retry at 32 bits.
#
# abPOA is built once more with -DABPOA_TEST_SCORE_RANGE, under which ABPOA_TEST_BITS=32 forces
# 32 bits and ABPOA_TEST_FLOOR16=<v> forces 16 bits wherever the scores fit, with "minus infinity"
# at v, high enough to lose to real scores (capped at the highest floor the checks can cover).
# Every output must equal the plain build's:
#   1. 16 and 32 bits agree, in every gap and alignment mode, banded and not
#   2. a floor that loses is caught, and the alignment redone at 32 bits gives the same result
#   3. on both sides of the 16-bit limits (query length, graph depth) the result is the 32-bit one
#   4. scores that the previous 16-bit choice could not hold (a trained model with gap extension
#      60, which aborted with "Error in cg_backtrack") give the 32-bit result, and the same as with
#      every score halved
#   5. a 16-bit alignment proven safe needs no retry, even where row 0's gap on the dearer piece
#      leaves the 16-bit range
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_DIR="${TMPDIR:-/tmp}/abpoa_score_range_$$"
trap "rm -rf $BUILD_DIR" EXIT
ERRORS=0
fail() { echo "FAIL: $*"; ERRORS=$((ERRORS + 1)); }

# test builds: the default one, and on x86 also SSE2, whose vectors hold half as many scores
TEST_FLAGS="-Wall -Wno-unused-function -Wno-misleading-indentation -DUSE_SIMDE -DSIMDE_ENABLE_NATIVE_ALIASES -DABPOA_TEST_SCORE_RANGE"
BINS=""
build() { # name, make args...
    local d="$BUILD_DIR/$1"; shift
    mkdir -p "$d" && cp -r src Makefile "$d/" && ln -s "$PROJECT_DIR/include" "$d/include"
    make -C "$d" clean >/dev/null 2>&1
    if make -C "$d" -j2 EXTRA_FLAGS="$TEST_FLAGS" "$@" >"$d/make.log" 2>&1; then
        BINS="$BINS $(ls "$d"/bin/abpoa*)"
    else
        tail -20 "$d/make.log"; fail "test build ($*) failed"
    fi
}
build default
case "$(uname -m)" in x86_64|amd64) build sse2 sse2=1 ;; esac
[ -n "$BINS" ] || { echo "$ERRORS score range errors"; exit 1; }

# deterministic random sequences: randseq <seed> <length> [<mutation rate>, applied to the seed's own sequence]
randseq() {
    awk -v seed="$1" -v n="$2" -v mu="${3:-0}" 'BEGIN { srand(seed); s = "";
        for (i = 0; i < n; ++i) s = s substr("ACGT", int(rand() * 4) + 1, 1);
        if (mu > 0) { srand(seed + 7919); t = "";
            for (i = 1; i <= n; ++i) { r = rand(); c = substr(s, i, 1);
                if (r < mu / 3) continue; else if (r < 2 * mu / 3) c = substr("ACGT", int(rand() * 4) + 1, 1);
                else if (r < mu) c = c substr("ACGT", int(rand() * 4) + 1, 1); t = t c }
            s = t }
        print s }'
}

# every way of running bin against in.fa with opts must give the plain run's output
same_as_plain() { # bin, in.fa, opts...
    local bin="$1" fa="$2"; shift 2
    local ref out f
    if ! ref=$("$bin" "$@" "$fa" 2>/dev/null); then fail "$(basename "$bin") $* $fa exits non-zero"; return; fi
    out=$(ABPOA_TEST_BITS=32 "$bin" "$@" "$fa" 2>/dev/null) || true
    [ "$out" = "$ref" ] || fail "$(basename "$bin") $* $fa: 32 bits differ from the plain run"
    for f in -20000 -6000 -2000 -500 1 2000; do
        out=$(ABPOA_TEST_FLOOR16=$f "$bin" "$@" "$fa" 2>/dev/null) || true
        [ "$out" = "$ref" ] || fail "$(basename "$bin") $* $fa: 16 bits at floor $f differ from the plain run"
    done
}

# 1, 2: gap modes x alignment modes x banding, on the shipped test data
for bin in $BINS; do
    for fa in test_data/seq.fa test_data/heter.fa; do
        for gap in "" "-O 4,0 -E 2,0" "-O 0,0 -E 2,0"; do
            for mode in 0 1 2; do
                for band in "" "-b -1"; do
                    same_as_plain "$bin" "$fa" -r1 -m $mode $gap $band
                done
            done
        done
        for extra in "-s -r2" "-G -r1" "-p -r1"; do
            same_as_plain "$bin" "$fa" $extra
        done
    done
    # the losing floors must actually have been caught and retried
    n=$(ABPOA_TEST_FLOOR16=2000 "$bin" -V 2 -r1 test_data/heter.fa 2>&1 >/dev/null | grep -c "redone at 32 bits" || true)
    [ "$n" -gt 0 ] || fail "$(basename "$bin"): a 16-bit floor of 2000 was never caught"
done

# 3: across the 16-bit limits, with cactus-like trained scores and band (every row covers the query)
T1="-M 210 -X 1080 -O 1410,4230 -E 30,1 -b 1000 -f 0.1 -r1"
widths() { "$@" -V 2 2>&1 >/dev/null | grep -o "score width: [0-9]* bits" | sort -u | tr '\n' ' '; }
for bin in $BINS; do
    seen=""
    for len in $(awk 'BEGIN { for (i = 125; i <= 145; ++i) print i }'); do  # query length: 135 is the last 16-bit one
        fa="$BUILD_DIR/q$len.fa"
        printf ">a\n%s\n>b\n%s\n>c\n%s\n" "$(randseq $len $len)" "$(randseq $len $len 0.1)" "$(randseq $((len + 1)) $len 0.05)" > "$fa"
        same_as_plain "$bin" "$fa" $T1
        seen="$seen$(widths "$bin" $T1 "$fa")"
    done
    for w in 16 32; do echo "$seen" | grep -q "$w bits" || fail "$(basename "$bin"): query length sweep never ran at $w bits"; done
    seen=""
    for len in $(awk 'BEGIN { for (i = 7300; i <= 8100; i += 50) print i }'); do  # graph depth for a 130 bp query
        fa="$BUILD_DIR/d$len.fa"
        printf ">a\n%s\n>b\n%s\n" "$(randseq $len $len)" "$(randseq 1 130)" > "$fa"
        same_as_plain "$bin" "$fa" $T1
        seen="$seen$(widths "$bin" $T1 "$fa")"
    done
    for w in 16 32; do echo "$seen" | grep -q "$w bits" || fail "$(basename "$bin"): graph depth sweep never ran at $w bits"; done
done

# 4: the HPRC oct9 chr2 model, scaled 30x, and the same model halved
T2="-M 210 -X 1020 -O 1290,3870 -E 60,2"
T2H="-M 105 -X 510 -O 645,1935 -E 30,1"
for bin in $BINS; do
    for fa in test_data/seq.fa $BUILD_DIR/q125.fa $BUILD_DIR/q140.fa; do
        for opts in "-r1" "-r1 -b -1" "-r1 -b 1000 -f 0.1 -p" "-r1 -m 1" "-r1 -m 2 -b -1"; do
            same_as_plain "$bin" "$fa" $T2 $opts
            a=$("$bin" $T2 $opts "$fa" 2>/dev/null) || true
            b=$("$bin" $T2H $opts "$fa" 2>/dev/null) || true
            [ -n "$a" ] && [ "$a" = "$b" ] || fail "$(basename "$bin") $opts $fa: chr2 model differs from it halved"
        done
    done
done

# 5: convex gaps with a gap extension above the match score: the width choice bounds the cheaper
# piece's gap along row 0, -(24 + i), while the other piece's -(4 + 100*i) is out of 16-bit range
# past column 327; that must neither change the result nor make a proven alignment need its retry
fa="$BUILD_DIR/row0.fa"
printf ">a\n%s\n>b\n%s\n" "$(randseq 5 500)" "$(randseq 6 400)" > "$fa"
R0="-M 1 -X 4 -O 4,24 -E 100,1 -b -1 -r1"
for bin in $BINS; do
    same_as_plain "$bin" "$fa" $R0
    [ "$(widths "$bin" $R0 "$fa")" = "score width: 16 bits " ] || fail "$(basename "$bin") $R0: not a 16-bit alignment"
    n=$("$bin" $R0 -V 2 "$fa" 2>&1 >/dev/null | grep -c "redone at 32 bits" || true)
    [ "$n" = 0 ] || fail "$(basename "$bin") $R0: a proven 16-bit alignment was redone at 32 bits"
done

if [ $ERRORS -gt 0 ]; then
    echo "$ERRORS score range errors"
    exit 1
fi
echo "Score range checks passed"
exit 0
