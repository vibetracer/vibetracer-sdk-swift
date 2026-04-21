#!/usr/bin/env bash
# Vibe Tracer Swift skill pack installer.
# Source: https://github.com/vibetracer/vibetracer-sdk-swift/blob/main/skills/install.sh
# All downloads go through https://vibetracer.xyz/sdk/swift/... so China users work.
set -euo pipefail

SKILLS=(vibe-tracer-swift-install vibe-tracer-swift-events vibe-tracer-swift-identity vibe-tracer-swift-debug vibe-tracer-swift-platform-config)
BASE_URL="https://vibetracer.xyz/sdk/swift"

TOOL=""
TARGET=""
VERSION=""
UNINSTALL=0

usage() {
  cat <<'EOF'
Vibe Tracer Swift skill pack installer.

Usage:
  install.sh [--tool <name>] [--target <path>] [--version <ref>] [--uninstall] [--help]

Flags:
  --tool <name>     One of: claude (default), cursor, windsurf, all.
  --target <path>   Custom absolute directory. Mutually exclusive with --tool.
  --version <ref>   Git ref (tag or branch). Defaults to main.
  --uninstall       Remove all vibe-tracer-swift-* skills from the resolved target(s).
  --help            Show this help.

Tool → path:
  claude    ~/.claude/skills
  cursor    ~/.cursor/rules
  windsurf  ~/.codeium/windsurf/rules
  all       auto-detects which of the above exist on this machine.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tool) TOOL="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$TOOL" ] && [ -n "$TARGET" ]; then
  echo "error: --tool and --target are mutually exclusive" >&2; exit 2
fi
if [ -z "$TOOL" ] && [ -z "$TARGET" ]; then TOOL="claude"; fi

path_for_tool() {
  case "$1" in
    claude) echo "$HOME/.claude/skills" ;;
    cursor) echo "$HOME/.cursor/rules" ;;
    windsurf) echo "$HOME/.codeium/windsurf/rules" ;;
    *) echo "error: unknown tool: $1 (must be one of: claude, cursor, windsurf, all)" >&2; exit 2 ;;
  esac
}

TARGETS=()
if [ -n "$TARGET" ]; then
  TARGETS+=("$TARGET")
elif [ "$TOOL" = "all" ]; then
  [ -d "$HOME/.claude" ] && TARGETS+=("$(path_for_tool claude)")
  [ -d "$HOME/.cursor" ] && TARGETS+=("$(path_for_tool cursor)")
  [ -d "$HOME/.codeium/windsurf" ] && TARGETS+=("$(path_for_tool windsurf)")
  if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "error: --tool all found no known agent-tool directories (~/.claude, ~/.cursor, ~/.codeium/windsurf)." >&2
    echo "Install one, or pass --tool <name> / --target <path> explicitly." >&2
    exit 1
  fi
else
  case "$TOOL" in claude|cursor|windsurf) ;; *) path_for_tool "$TOOL" >/dev/null ;; esac
  TARGETS+=("$(path_for_tool "$TOOL")")
fi

for t in "${TARGETS[@]}"; do
  if [ "$UNINSTALL" = "1" ]; then
    for s in "${SKILLS[@]}"; do rm -rf "$t/$s"; done
    echo "✓ Removed Vibe Tracer Swift skills from $t"
  else
    mkdir -p "$t"
    for s in "${SKILLS[@]}"; do
      url="$BASE_URL/skills/$s/SKILL.md"
      [ -n "$VERSION" ] && url="$url?ref=$VERSION"
      mkdir -p "$t/$s"
      curl -fsSL "$url" -o "$t/$s/SKILL.md"
    done
    echo "✓ Installed ${#SKILLS[@]} Vibe Tracer Swift skills to $t:"
    for s in "${SKILLS[@]}"; do echo "    $s"; done
    echo ""
    echo "To get started, tell your AI:"
    echo "    \"add vibe tracer event tracking to my app\""
  fi
done
