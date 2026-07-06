#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=${XBRL_WORK:-"$ROOT/tests/xbrl-taxonomies"}
CACHE=${XBRL_CACHE:-"$WORK/cache"}
OUT=${XBRL_OUT:-"$WORK/out"}
REPORT_DIR=${XBRL_REPORT_DIR:-"$WORK/reports"}
REPORT=${XBRL_REPORT:-"$REPORT_DIR/xsdtohaskell.tsv"}
PATTERN=${XBRL_PATTERN:-"*.xsd"}
LIMIT=${XBRL_LIMIT:-0}
FILE_LIST=${XBRL_FILE_LIST:-}
TIMEOUT=${XBRL_TIMEOUT:-0}

mkdir -p "$OUT" "$REPORT_DIR"

if [ ! -d "$CACHE" ]; then
    echo "missing taxonomy cache: $CACHE" >&2
    echo "run script/fetch-xbrl-taxonomies.sh first" >&2
    exit 1
fi

echo "Building XsdToHaskell"
cabal build exe:XsdToHaskell

files="$REPORT_DIR/xsd-files.txt"
if [ -n "$FILE_LIST" ]; then
    sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$FILE_LIST" |
    while IFS= read -r file; do
        case "$file" in
            /*) printf '%s\n' "$file" ;;
            *)  printf '%s/%s\n' "$CACHE" "$file" ;;
        esac
    done > "$files"
else
    find "$CACHE" -type f -name '*.xsd' -path "$CACHE/$PATTERN" | sort > "$files"
fi

total=$(wc -l < "$files" | sed 's/^ *//')
if [ "$LIMIT" != 0 ] && [ "$total" -gt "$LIMIT" ]; then
    sed -n "1,${LIMIT}p" "$files" > "$files.limit"
    mv "$files.limit" "$files"
    total=$LIMIT
fi

printf 'status\txsd\toutput\tlog\n' > "$REPORT"

run_xsdtohaskell() {
    xsd=$1
    out=$2
    if [ "$TIMEOUT" = 0 ]; then
        cabal exec XsdToHaskell -- "$xsd" "$out"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'my $seconds = shift @ARGV; alarm $seconds; exec @ARGV' \
            "$TIMEOUT" cabal exec XsdToHaskell -- "$xsd" "$out"
    elif command -v timeout >/dev/null 2>&1; then
        timeout "$TIMEOUT" cabal exec XsdToHaskell -- "$xsd" "$out"
    else
        echo "warning: XBRL_TIMEOUT requested but neither perl nor timeout is available" >&2
        cabal exec XsdToHaskell -- "$xsd" "$out"
    fi
}

ok=0
fail=0
index=0
while IFS= read -r xsd; do
    index=$((index + 1))
    rel=${xsd#"$CACHE"/}
    out="$OUT/${rel%.xsd}.hs"
    log="$REPORT_DIR/${rel%.xsd}.log"
    mkdir -p "$(dirname "$out")" "$(dirname "$log")"

    echo "[$index/$total] XsdToHaskell $rel"
    if run_xsdtohaskell "$xsd" "$out" > "$log" 2>&1; then
        ok=$((ok + 1))
        printf 'ok\t%s\t%s\t%s\n' "$xsd" "$out" "$log" >> "$REPORT"
    else
        code=$?
        fail=$((fail + 1))
        if [ "$code" = 142 ]; then
            printf 'timeout\t%s\t%s\t%s\n' "$xsd" "$out" "$log" >> "$REPORT"
        else
            printf 'fail\t%s\t%s\t%s\n' "$xsd" "$out" "$log" >> "$REPORT"
        fi
    fi
done < "$files"

echo "XsdToHaskell report: $REPORT"
echo "ok=$ok fail=$fail total=$total"

if [ "$fail" -ne 0 ]; then
    exit 1
fi
