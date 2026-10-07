#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# Behaviour tests for skills/concourse-ci/scripts/validate-pipeline.sh.
#
# Each case writes a pipeline fixture to a temporary directory and runs the
# validator with a PATH that holds only the tools the case needs, so a `fly`
# installed on the developer's machine (and its logged-in targets) is never
# used. Cases that need fly get a stub that records its arguments.
#
# Requires: bash, mikefarah yq v4, GNU grep, awk, tr, head.
# Usage: bash tests/validate-pipeline.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/concourse-ci/scripts/validate-pipeline.sh"
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# PATH directory with the tools the validator calls, and without fly.
BIN="$WORK/bin"
mkdir -p "$BIN"
for tool in yq grep head awk tr; do
    path="$(command -v "$tool")" || { echo "missing required tool: $tool" >&2; exit 2; }
    ln -s "$path" "$BIN/$tool"
done

# Runs the validator; sets OUT (stdout+stderr) and RC (exit status).
run_validator() {
    local path_dirs="$1"
    shift
    set +e
    OUT="$(PATH="$path_dirs" "$BASH_BIN" "$SCRIPT" "$@" 2>&1)"
    RC=$?
    set -e
}

check() {
    local name="$1" expected_rc="$2"
    shift 2
    local ok=1
    if [[ "$RC" -ne "$expected_rc" ]]; then
        echo "  expected exit $expected_rc, got $RC"
        ok=0
    fi
    local want
    for want in "$@"; do
        if [[ "$want" == !* ]]; then
            if grep -qF -- "${want#!}" <<< "$OUT"; then
                echo "  unexpected output: ${want#!}"
                ok=0
            fi
        elif ! grep -qF -- "$want" <<< "$OUT"; then
            echo "  missing output: $want"
            ok=0
        fi
    done
    if [[ "$ok" -eq 1 ]]; then
        echo "ok   $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name"
        while IFS= read -r line; do printf '    | %s\n' "$line"; done <<< "$OUT"
        FAIL=$((FAIL + 1))
    fi
}

fixture() {
    local file="$WORK/$1"
    cat > "$file"
    echo "$file"
}

VALID="$(fixture valid.yml <<'YAML'
resources:
  - name: repo
    type: git
    icon: git
    source:
      uri: https://example.com/repo.git
      branch: main
jobs:
  - name: test
    plan:
      - get: repo
        trigger: true
      - task: unit
        file: repo/ci/unit.yml
YAML
)"

run_validator "$BIN"
check "no argument prints usage and fails" 1 "Usage:"

run_validator "$BIN" "$WORK/does-not-exist.yml"
check "missing pipeline file fails" 1 "Pipeline file not found"

run_validator "$BIN" "$VALID"
check "valid pipeline passes without fly" 0 \
    "YAML syntax valid" "Found 1 jobs" "Found 1 resources" \
    "fly CLI not found" "Summary: 0 errors, 0 warnings"

NO_RESOURCES="$(fixture no-resources.yml <<'YAML'
jobs:
  - name: hello
    plan:
      - task: say-hello
        config:
          platform: linux
          run:
            path: echo
YAML
)"
run_validator "$BIN" "$NO_RESOURCES"
check "warning alone does not fail the run" 0 \
    "Pipeline has no resources defined" "Summary: 0 errors, 1 warnings"

NO_JOBS="$(fixture no-jobs.yml <<'YAML'
resources:
  - name: repo
    type: git
    source:
      uri: https://example.com/repo.git
YAML
)"
run_validator "$BIN" "$NO_JOBS"
check "pipeline without jobs fails after the summary" 1 \
    "Pipeline has no jobs defined" "Summary: 1 errors, 0 warnings"

BROKEN="$(fixture broken.yml <<'YAML'
jobs:
  - name: test
    plan: [
YAML
)"
run_validator "$BIN" "$BROKEN"
check "invalid YAML fails" 1 "Invalid YAML syntax"

# A long valid document before the syntax error: yq prints more than the five
# lines the validator shows, and the exit status must still be 1.
LONG_BROKEN="$WORK/long-broken.yml"
{
    echo "jobs:"
    for i in $(seq 1 40); do
        printf '  - name: job-%s\n    plan:\n      - task: t\n' "$i"
    done
    echo "---"
    echo "not: [yaml"
} > "$LONG_BROKEN"
run_validator "$BIN" "$LONG_BROKEN"
check "invalid YAML after a long document fails with exit 1" 1 "Invalid YAML syntax"

CREDS="$(fixture creds.yml <<'YAML'
resources:
  - name: repo
    type: git
    source:
      uri: https://example.com/repo.git
      password: hunter2
jobs:
  - name: test
    plan:
      - get: repo
        trigger: true
YAML
)"
run_validator "$BIN" "$CREDS"
check "literal credential is reported" 0 "Possible hardcoded credentials"

VAR_CREDS="$(fixture var-creds.yml <<'YAML'
resources:
  - name: repo
    type: git
    source:
      uri: https://example.com/repo.git
      password: ((git.password))
jobs:
  - name: test
    plan:
      - get: repo
        trigger: true
YAML
)"
run_validator "$BIN" "$VAR_CREDS"
check "((variable)) credential is not reported" 0 \
    "!Possible hardcoded credentials" "Summary: 0 errors, 0 warnings"

TAGS="$(fixture tags.yml <<'YAML'
resources:
  - name: repo
    type: git
    source:
      uri: https://example.com/repo.git
      tag_regex: '^v1.2'
jobs:
  - name: release
    plan:
      - get: repo
        trigger: true
      - put: repo
        params:
          repository: repo
YAML
)"
run_validator "$BIN" "$TAGS"
check "unescaped tag_regex and read/write tag resource are reported" 0 \
    "Possible unescaped dots in tag_regex" \
    "Resource 'repo' with tag_regex is used for both get and put" \
    "Summary: 0 errors, 2 warnings"

# A resource name is pipeline content. It reached yq as part of the
# expression and was split on whitespace, so a name with a space or a
# double quote was never checked and a crafted name could run yq functions.
ODD_NAME="$(fixture odd-name.yml <<'YAML'
resources:
  - name: 'my "repo"'
    type: git
    source:
      uri: https://example.com/repo.git
      tag_regex: '^v1\.2'
jobs:
  - name: release
    plan:
      - get: 'my "repo"'
        trigger: true
      - put: 'my "repo"'
YAML
)"
run_validator "$BIN" "$ODD_NAME"
check "a resource name with a space and quotes is checked as one name" 0 \
    "Resource 'my \"repo\"' with tag_regex is used for both get and put" \
    "Summary: 0 errors, 2 warnings"

MANUAL="$(fixture manual.yml <<'YAML'
resources:
  - name: repo
    type: git
    source:
      uri: https://example.com/repo.git
jobs:
  - name: deploy
    plan:
      - get: repo
YAML
)"
run_validator "$BIN" "$MANUAL"
check "job without triggering get is listed" 0 \
    "Jobs without auto-triggering gets (may be intentional): deploy"

# fly stub: `fly targets` prints nothing, `fly validate-pipeline` records its
# arguments and exits with FLY_RC.
FLYBIN="$WORK/flybin"
mkdir -p "$FLYBIN"
cat > "$FLYBIN/fly" <<STUB
#!$BASH_BIN
if [[ "\$1" == "targets" ]]; then exit 0; fi
printf '%s\n' "\$*" > "$WORK/fly-args"
exit "\${FLY_RC:-0}"
STUB
chmod +x "$FLYBIN/fly"

VARS="$(fixture vars.yml <<'YAML'
git:
  uri: https://example.com/repo.git
YAML
)"

export FLY_RC=0
run_validator "$FLYBIN:$BIN" "$VALID" "$VARS"
check "fly without target validates syntax with var files" 0 \
    "No fly target found" "Pipeline syntax validated with fly"
if [[ "$(cat "$WORK/fly-args")" == "validate-pipeline -c $VALID -l $VARS" ]]; then
    echo "ok   fly receives the pipeline and the var file"
    PASS=$((PASS + 1))
else
    echo "FAIL fly receives the pipeline and the var file: $(cat "$WORK/fly-args")"
    FAIL=$((FAIL + 1))
fi

export FLY_RC=1
run_validator "$FLYBIN:$BIN" "$VALID"
check "failing fly validation fails the run" 1 \
    "fly syntax validation failed" "Summary: 1 errors, 0 warnings"

# validate_yaml_syntax falls back to python3 when yq is missing. main() stops
# earlier in that case (missing yq ends the run), so the function is called
# directly from the sourced script. The pipeline path is an argument of the
# python3 program, not part of its text, so a path holding a quote is read
# like any other.
PYBIN="$WORK/pybin"
mkdir -p "$PYBIN"
# A wrapper, not a symlink: a virtualenv interpreter reached through a
# symlink elsewhere no longer finds its own packages.
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v python3)" > "$PYBIN/python3"
chmod +x "$PYBIN/python3"
yaml_syntax_via_python3() {
    set +e
    # shellcheck disable=SC2016  # $1/$2 belong to the inner bash, not this one
    OUT="$(PATH="$PYBIN" "$BASH_BIN" -c 'source "$1" && validate_yaml_syntax "$2"' _ "$SCRIPT" "$1" 2>&1)"
    RC=$?
    set -e
}
if "$PYBIN/python3" -c 'import yaml' 2>/dev/null; then
    mkdir -p "$WORK/it's here"
    cp "$VALID" "$WORK/it's here/pipe'line.yml"
    yaml_syntax_via_python3 "$WORK/it's here/pipe'line.yml"
    check "python3 fallback reads a path holding a quote" 0 \
        "YAML syntax valid" "!Invalid YAML syntax"
    yaml_syntax_via_python3 "$BROKEN"
    check "python3 fallback still rejects invalid YAML" 1 "Invalid YAML syntax"
else
    echo "skip python3 fallback cases: PyYAML is not installed"
fi

BIN_NO_YQ="$WORK/bin-no-yq"
mkdir -p "$BIN_NO_YQ"
for tool in grep head awk tr; do
    ln -s "$(command -v "$tool")" "$BIN_NO_YQ/$tool"
done
run_validator "$BIN_NO_YQ" "$VALID"
check "a missing yq ends the run with exit 1" 1 "yq not found" "!Summary:"

# Messages carry resource names from the pipeline; they are printed as text,
# so a backslash sequence in a name stays a backslash sequence.
ESC_NAME="$(fixture esc-name.yml <<'YAML'
resources:
  - name: 'repo\033[31m'
    type: git
    source:
      uri: https://example.com/repo.git
      tag_regex: '^v1\.2'
jobs:
  - name: release
    plan:
      - get: 'repo\033[31m'
        trigger: true
      - put: 'repo\033[31m'
YAML
)"
run_validator "$BIN" "$ESC_NAME"
check "a backslash sequence in a resource name is printed as text" 0 \
    "Resource 'repo\\033[31m' with tag_regex"

# Every shipped example pipeline passes the validator; the vars template is
# not a pipeline and only has to parse.
for example in "$ROOT"/skills/concourse-ci/examples/*.yml; do
    name="$(basename "$example")"
    if [[ "$name" == "vars-template.yml" ]]; then
        if yq eval '.' "$example" > /dev/null 2>&1; then
            echo "ok   example $name parses"
            PASS=$((PASS + 1))
        else
            echo "FAIL example $name parses"
            FAIL=$((FAIL + 1))
        fi
        continue
    fi
    run_validator "$BIN" "$example"
    check "example $name passes the validator" 0 "YAML syntax valid" "Summary: 0 errors"
done

echo ""
echo "validate-pipeline.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
