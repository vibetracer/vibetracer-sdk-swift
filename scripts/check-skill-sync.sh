#!/usr/bin/env bash
# Verify the "## Keeping this skill current" section is byte-identical
# across all five skills/vibe-tracer-swift-*/SKILL.md files (modulo the
# skill's own name).
#
# The section is intentionally duplicated per skill (so each skill can
# self-check independently), but the content must stay in sync. This
# hook catches silent drift — e.g. edits that fix the bash pipeline in
# one skill but forget the other four.
#
# Canonical source: scripts/.skill-version-check.template.md, with
# `__NAME__` substituted for each skill's folder name.
#
# This check runs against the *working tree*, not staged content — the
# drift we care about is what would exist in the commit, and that's
# equivalent to the working tree once staged files have been written
# back by the editor. For partial-stage edge cases the check errs on
# the strict side (any drift anywhere fails the commit).

set -euo pipefail

template_path="scripts/.skill-version-check.template.md"
if [ ! -f "$template_path" ]; then
  echo "error: missing $template_path — cannot run skill-sync check." >&2
  exit 1
fi

template="$(cat "$template_path")"
fail=0

for skill_dir in skills/vibe-tracer-swift-*/; do
  name="$(basename "$skill_dir")"
  file="$skill_dir/SKILL.md"

  [ -f "$file" ] || {
    echo "error: $file is missing." >&2
    fail=1
    continue
  }

  expected="${template//__NAME__/$name}"

  # Extract the section from the file: everything from the "## Keeping
  # this skill current" heading up to (but not including) the next
  # level-2 heading. awk's default record-at-a-time model works cleanly
  # here with a start/stop flag.
  actual="$(awk '
    /^## Keeping this skill current$/ { capture=1; print; next }
    capture && /^## / { capture=0 }
    capture { print }
  ' "$file")"

  if [ -z "$actual" ]; then
    echo "error: $file is missing the '## Keeping this skill current' section." >&2
    echo "  Regenerate from $template_path (substitute __NAME__ with $name)." >&2
    fail=1
    continue
  fi

  # Trim trailing blank lines from both so trivial whitespace doesn't
  # trigger spurious drift reports.
  actual="$(printf '%s\n' "$actual" | awk 'NF {p=1} p {print}' | awk '{lines[NR]=$0} END {for (i=1; i<=NR; i++) if (i<NR || lines[i]!="") print lines[i]}')"
  expected="$(printf '%s\n' "$expected" | awk 'NF {p=1} p {print}' | awk '{lines[NR]=$0} END {for (i=1; i<=NR; i++) if (i<NR || lines[i]!="") print lines[i]}')"

  if [ "$actual" != "$expected" ]; then
    echo "error: $file 'Keeping this skill current' section drifted from $template_path." >&2
    echo "  diff (expected vs actual, first lines):" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20 | sed 's/^/    /' >&2
    fail=1
  fi
done

exit $fail
