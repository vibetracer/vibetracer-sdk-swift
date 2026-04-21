#!/usr/bin/env bash
# Integration tests for the Codex install path in ../install.sh.
# Runs install.sh against a sandboxed HOME with a PATH-shimmed fake curl —
# no network, no side effects outside $SANDBOX.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"

SKILLS=(
  vibe-tracer-swift-install
  vibe-tracer-swift-events
  vibe-tracer-swift-identity
  vibe-tracer-swift-debug
  vibe-tracer-swift-platform-config
)

PASS=0
FAIL=0
FAILURES=()

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  FAKE_HOME="$SANDBOX/home"
  FAKE_BIN="$SANDBOX/bin"
  mkdir -p "$FAKE_HOME" "$FAKE_BIN"

  cat > "$FAKE_BIN/curl" <<'CURL_EOF'
#!/usr/bin/env bash
# Fake curl — writes a stub SKILL.md to the -o target.
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -fsSL|-fsS|-sf|-s|-f|-L) shift ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || { echo "fake curl: missing -o" >&2; exit 2; }
[ -n "$url" ] || { echo "fake curl: missing url" >&2; exit 2; }
name="$(echo "$url" | sed -E 's|.*/skills/([^/]+)/SKILL.md.*|\1|')"
cat > "$out" <<STUB
---
name: $name
version: 2026-04-21
description: stub for testing
---
# $name stub
STUB
CURL_EOF
  chmod +x "$FAKE_BIN/curl"
}

teardown_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

run_install() {
  HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" bash "$INSTALL_SH" "$@"
}

assert() {
  local cond="$1" msg="$2"
  if eval "$cond"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("[$CURRENT_CASE] $msg")
    echo "  FAIL: $msg" >&2
  fi
}

CURRENT_CASE=""
test_case() {
  CURRENT_CASE="$1"
  shift
  echo ""
  echo "== $CURRENT_CASE =="
  setup_sandbox
  if ! "$@"; then
    FAIL=$((FAIL + 1))
    FAILURES+=("[$CURRENT_CASE] case body exited non-zero")
    echo "  FAIL: case body exited non-zero" >&2
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# cases
# ---------------------------------------------------------------------------

case_clean_install() {
  run_install --tool codex >/dev/null
  assert '[ -f "$FAKE_HOME/.codex/AGENTS.md" ]' "AGENTS.md created"
  assert 'grep -q "<!-- vibetracer:begin" "$FAKE_HOME/.codex/AGENTS.md"' "begin sentinel present"
  assert 'grep -q "<!-- vibetracer:end -->" "$FAKE_HOME/.codex/AGENTS.md"' "end sentinel present"
  for s in "${SKILLS[@]}"; do
    assert "[ -f '$FAKE_HOME/.codex/skills/$s/SKILL.md' ]" "$s/SKILL.md present"
  done
}

case_rerun_idempotent() {
  run_install --tool codex >/dev/null
  run_install --tool codex >/dev/null
  local begin_count end_count
  begin_count=$(grep -c "<!-- vibetracer:begin" "$FAKE_HOME/.codex/AGENTS.md" || true)
  end_count=$(grep -c "<!-- vibetracer:end -->" "$FAKE_HOME/.codex/AGENTS.md" || true)
  assert "[ '$begin_count' = '1' ]" "exactly one begin sentinel after re-run (got $begin_count)"
  assert "[ '$end_count' = '1' ]" "exactly one end sentinel after re-run (got $end_count)"
}

case_append_preserves_user_content() {
  mkdir -p "$FAKE_HOME/.codex"
  printf "# My Custom Instructions\n\nAlways be terse.\n" > "$FAKE_HOME/.codex/AGENTS.md"
  run_install --tool codex >/dev/null
  assert 'grep -q "My Custom Instructions" "$FAKE_HOME/.codex/AGENTS.md"' "user heading preserved"
  assert 'grep -q "Always be terse" "$FAKE_HOME/.codex/AGENTS.md"' "user body preserved"
  assert 'grep -q "<!-- vibetracer:begin" "$FAKE_HOME/.codex/AGENTS.md"' "our block appended"
  local user_line block_line
  user_line=$(grep -n "My Custom" "$FAKE_HOME/.codex/AGENTS.md" | head -1 | cut -d: -f1)
  block_line=$(grep -n "vibetracer:begin" "$FAKE_HOME/.codex/AGENTS.md" | head -1 | cut -d: -f1)
  assert "[ '$user_line' -lt '$block_line' ]" "user content before our block (user=$user_line, block=$block_line)"
}

case_uninstall_empty_removes_file() {
  run_install --tool codex >/dev/null
  run_install --tool codex --uninstall >/dev/null
  assert '[ ! -f "$FAKE_HOME/.codex/AGENTS.md" ]' "AGENTS.md deleted when only our block existed"
  for s in "${SKILLS[@]}"; do
    assert "[ ! -d '$FAKE_HOME/.codex/skills/$s' ]" "$s removed"
  done
}

case_uninstall_preserves_user() {
  mkdir -p "$FAKE_HOME/.codex"
  printf "# User Content\n\nkeep me\n" > "$FAKE_HOME/.codex/AGENTS.md"
  run_install --tool codex >/dev/null
  run_install --tool codex --uninstall >/dev/null
  assert '[ -f "$FAKE_HOME/.codex/AGENTS.md" ]' "AGENTS.md kept (user content exists)"
  assert 'grep -q "User Content" "$FAKE_HOME/.codex/AGENTS.md"' "user content preserved"
  assert '! grep -q "vibetracer:begin" "$FAKE_HOME/.codex/AGENTS.md"' "begin sentinel stripped"
  assert '! grep -q "vibetracer:end" "$FAKE_HOME/.codex/AGENTS.md"' "end sentinel stripped"
  local blank_runs
  blank_runs=$(awk 'BEGIN{max=0; cur=0} /^$/{cur++; if(cur>max)max=cur; next} {cur=0} END{print max}' "$FAKE_HOME/.codex/AGENTS.md")
  assert "[ '$blank_runs' -le '1' ]" "no runs of >1 blank line after strip (got $blank_runs)"
}

case_tool_all_detects_codex() {
  mkdir -p "$FAKE_HOME/.codex"
  run_install --tool all >/dev/null
  assert '[ -f "$FAKE_HOME/.codex/AGENTS.md" ]' "--tool all installed to codex"
  assert '[ -f "$FAKE_HOME/.codex/skills/vibe-tracer-swift-install/SKILL.md" ]' "--tool all wrote skill files to codex"
}

case_project_slug_appears_in_closing_prompt() {
  local out
  out=$(run_install --tool codex --project acme-a1b2 2>&1)
  assert 'echo "$out" | grep -q "My project slug is acme-a1b2"' "closing prompt embeds slug"
  # The URL template is the skill's responsibility; install.sh must not
  # quote it directly (single source of truth).
  assert '! echo "$out" | grep -q "vibetracer.xyz/projects/"' "install.sh does not print the settings URL"
}

case_no_project_slug_uses_generic_prompt() {
  local out
  out=$(run_install --tool codex 2>&1)
  assert 'echo "$out" | grep -q "help me figure out what to track\""' "generic prompt rendered when no slug"
  assert '! echo "$out" | grep -q "My project slug is"' "no slug line when --project omitted"
}

case_invalid_project_slug_rejected() {
  local out rc=0
  out=$(run_install --tool codex --project 'Bad Slug!' 2>&1) || rc=$?
  assert "[ '$rc' != '0' ]" "invalid slug exits non-zero (got $rc)"
  assert 'echo "$out" | grep -q "--project must match"' "error names the constraint"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

test_case "clean install"                    case_clean_install
test_case "re-run idempotent"                case_rerun_idempotent
test_case "append preserves user content"    case_append_preserves_user_content
test_case "uninstall empty removes file"     case_uninstall_empty_removes_file
test_case "uninstall preserves user content" case_uninstall_preserves_user
test_case "--tool all detects codex"         case_tool_all_detects_codex
test_case "--project slug in closing prompt" case_project_slug_appears_in_closing_prompt
test_case "no --project stays generic"       case_no_project_slug_uses_generic_prompt
test_case "--project invalid slug rejected"  case_invalid_project_slug_rejected

echo ""
echo "== summary =="
echo "passed: $PASS"
echo "failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
