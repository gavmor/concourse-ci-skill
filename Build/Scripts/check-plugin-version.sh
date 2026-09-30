#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
set -euo pipefail

# Verify plugin.json version matches SKILL.md version
PLUGIN_V=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "unknown")
if [[ ! -d skills ]]; then
    echo "ERROR: no skills/ directory in $(pwd); run this script from the repository root"
    exit 1
fi
SKILL_MD=$(find skills -name 'SKILL.md' -print -quit)
if [[ -z "$SKILL_MD" ]]; then
    echo "ERROR: no SKILL.md found under skills/"
    exit 1
fi
SKILL_V=$(grep -oP 'version:\s*"?\K[0-9.]+' "$SKILL_MD" | head -1 || true)
if [[ -z "$SKILL_V" ]]; then
    echo "ERROR: $SKILL_MD has no version (expected a 'version:' entry in its front matter)"
    exit 1
fi
if [[ "$PLUGIN_V" != "$SKILL_V" ]]; then
    echo "ERROR: plugin.json version ($PLUGIN_V) != SKILL.md version ($SKILL_V)"
    exit 1
fi
echo "Version check passed: $PLUGIN_V"
