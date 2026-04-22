#!/usr/bin/env bash
# install-or-upgrade.sh — single entry point for both first-time install and
# in-place upgrade of an integrated VibeTracer SPM dependency.
#
# Contract: deterministic, file-mutation-only. Does NOT run xcodebuild and does
# NOT verify the build — that's the caller's job (the agent invoking this from
# a SKILL.md does the headless build + PlistBuddy assertion, because the build
# environment and simulator preference vary per user).
#
# Branches:
#   - **broken-state** (pbxproj has INFOPLIST_KEY_VibeTracerApiKey but no
#     INFOPLIST_FILE): a previous install hit Xcode's silent-key-drop bug.
#     wire-xcode.rb's new file-based Info.plist provisioning fixes it; we
#     invoke wire-xcode.rb to do the remediation.
#   - **first-time** (no VibeTracer pin in pbxproj): wire-xcode.rb adds the
#     SPM reference, links the product, provisions xcconfig + Info.plist.
#   - **already-current** (Package.resolved at or above sdk-version): no-op.
#   - **drift** (Package.resolved below sdk-version): delete Package.resolved
#     to force re-resolution, run wire-xcode.rb to bump minimumVersion, emit
#     CHANGELOG migration delta. Agent re-resolves via xcodebuild after.
#
# Usage:
#   install-or-upgrade.sh <project-root> <target-name>
#
#   <project-root>  Directory containing exactly one .xcodeproj.
#   <target-name>   The target linking VibeTracer (e.g. DateCalculator).
#
# Safe to call from any vibe-tracer-swift-* skill's drift gate on every
# invocation — short-circuits cleanly when nothing to do.
#
# Never runs destructive git operations. On any failure that leaves the project
# mid-mutation, prints which file was being edited and exits non-zero — the
# agent diagnoses from there, asks the user to inspect, and re-runs after fix.

set -euo pipefail

[ $# -eq 2 ] || { echo "usage: install-or-upgrade.sh <project-root> <target-name>" >&2; exit 2; }

proj_root="$1"
target="$2"
skill_dir="$(cd "$(dirname "$0")/.." && pwd)"   # .../vibe-tracer-swift-install
skill_md="$skill_dir/SKILL.md"
changelog="$skill_dir/CHANGELOG.md"
wire_script="$skill_dir/scripts/wire-xcode.rb"

[ -f "$skill_md" ]    || { echo "error: missing $skill_md — reinstall the skill pack" >&2; exit 2; }
[ -f "$wire_script" ] || { echo "error: missing $wire_script — reinstall the skill pack" >&2; exit 2; }
[ -d "$proj_root" ]   || { echo "error: project-root not a directory: $proj_root" >&2; exit 2; }

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
pbxproj="$xcodeproj/project.pbxproj"

# ─── 3. Detect known-broken state ────────────────────────────────────────────
# Old wire-xcode.rb set INFOPLIST_KEY_VibeTracerApiKey on the target's build
# settings. Xcode's auto-Info.plist generator silently drops it because
# VibeTracerApiKey isn't on Apple's recognized-keys allowlist. Result at
# runtime: configure(apiKey: "") → every event dropped client-side.
#
# The reliable signature: pbxproj contains INFOPLIST_KEY_VibeTracerApiKey AND
# does not contain INFOPLIST_FILE. (Presence of INFOPLIST_FILE means a previous
# remediation already ran or the user hand-fixed it.)
broken_state=0
if grep -q 'INFOPLIST_KEY_VibeTracerApiKey' "$pbxproj" 2>/dev/null \
   && ! grep -q 'INFOPLIST_FILE' "$pbxproj" 2>/dev/null; then
  broken_state=1
fi

# ─── 4. Check whether VibeTracer is in the pbxproj at all ────────────────────
# Match the same key wire-xcode.rb uses to identify our package reference.
has_vibetracer=0
if grep -q 'repositoryURL = "*https://github.com/vibetracer/vibetracer-sdk-swift' "$pbxproj" 2>/dev/null \
   || grep -q 'repositoryURL = https://github.com/vibetracer/vibetracer-sdk-swift' "$pbxproj" 2>/dev/null; then
  has_vibetracer=1
fi

# ─── 5. Locate Package.resolved(s) and read the VibeTracer pin ───────────────
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

# ─── 6. Branch ───────────────────────────────────────────────────────────────
# Order matters:
#   broken-state takes priority — fix the silent-key-drop before anything else.
#   no VibeTracer in pbxproj → first-time install path.
#   pinned >= current → already-current short-circuit.
#   pinned < current → upgrade path (drift).
#   no Package.resolved but VibeTracer is in pbxproj → first build never ran;
#     wire-xcode.rb is a no-op since version constraint is already correct.

semver_lt() {
  # returns 0 (true) if $1 < $2, else 1.
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

if [ "$broken_state" = "1" ]; then
  echo "→ Detected the silent-key-drop install bug (INFOPLIST_KEY_VibeTracerApiKey set, no INFOPLIST_FILE)."
  echo "  Re-running wire-xcode.rb to provision a file-based Info.plist."
  if ! ruby "$wire_script" "$xcodeproj" "$target" "$current"; then
    echo ""
    echo "✗ wire-xcode.rb failed during broken-state remediation." >&2
    echo "  Inspect: $pbxproj" >&2
    echo "  And:     $proj_root/$target/Info.plist (if present)" >&2
    exit 1
  fi
  echo ""
  echo "→ Broken state remediated. The agent must now run a clean build to"
  echo "  confirm the fix took (see SKILL.md → Verifying the build)."
  exit 0
fi

if [ "$has_vibetracer" = "0" ]; then
  echo "→ VibeTracer is not yet integrated into $(basename "$xcodeproj")."
  echo "  Running wire-xcode.rb for first-time install."
  if ! ruby "$wire_script" "$xcodeproj" "$target" "$current"; then
    echo ""
    echo "✗ wire-xcode.rb failed during first-time install." >&2
    echo "  Inspect: $pbxproj" >&2
    exit 1
  fi
  echo ""
  echo "→ First-time install complete. The agent must run a clean build to"
  echo "  confirm (see SKILL.md → Verifying the build)."
  exit 0
fi

# Past this point, VibeTracer IS integrated. Decide based on pinned version.

if [ -z "$pinned" ]; then
  echo "✓ VibeTracer is integrated but no Package.resolved yet (first build hasn't run)."
  echo "  Nothing to do — first build will fetch the current minimumVersion fresh."
  exit 0
fi

if ! semver_lt "$pinned" "$current"; then
  echo "✓ Already on VibeTracer $pinned (skill sdk-version $current)"
  exit 0
fi

# ─── Drift detected: upgrade path ────────────────────────────────────────────
echo "→ Upgrading VibeTracer: $pinned → $current"

# Delete every Package.resolved referencing VibeTracer so SPM unambiguously
# re-resolves. Editing pbxproj's minimumVersion *should* trigger re-resolution
# (since the pinned version no longer satisfies the new lower bound), but Xcode
# doesn't always notice until prompted.
for p in "${resolved_paths[@]}"; do
  rm -f "$p"
  echo "  removed $p"
done

# Bump pbxproj via wire-xcode.rb (idempotent on the upgrade branch).
if ! ruby "$wire_script" "$xcodeproj" "$target" "$current"; then
  echo ""
  echo "✗ wire-xcode.rb failed during upgrade." >&2
  echo "  Inspect: $pbxproj" >&2
  echo "  And:     $proj_root/$target/Info.plist" >&2
  exit 1
fi

echo ""
echo "→ pbxproj bumped. The agent must now:"
echo "  1. Trigger SPM re-resolution (xcodebuild -resolvePackageDependencies, or"
echo "     have the user open Xcode → File → Packages → Resolve Package Versions)."
echo "  2. Run a clean build to confirm (see SKILL.md → Verifying the build)."

# ─── CHANGELOG delta — every `### Breaking — API` section in (pinned, current] ─
# The agent reads this to know what call-site migrations are needed. If every
# breaking section is "None.", this emits a tight summary and the agent can
# proceed with the original task without asking the user to change code.
if [ ! -f "$changelog" ]; then
  echo ""
  echo "⚠ no CHANGELOG.md in the skill pack — skipping migration notes."
  echo "  Re-run the bootstrapper to fetch the current CHANGELOG."
  exit 0
fi

echo ""
echo "── Migration notes (CHANGELOG delta ${pinned} → ${current}) ──"

# Semver-aware filtering: for each `## [X.Y.Z]` section where pinned < X.Y.Z ≤ current,
# extract its `### Breaking — API` body. macOS ships python3 by default (Command
# Line Tools). If it's somehow missing, fall back to awk that prints every
# Breaking — API section and tells the agent to filter mentally. The regex
# explicitly matches `[X.Y.Z]` shape, so non-semver entries (e.g. skill-pack
# notes headed `[skill-pack-YYYY-MM-DD]`) are correctly ignored — they don't
# represent SDK API changes.
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
