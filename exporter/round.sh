#!/bin/bash
# round.sh: one round of the exporter's conformance fixtures, for the owner to run. Safe to re-run.
#   1. If the patch is newer than the exporter binary (or there is none): a fresh copy of the
#      patched files from scratch/sema/zig-src into scratch/sema/zig-src-export (the whole tree
#      is copied once), the patch applied, and the compiler built without LLVM into
#      scratch/sema/zig-export. zig-src itself is never changed.
#   2. The dump tool built with the installed zig, reading through glint's own reader
#      (cf/src/compiled_read.zig, with aegis from cf's packages).
#   3. Each fixture: analysed by the exporter with GLINT_FACTS_DIR set (no binary emitted), its
#      facts file dumped as text and checked against its expect.txt; analysed a second time and
#      the two files compared byte for byte; analysed once without the variable, which must
#      write nothing.
# Everything is written under scratch/sema/exporter/out. Nothing goes to the terminal but the
# last line: "DONE exporter/out: P passed, F failed" or "FAILED at <step>: see <log>".
S=/Users/gusto/work/tycho/.wt/warp-fast/scratch/sema
E=$S/exporter
BOOT=/Users/gusto/.local/share/bay/zig/0.17.0/zig
TREE=$S/zig-src-export
NEW=$S/zig-export/bin/zig
PATCH=$E/glint-export-0.17.0.patch
OUT=$E/out
CF=/Users/gusto/work/tycho/.wt/warp-fast/cf
FORMAT=$CF/src/facts_format.zig
READER=$CF/src/compiled_read.zig
AEGIS=$(/bin/ls -d "$CF"/zig-pkg/aegis-*/src 2>/dev/null | head -1)/root.zig

fail() { echo "FAILED at $1: see $2"; exit 1; }
for need in "$BOOT" "$S/zig-src/build.zig" "$PATCH" "$FORMAT" "$READER" "$AEGIS" "$E/tool/facts_dump.zig"; do
    [ -e "$need" ] || fail "start" "$need (missing)"
done
rm -rf "$OUT"
mkdir -p "$OUT"

# 1. The exporter.
if [ ! -x "$NEW" ] || [ "$PATCH" -nt "$NEW" ]; then
    : > "$OUT/build.log"
    if [ ! -d "$TREE" ]; then
        cp -R "$S/zig-src" "$TREE" >> "$OUT/build.log" 2>&1 || fail "copy" "$OUT/build.log"
    fi
    rm -f "$NEW" "$TREE/src/glint_export.zig" "$TREE/src/glint_facts_format.zig"
    for f in src/Sema.zig src/Zcu/PerThread.zig src/Compilation.zig; do
        cp "$S/zig-src/$f" "$TREE/$f" >> "$OUT/build.log" 2>&1 || fail "copy" "$OUT/build.log"
    done
    ( cd "$TREE" && patch -p1 < "$PATCH" ) >> "$OUT/build.log" 2>&1 || fail "patch" "$OUT/build.log"
    ( cd "$TREE" && /usr/bin/time -l "$BOOT" build \
        -Dno-lib -Doptimize=ReleaseSafe -Dversion-string=0.17.0 \
        --prefix "$S/zig-export" ) >> "$OUT/build.log" 2>&1 || fail "build" "$OUT/build.log"
    [ -x "$NEW" ] || fail "build" "$OUT/build.log"
fi

# 2. The dump tool.
cp "$FORMAT" "$E/tool/facts_format.zig" || fail "dump tool" "$FORMAT"
( cd "$E/tool" && "$BOOT" build-exe -OReleaseSafe --dep reader --dep format -Mroot=facts_dump.zig --dep aegis -Mreader="$READER" -Maegis="$AEGIS" -Mformat=facts_format.zig \
    --cache-dir "$S/join/cache" --global-cache-dir "$S/join/gcache" -femit-bin=facts_dump ) > "$OUT/tool.log" 2>&1 \
    || fail "dump tool" "$OUT/tool.log"
DUMP=$E/tool/facts_dump

# 3. The fixtures.
analyse() { # NAME DIR-OR-EMPTY LOG
    rm -rf "$S/cache-fixture" "$S/gcache-fixture"
    ( cd "$E/fixtures/$1" && GLINT_FACTS_DIR="$2" "$NEW" build-obj -fno-emit-bin "$1.zig" \
        --zig-lib-dir "$S/zig-src/lib" \
        --cache-dir "$S/cache-fixture" --global-cache-dir "$S/gcache-fixture" ) > "$3" 2>&1
}
passed=0
failed=0
: > "$OUT/summary.txt"
for dir in "$E"/fixtures/*/; do
    name=$(basename "$dir")
    o=$OUT/$name
    mkdir -p "$o"
    verdict=PASS
    note() { echo "$name: $1" >> "$o/check.txt"; verdict=FAIL; }
    : > "$o/check.txt"

    if ! analyse "$name" "$o/facts-1" "$o/run-1.log"; then note "the exporter failed (run-1.log)"; fi
    count=$(/bin/ls "$o/facts-1" 2>/dev/null | grep -c '\.facts$')
    [ "$count" = 1 ] || note "expected one facts file, found $count"
    file=$(/bin/ls "$o/facts-1"/*.facts 2>/dev/null | head -1)
    if [ -n "$file" ]; then
        "$DUMP" "$file" > "$o/dump.txt" 2> "$o/dump.err" || note "the dump tool failed (dump.err)"
        "$DUMP" --all "$file" > "$o/dump-all.txt" 2>> "$o/dump.err"
        /bin/ls -l "$file" | awk '{ print $5 " bytes" }' > "$o/size.txt"
        # Every body is named by its function.
        unnamed=$(grep -c '(unnamed)' "$o/dump-all.txt")
        [ "$unnamed" = 0 ] || note "$unnamed body line(s) with no function's name (dump-all.txt)"
        # expect.txt: a count, a tab, a text: that many lines of the dump start with the text.
        # A line with no tab (a comment) is skipped.
        while IFS=$'\t' read -r want text; do
            [ -n "$text" ] || continue
            got=$(awk -v t="$text" 'index($0, t) == 1' "$o/dump.txt" | wc -l | tr -d ' ')
            [ "$got" = "$want" ] || note "expected $want line(s) starting with [$text], found $got"
        done < "$dir/expect.txt"
        # The same analysis again gives the same bytes.
        if analyse "$name" "$o/facts-2" "$o/run-2.log"; then
            again=$(/bin/ls "$o/facts-2"/*.facts 2>/dev/null | head -1)
            if [ -z "$again" ] || ! cmp -s "$file" "$again"; then note "a second run gave other bytes"; fi
            [ "$(basename "$file")" = "$(basename "${again:-none}")" ] || note "a second run gave another file name"
        else
            note "the exporter failed on the second run (run-2.log)"
        fi
    fi
    # Without the variable nothing is written and the analysis still succeeds.
    before=$(find "$o" -name '*.facts' | wc -l)
    if ! ( unset GLINT_FACTS_DIR; rm -rf "$S/cache-fixture" "$S/gcache-fixture"; cd "$E/fixtures/$name" && "$NEW" build-obj -fno-emit-bin "$name.zig" \
        --zig-lib-dir "$S/zig-src/lib" --cache-dir "$S/cache-fixture" --global-cache-dir "$S/gcache-fixture" ) > "$o/run-off.log" 2>&1; then
        note "the exporter failed with the variable unset (run-off.log)"
    fi
    after=$(find "$o" "$E/fixtures/$name" -name '*.facts' | wc -l)
    [ "$before" = "$after" ] || note "a facts file was written with the variable unset"

    echo "$verdict $name" >> "$OUT/summary.txt"
    cat "$o/check.txt" >> "$OUT/summary.txt"
    if [ "$verdict" = PASS ]; then passed=$((passed + 1)); else failed=$((failed + 1)); fi
done
grep -a -E '^ +[0-9.]+ real|maximum resident set size' "$OUT/build.log" >> "$OUT/summary.txt" 2>/dev/null
/bin/ls -l "$NEW" | awk '{ print "exporter binary " $5 " bytes" }' >> "$OUT/summary.txt"

echo "DONE exporter/out: $passed passed, $failed failed"
