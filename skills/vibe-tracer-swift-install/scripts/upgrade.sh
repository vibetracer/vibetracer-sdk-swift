#!/usr/bin/env bash
# upgrade.sh — bump an already-integrated VibeTracer SPM pin to the version
# declared by the sibling SKILL.md's `sdk-version` frontmatter.
#
# Contract: idempotent. If the project is already at or above that version,
# prints "✓ Already on …" and exits 0. Safe to call from any vibe-tracer-swift-*
# skill's drift gate on every invocation.
#
# Usage:
#   upgrade.sh <project-root> <target-name>
#
#   <project-root>  Directory containing exactly one .xcodeproj (the consuming app).
#   <target-name>   The target linking VibeTracer. wire-xcode.rb requires it even
#                   on an upgrade — we reuse the same script, same signature.
#
# On drift detected:
#   1. Delete every Package.resolved that pins VibeTracer below <current>
#      (both <proj>.xcodeproj/... and <proj>.xcworkspace/... paths).
#   2. Run wire-xcode.rb with <current>; it's idempotent and bumps minimumVersion.
#   3. Best-effort xcodebuild -resolvePackageDependencies against the first
#      shared scheme. If that fails (no shared scheme, network, etc.), print
#      a one-line fallback asking the user to open Xcode manually.
#   4. Parse CHANGELOG.md (shipped alongside this script in the pack) for every
#      `### Breaking — API` section between (pinned, current] and emit it so
#      the agent can walk the user through migrations.

set -euo pipefail

[ $# -eq 2 ] || { echo "usage: upgrade.sh <project-root> <target-name>" >&2; exit 2; }

proj_root="$1"
target="$2"
skill_dir="$(cd "$(dirname "$0")/.." && pwd)"   # .../vibe-tracer-swift-install
skill_md="$skill_dir/SKILL.md"
changelog="$skill_dir/CHANGELOG.md"
wire_script="$skill_dir/scripts/wire-xcode.rb"

[ -f "$skill_md" ]     || { echo "error: missing $skill_md — reinstall the skill pack" >&2; exit 2; }
[ -f "$wire_script" ]  || { echo "error: missing $wire_script — reinstall the skill pack" >&2; exit 2; }
[ -d "$proj_root" ]    || { echo "error: project-root not a directory: $proj_root" >&2; exit 2; }

# ─── 1. Read target version from install skill's frontmatter ─────────────────
current=$(awk -F': *' '/^sdk-version:/ {print $2; exit}' "$skill_md")
[ -n "$current" ] || { echo "error: no sdk-version in $skill_md" >&2; exit 2; }

# ─── 2. Find exactly one .xcodeproj ──────────────────────────────────────────
# Depth-limited so we don't descend into Carthage/Pods/DerivedData caches.
xcodeprojs=$(find "$proj_root" -maxdepth 3 -name "*.xcodeproj" -type d \
  -not -path "*/Pods/*" -not -path "*/Carthage/*" -not -path "*/DerivedData/*" 2>/dev/null)
n=$(printf '%s\n' "$xcodeprojs" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  echo "error: no .xcodeproj under $proj_root" >&2
  exit 2
elif [ "$n" -gt 1 ]; then
  echo "error: multiple .xcodeproj under $proj_root — pass the specific project root:" >&2
  printf '  %s\n' $xcodeprojs >&2
  exit 2
fi
xcodeproj="$xcodeprojs"

# ─── 3. Locate Package.resolved(s) and read the VibeTracer pin ───────────────
# Xcode writes either v1 (object.pins[].package) or v2/v3 (pins[].identity)
# schema. We handle both. The file lives under project.xcworkspace (for a bare
# .xcodeproj) OR under the user's outer .xcworkspace if they have one.
resolved_paths=()
p1="$xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[ -f "$p1" ] && resolved_paths+=("$p1")
while IFS= read -r p2; do
  [ -f "$p2" ] && resolved_paths+=("$p2")
done < <(find "$proj_root" -maxdepth 3 -name "Package.resolved" -path "*.xcworkspace/*" 2>/dev/null)

pinned=""
# macOS bash 3.x: `${arr[@]}` trips `set -u` when the array is empty.
# The `+` expansion expands to nothing if the array isn't set or is empty,
# and to the elements otherwise.
for p in ${resolved_paths[@]+"${resolved_paths[@]}"}; do
  # Two passes — one for v2/v3 schema (`"identity" : "vibetracer-sdk-swift"`),
  # one for v1 (`"package" : "VibeTracer"`). Within each, range from the matching
  # line to the next `}` covers the state object containing `"version"`. Two
  # separate gsubs (not alternation with `|`) — BSD awk on macOS strips too
  # eagerly when the alternation contains `.*"`, returning empty.
  v=$(awk '
    /"identity" *: *"vibetracer-sdk-swift"/,/}/ {
      if (match($0, /"version" *: *"[^"]+"/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/.*"version" *: *"/, "", s)
        gsub(/".*/, "", s)
        print s; exit
      }
    }
    /"package" *: *"VibeTracer"/,/}/ {
      if (match($0, /"version" *: *"[^"]+"/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/.*"version" *: *"/, "", s)
        gsub(/".*/, "", s)
        print s; exit
      }
    }
  ' "$p" 2>/dev/null | head -1)
  if [ -n "$v" ]; then
    pinned="$v"
    break
  fi
done

# ─── 4. Semver compare (sort -V). Short-circuit if not behind. ───────────────
# sort -V is available on macOS by default and correct for flat X.Y.Z.
# Pre-release tags (e.g. 2.2.0-beta.1) are out of scope — the SDK ships X.Y.Z.
semver_lt() {
  # returns 0 (true) if $1 < $2, else 1.
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

if [ -z "$pinned" ]; then
  # Either no Package.resolved yet (SPM added but never built) or VibeTracer
  # isn't linked. Drift is undefined — let the caller (the first-time install
  # path, or a "you integrated but never built" user) handle it. Exit clean.
  echo "✓ No VibeTracer pin found in Package.resolved — nothing to upgrade"
  exit 0
fi

if ! semver_lt "$pinned" "$current"; then
  echo "✓ Already on VibeTracer $pinned (skill sdk-version $current)"
  exit 0
fi

echo "→ Upgrading VibeTracer: $pinned → $current"

# ─── 5. Delete Package.resolved(s) to force SPM to re-resolve ────────────────
# Editing pbxproj's minimumVersion alone is *supposed* to trigger re-resolution
# (since the pinned version no longer satisfies the new lower bound), but Xcode
# doesn't always notice until the user explicitly resolves. Deleting the file
# makes re-resolution unambiguous.
for p in "${resolved_paths[@]}"; do
  rm -f "$p"
  echo "  removed $p"
done

# ─── 6. Bump pbxproj via wire-xcode.rb (idempotent upgrade branch) ───────────
if ! ruby "$wire_script" "$xcodeproj" "$target" "$current"; then
  echo ""
  echo "⚠ wire-xcode.rb failed. Rollback with:" >&2
  echo "    git -C $proj_root checkout $(basename "$xcodeproj")/project.pbxproj" >&2
  exit 1
fi

# ─── 7. Best-effort xcodebuild -resolvePackageDependencies ───────────────────
# Needs a shared scheme. If there's none, or if xcodebuild fails for any other
# reason, fall back to a one-liner nudge — user can do the same thing via Xcode
# menu File → Packages → Resolve Package Versions.
scheme=$(xcodebuild -project "$xcodeproj" -list 2>/dev/null \
  | awk '/Schemes:/{f=1; next} f && NF{sub(/^[[:space:]]+/,""); print; exit}' \
  || true)
if [ -n "$scheme" ]; then
  if xcodebuild -project "$xcodeproj" -scheme "$scheme" \
       -resolvePackageDependencies >/dev/null 2>&1; then
    echo "  re-resolved via xcodebuild (scheme: $scheme)"
  else
    echo "⚠ xcodebuild -resolvePackageDependencies failed. In Xcode:"
    echo "    File → Packages → Resolve Package Versions"
  fi
else
  echo "⚠ no shared scheme found for xcodebuild. In Xcode:"
  echo "    File → Packages → Resolve Package Versions"
fi

# ─── 8. Emit CHANGELOG delta — every `### Breaking — API` section in (pinned, current] ─
# The agent reads this to know what call-site migrations are needed. If every
# breaking section is "None.", this emits a tight summary and the agent can
# proceed with the original task without asking the user to change code.
if [ ! -f "$changelog" ]; then
  echo ""
  echo "⚠ no CHANGELOG.md in the skill pack — skipping migration notes."
  echo "  Re-run install.sh to get the current CHANGELOG."
  exit 0
fi

echo ""
echo "── Migration notes (CHANGELOG delta ${pinned} → ${current}) ──"

# Semver-aware filtering: for each `## [X.Y.Z]` section where pinned < X.Y.Z ≤ current,
# extract its `### Breaking — API` body. macOS ships python3 by default (Command
# Line Tools). If it's somehow missing, fall back to awk that prints every
# Breaking — API section and tells the agent to filter mentally.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$changelog" "$pinned" "$current" <<'PY'
import re, sys

path, lo, hi = sys.argv[1], sys.argv[2], sys.argv[3]

def vkey(v):
    return tuple(int(x) for x in v.split("."))

with open(path) as f:
    text = f.read()

sections = re.split(r'(?m)^(## \[\d+\.\d+\.\d+\].*)$', text)
pairs = list(zip(sections[1::2], sections[2::2]))

lo_k, hi_k = vkey(lo), vkey(hi)
any_breaking = False
saw_any = False

for header, body in pairs:
    m = re.search(r'\[(\d+\.\d+\.\d+)\]', header)
    if not m: continue
    v = m.group(1)
    if not (lo_k < vkey(v) <= hi_k): continue
    saw_any = True
    bm = re.search(r'(?m)^### Breaking — API\s*$\n(.*?)(?=^### |^## |\Z)',
                   body, re.DOTALL)
    if not bm:
        print(f"\n{v}: (no `### Breaking — API` section — assume none)")
        continue
    content = bm.group(1).strip()
    print(f"\n{v}:")
    print(content)
    if content.lower() != "none.":
        any_breaking = True

if not saw_any:
    print("\n(no CHANGELOG entries in this delta)")
elif any_breaking:
    print("\n→ Breaking changes detected. Apply the migrations above before continuing.")
else:
    print("\n→ All breaking sections are `None.` — no call-site migrations needed.")
PY
else
  echo "(python3 unavailable — dumping all Breaking — API sections; agent should filter to versions > $pinned)"
  awk '
    /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ { hdr=$0; inblk=0; next }
    /^### Breaking — API$/ { inblk=1; print ""; print hdr; print $0; next }
    inblk && (/^### / || /^## /) { inblk=0 }
    inblk { print }
  ' "$changelog"
fi
