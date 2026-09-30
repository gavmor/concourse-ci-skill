#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# Behaviour tests for Build/Scripts/check-plugin-version.sh, which the
# pre-push hook runs to compare .claude-plugin/plugin.json with the version in
# SKILL.md. Each case builds a minimal repository layout in a temporary
# directory and runs the script from there.
#
# Requires: bash, python3, GNU grep (-P).
# Usage: bash tests/check-plugin-version.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Build/Scripts/check-plugin-version.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# Creates a layout with the given plugin.json and SKILL.md versions.
layout() {
    local dir="$WORK/$1" plugin_v="$2" skill_v="$3"
    mkdir -p "$dir/.claude-plugin"
    printf '{"name": "x", "version": "%s"}\n' "$plugin_v" > "$dir/.claude-plugin/plugin.json"
    mkdir -p "$dir/skills/x"
    printf -- '---\nname: x\nmetadata:\n  version: "%s"\n---\n\n# X\n' "$skill_v" > "$dir/skills/x/SKILL.md"
    echo "$dir"
}

case_run() {
    local name="$1" dir="$2" expected_rc="$3" expected_out="$4"
    local out rc
    set +e
    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq "$expected_rc" ]] && grep -qF -- "$expected_out" <<< "$out"; then
        echo "ok   $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name (exit $rc, expected $expected_rc)"
        while IFS= read -r line; do printf '    | %s\n' "$line"; done <<< "$out"
        FAIL=$((FAIL + 1))
    fi
}

case_run "matching versions pass" "$(layout match 1.2.3 1.2.3)" 0 \
    "Version check passed: 1.2.3"
case_run "mismatching versions fail" "$(layout mismatch 1.2.3 1.2.4)" 1 \
    "ERROR: plugin.json version (1.2.3) != SKILL.md version (1.2.4)"
case_run "this repository's versions agree" "$ROOT" 0 "Version check passed:"

# The script used to exit 1 without a word in these layouts: find and grep -oP
# failed inside command substitutions under set -euo pipefail.
d="$(layout no-skills-dir 1.2.3 1.2.3)"; rm -rf "$d/skills"
case_run "a missing skills/ directory is named" "$d" 1 \
    "ERROR: no skills/ directory in"
d="$(layout no-skill-md 1.2.3 1.2.3)"; rm -f "$d/skills/x/SKILL.md"
case_run "a skills/ directory without SKILL.md is named" "$d" 1 \
    "ERROR: no SKILL.md found under skills/"
d="$(layout no-version 1.2.3 1.2.3)"
printf -- '---\nname: x\n---\n\n# X\n' > "$d/skills/x/SKILL.md"
case_run "a SKILL.md without a version is named" "$d" 1 \
    "ERROR: skills/x/SKILL.md has no version"

echo ""
echo "check-plugin-version.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
