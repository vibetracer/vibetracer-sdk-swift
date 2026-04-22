#!/usr/bin/env bash
# Verify that every "canonical stanza" defined under scripts/.skill-templates/
# is byte-identical (modulo `__NAME__` substitution) across all five
# skills/vibe-tracer-swift-*/SKILL.md files.
#
# Each `.md` file under .skill-templates/ is one stanza. The template's first
# `## ` heading names the stanza; the body is everything from that heading up
# to (but not including) the next level-2 heading, with `__NAME__` replaced by
# the skill's own folder name.
#
# The hook catches silent drift — e.g. an edit that fixes the bash pipeline in
# one skill but forgets the other four. Adding a new canonical stanza is a
# matter of dropping a new `.md` file into `.skill-templates/`; this script
# discovers and enforces it on the next run.
#
# This check runs against the *working tree*, not staged content — the drift
# we care about is what would exist in the commit, equivalent to the working
# tree once staged files have been written back by the editor. For
# partial-stage edge cases the check errs strict (any drift fails the commit).

set -euo pipefail

templates_dir="scripts/.skill-templates"
if [ ! -d "$templates_dir" ]; then
  echo "error: missing $templates_dir — cannot run skill-sync check." >&2
  exit 1
fi

shopt -s nullglob
templates=("$templates_dir"/*.md)
shopt -u nullglob

if [ "${#templates[@]}" -eq 0 ]; then
  echo "error: no canonical stanzas under $templates_dir/" >&2
  exit 1
fi

# Extract the heading line (first `^## ` line) from a file. The remainder of
# the section is the body — everything from the heading up to the next `^## `
# line (the "next level-2 heading" boundary).
extract_heading() {
  awk '/^## / {print; exit}' "$1"
}

extract_section() {
  # $1 = file path, $2 = the exact heading line to anchor on.
  awk -v hdr="$2" '
    $0 == hdr { capture=1; print; next }
    capture && /^## / { capture=0 }
    capture { print }
  ' "$1"
}

# Trim trailing blank lines so trivial whitespace doesn't trigger spurious
# drift reports. Used on both expected and actual.
trim_trailing_blank() {
  awk '{lines[NR]=$0} END {
    for (last=NR; last>0; last--) if (lines[last] ~ /[^[:space:]]/) break
    for (i=1; i<=last; i++) print lines[i]
  }'
}

fail=0

for template in "${templates[@]}"; do
  template_name="$(basename "$template" .md)"
  template_heading="$(extract_heading "$template")"

  if [ -z "$template_heading" ]; then
    echo "error: $template has no '## ' heading; cannot enforce." >&2
    fail=1
    continue
  fi

  template_body="$(cat "$template")"

  for skill_dir in skills/vibe-tracer-swift-*/; do
    name="$(basename "$skill_dir")"
    file="$skill_dir/SKILL.md"

    [ -f "$file" ] || {
      echo "error: $file is missing." >&2
      fail=1
      continue
    }

    expected="$(printf '%s' "$template_body" | sed "s/__NAME__/$name/g" | trim_trailing_blank)"
    actual="$(extract_section "$file" "$template_heading" | trim_trailing_blank)"

    if [ -z "$actual" ]; then
      echo "error: $file is missing the '$template_heading' section." >&2
      echo "  Add the canonical stanza from $template (substitute __NAME__ with $name)." >&2
      fail=1
      continue
    fi

    if [ "$actual" != "$expected" ]; then
      echo "error: $file '$template_heading' section drifted from $template." >&2
      echo "  diff (expected vs actual, first lines):" >&2
      diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -20 | sed 's/^/    /' >&2
      fail=1
    fi
  done
done

exit $fail
