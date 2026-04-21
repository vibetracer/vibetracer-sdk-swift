#!/usr/bin/env bash
# Fail the commit if any skills/vibe-tracer-swift-*/SKILL.md is staged
# without its `version:` frontmatter line matching today's (UTC) date.
#
# Why: the update-notifier feature depends on agents comparing a local
# `version: YYYY-MM-DD` to the published one. A SKILL.md edit that doesn't
# bump the date means users never get notified about the change. The hook
# makes the discipline automatic — you can't forget, because the commit
# won't land.
#
# Scope: only SKILL.md files under skills/vibe-tracer-swift-*/ are checked.
# Scripts, docs, and test files are ignored.

set -euo pipefail

today="$(date -u +%Y-%m-%d)"
fail=0

# diff-filter=ACMR = added, copied, modified, renamed — every file state
# where the committed content is new. Deletions are ignored (no content
# to check).
while IFS= read -r file; do
  [ -z "$file" ] && continue

  # Read the *staged* version, not the working-tree version. This matters
  # when you `git add -p` partial hunks: the hook checks what's actually
  # going into the commit.
  staged_version="$(git show ":$file" | awk '/^version: / {print $2; exit}')"

  if [ -z "$staged_version" ]; then
    echo "error: $file is missing a 'version:' frontmatter line." >&2
    echo "  Add: version: $today" >&2
    fail=1
    continue
  fi

  if [ "$staged_version" != "$today" ]; then
    echo "error: $file has version '$staged_version' but today is $today." >&2
    echo "  Bump the frontmatter:" >&2
    echo "    sed -i '' 's/^version: .*/version: $today/' '$file'  # macOS" >&2
    echo "    sed -i    's/^version: .*/version: $today/' '$file'  # Linux" >&2
    echo "  Then: git add '$file' && git commit" >&2
    fail=1
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR | grep -E '^skills/vibe-tracer-swift-[^/]+/SKILL\.md$' || true)

exit $fail
