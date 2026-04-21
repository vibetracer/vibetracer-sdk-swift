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
PROJECT=""
UNINSTALL=0

usage() {
  cat <<'EOF'
Vibe Tracer Swift skill pack installer.

Usage:
  install.sh [--tool <name>] [--target <path>] [--version <ref>] [--project <slug>] [--uninstall] [--help]

Flags:
  --tool <name>     One of: claude (default), cursor, windsurf, codex, all.
  --target <path>   Custom absolute directory. Mutually exclusive with --tool.
  --version <ref>   Git ref (tag or branch). Defaults to main.
  --project <slug>  Project slug from your dashboard URL. When set, the
                    closing prompt includes it so the agent can build the
                    correct API-key URL without asking which project.
  --uninstall       Remove all vibe-tracer-swift-* skills from the resolved target(s).
  --help            Show this help.

Tool → path:
  claude    ~/.claude/skills
  cursor    ~/.cursor/rules
  windsurf  ~/.codeium/windsurf/rules
  codex     ~/.codex/skills  (also appends a router block to ~/.codex/AGENTS.md)
  all       auto-detects which of the above exist on this machine.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tool) TOOL="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Matches the slug shape produced by the dashboard (`slugify` + 4-hex suffix):
# lowercase alphanumerics and hyphens, starting with an alphanumeric. Length
# bound keeps the echo line tidy and prevents a pathological slug from
# bloating the prompt text that ends up pasted into the agent.
if [ -n "$PROJECT" ]; then
  if ! printf '%s' "$PROJECT" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; then
    echo "error: --project must match [a-z0-9][a-z0-9-]{0,63} (got: $PROJECT)" >&2
    exit 2
  fi
fi

if [ -n "$TOOL" ] && [ -n "$TARGET" ]; then
  echo "error: --tool and --target are mutually exclusive" >&2; exit 2
fi
if [ -z "$TOOL" ] && [ -z "$TARGET" ]; then TOOL="claude"; fi

path_for_tool() {
  case "$1" in
    claude) echo "$HOME/.claude/skills" ;;
    cursor) echo "$HOME/.cursor/rules" ;;
    windsurf) echo "$HOME/.codeium/windsurf/rules" ;;
    codex) echo "$HOME/.codex/skills" ;;
    *) echo "error: unknown tool: $1 (must be one of: claude, cursor, windsurf, codex, all)" >&2; exit 2 ;;
  esac
}

TARGETS=()
if [ -n "$TARGET" ]; then
  TARGETS+=("$TARGET")
elif [ "$TOOL" = "all" ]; then
  [ -d "$HOME/.claude" ] && TARGETS+=("$(path_for_tool claude)")
  [ -d "$HOME/.cursor" ] && TARGETS+=("$(path_for_tool cursor)")
  [ -d "$HOME/.codeium/windsurf" ] && TARGETS+=("$(path_for_tool windsurf)")
  [ -d "$HOME/.codex" ] && TARGETS+=("$(path_for_tool codex)")
  if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "error: --tool all found no known agent-tool directories (~/.claude, ~/.cursor, ~/.codeium/windsurf, ~/.codex)." >&2
    echo "Install one, or pass --tool <name> / --target <path> explicitly." >&2
    exit 1
  fi
else
  case "$TOOL" in claude|cursor|windsurf|codex) ;; *) path_for_tool "$TOOL" >/dev/null ;; esac
  TARGETS+=("$(path_for_tool "$TOOL")")
fi

codex_agents_md_block() {
  cat <<'BLOCK'
<!-- vibetracer:begin -->
<!-- version: v1 -->
## Vibe Tracer (iOS analytics)

When the user is working on a Swift app AND any of:
- mentions Vibe Tracer or `vibetracer-sdk-swift`
- `vibetracer-sdk-swift` appears in Package.swift / Podfile / project
- asks about analytics, event tracking, or user identity

Read the matching file from `~/.codex/skills/` before responding:
- `vibe-tracer-swift-install/SKILL.md` — first-time integration
- `vibe-tracer-swift-events/SKILL.md` — what to track
- `vibe-tracer-swift-identity/SKILL.md` — login/logout, identify()/reset()
- `vibe-tracer-swift-debug/SKILL.md` — events not arriving
- `vibe-tracer-swift-platform-config/SKILL.md` — macOS / Catalyst / Designed-for-iPad

These files are the source of truth. Do not improvise when they apply.
<!-- vibetracer:end -->
BLOCK
}

write_codex_agents_md() {
  local f="$HOME/.codex/AGENTS.md"
  local tmp="$f.vibetracer.tmp"
  mkdir -p "$(dirname "$f")"

  if [ ! -f "$f" ]; then
    codex_agents_md_block > "$f"
    return
  fi

  local begin_n end_n
  begin_n=$(grep -c "^<!-- vibetracer:begin" "$f" || true)
  end_n=$(grep -c "^<!-- vibetracer:end -->" "$f" || true)

  if [ "$begin_n" != "$end_n" ]; then
    echo "error: $f has $begin_n vibetracer begin sentinel(s) and $end_n end sentinel(s)." >&2
    echo "Fix manually (remove any vibetracer:begin .. vibetracer:end block) and re-run." >&2
    exit 1
  fi

  awk '
    /^<!-- vibetracer:begin/ { skip = 1; next }
    /^<!-- vibetracer:end -->/ { skip = 0; next }
    skip { next }
    { out[++n] = $0 }
    END {
      for (i = n; i > 0; i--) if (out[i] ~ /[^[:space:]]/) { last = i; break }
      for (i = 1; i <= last; i++) print out[i]
    }
  ' "$f" > "$tmp"

  if [ -s "$tmp" ]; then
    printf '\n' >> "$tmp"
  fi
  codex_agents_md_block >> "$tmp"
  mv "$tmp" "$f"
}

strip_codex_agents_md() {
  local f="$HOME/.codex/AGENTS.md"
  local tmp="$f.vibetracer.tmp"
  [ -f "$f" ] || return 0

  awk '
    /^<!-- vibetracer:begin/ { skip = 1; next }
    /^<!-- vibetracer:end -->/ { skip = 0; next }
    skip { next }
    { out[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) if (out[i] ~ /[^[:space:]]/) { first = i; break }
      for (i = n; i > 0; i--) if (out[i] ~ /[^[:space:]]/) { last = i; break }
      if (!first) exit 0
      prev_blank = 0
      for (i = first; i <= last; i++) {
        if (out[i] ~ /^[[:space:]]*$/) {
          if (!prev_blank) print ""
          prev_blank = 1
        } else {
          print out[i]
          prev_blank = 0
        }
      }
    }
  ' "$f" > "$tmp"

  if [ ! -s "$tmp" ]; then
    rm -f "$f" "$tmp"
  else
    mv "$tmp" "$f"
  fi
}

for t in "${TARGETS[@]}"; do
  if [ "$UNINSTALL" = "1" ]; then
    for s in "${SKILLS[@]}"; do rm -rf "$t/$s"; done
    if [ "$t" = "$HOME/.codex/skills" ]; then
      strip_codex_agents_md
      echo "✓ Removed Vibe Tracer Swift skills from $t and stripped ~/.codex/AGENTS.md router block"
    else
      echo "✓ Removed Vibe Tracer Swift skills from $t"
    fi
  else
    mkdir -p "$t"
    for s in "${SKILLS[@]}"; do
      url="$BASE_URL/skills/$s/SKILL.md"
      [ -n "$VERSION" ] && url="$url?ref=$VERSION"
      mkdir -p "$t/$s"
      curl -fsSL "$url" -o "$t/$s/SKILL.md"

      # Per-skill colocated scripts. Only vibe-tracer-swift-install has them today.
      # If more skills grow scripts later, extend this block — don't loop over
      # globbed URLs because there's no directory listing on the CDN.
      if [ "$s" = "vibe-tracer-swift-install" ]; then
        script_url="$BASE_URL/skills/$s/scripts/wire-xcode.rb"
        [ -n "$VERSION" ] && script_url="$script_url?ref=$VERSION"
        mkdir -p "$t/$s/scripts"
        curl -fsSL "$script_url" -o "$t/$s/scripts/wire-xcode.rb"
        chmod +x "$t/$s/scripts/wire-xcode.rb"
      fi
    done
    if [ "$t" = "$HOME/.codex/skills" ]; then
      write_codex_agents_md
    fi
    echo "✓ Installed ${#SKILLS[@]} Vibe Tracer Swift skills to $t:"
    for s in "${SKILLS[@]}"; do echo "    $s"; done
    if [ "$t" = "$HOME/.codex/skills" ]; then
      echo "    (also wired ~/.codex/AGENTS.md between vibetracer:* sentinels)"
    fi
    echo ""
    echo "To get started, tell your AI:"
    # We embed the slug in the agent prompt itself — not a separate "API key
    # URL" line — so the dashboard remains the single source of truth for
    # the URL template. The install skill already knows how to map
    # "my project slug is X" → the correct settings URL.
    if [ -n "$PROJECT" ]; then
      echo "    \"Add vibe tracer to my app and help me figure out what to track. My project slug is $PROJECT.\""
    else
      echo "    \"Add vibe tracer to my app and help me figure out what to track\""
    fi
  fi
done
