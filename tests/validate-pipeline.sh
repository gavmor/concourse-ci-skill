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

echo ""
echo "validate-pipeline.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
