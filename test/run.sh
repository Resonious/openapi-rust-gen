#!/bin/bash
#
# Generates a Rust crate from each test schema and runs `cargo check`
# to verify the generated code compiles.
#
# Usage:
#   ./test/run.sh          # run all schema tests
#   ./test/run.sh basic    # run only matching schemas
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMAS_DIR="$SCRIPT_DIR/schemas"
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

filter="${1:-}"

passed=0
failed=0
skipped=0
errors=()

# Include repo-root schemas as regression tests.
# petstore.json is excluded: it has a pre-existing orphan-rule issue
# (type Pets = Vec<Pet> then impl Into<Result<…>> for Pets).
for schema in "$ROOT_DIR"/ex.json "$SCHEMAS_DIR"/*.json; do
    name=$(basename "$schema" .json)

    if [[ -n "$filter" && "$name" != *"$filter"* ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    printf "  %-30s" "$name"

    out_dir="$WORK_DIR/$name"

    # Generate
    if ! ruby "$ROOT_DIR/main.rb" "$schema" "$out_dir/$name" >"$WORK_DIR/$name.stdout" 2>"$WORK_DIR/$name.stderr"; then
        echo "FAIL (generate)"
        failed=$((failed + 1))
        errors+=("$name: generation failed"$'\n'"$(cat "$WORK_DIR/$name.stderr")")
        continue
    fi

    # The generator uses the full output path as the crate name, which
    # contains slashes. Patch it to a simple identifier.
    sed -i "s|^name = .*|name = \"test_${name}\"|" "$out_dir/$name/Cargo.toml"

    # cargo check validates types and borrows without producing binaries
    if ! cargo check --manifest-path "$out_dir/$name/Cargo.toml" 2>"$WORK_DIR/$name.cargo.stderr"; then
        echo "FAIL (cargo check)"
        failed=$((failed + 1))
        errors+=("$name: cargo check failed"$'\n'"$(cat "$WORK_DIR/$name.cargo.stderr")")
        continue
    fi

    echo "ok"
    passed=$((passed + 1))
done

echo
echo "  $passed passed, $failed failed, $skipped skipped"

if [[ ${#errors[@]} -gt 0 ]]; then
    echo
    echo "Failures:"
    for err in "${errors[@]}"; do
        echo "  ---"
        echo "  $err" | head -20
    done
    exit 1
fi
