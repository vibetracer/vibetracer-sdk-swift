#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "usage: $0 <version>  e.g. $0 1.1.0"
  exit 1
fi

VERSION="$1"
TAG="v$VERSION"

# Pre-flight: clean tree
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree not clean — commit or stash changes first"
  git status --short
  exit 1
fi

# Pre-flight: tag doesn't already exist
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists"
  exit 1
fi

# Pre-flight: tests pass
echo "→ Running swift test"
swift test

# Bump podspec version to match $VERSION (skip if already matches).
# Why: SPM users get whatever git tag we push, but CocoaPods users get
# whatever version is in the podspec at the tagged commit. If these
# drift, `pod install` gives a different version than Package.swift users.
current_podspec_version=$(grep -E "^[[:space:]]*s\.version[[:space:]]*=" VibeTracer.podspec | sed -E "s/.*'([^']+)'.*/\1/")
if [ "$current_podspec_version" != "$VERSION" ]; then
  echo "→ Bumping VibeTracer.podspec: $current_podspec_version → $VERSION"
  sed -i '' -E "s/^([[:space:]]*s\.version[[:space:]]*=[[:space:]]*)'[^']*'/\1'$VERSION'/" VibeTracer.podspec
  new_podspec_version=$(grep -E "^[[:space:]]*s\.version[[:space:]]*=" VibeTracer.podspec | sed -E "s/.*'([^']+)'.*/\1/")
  if [ "$new_podspec_version" != "$VERSION" ]; then
    echo "error: podspec bump failed — sed produced version '$new_podspec_version', expected '$VERSION'"
    exit 1
  fi
  git add VibeTracer.podspec
  git commit -m "chore: bump podspec to $VERSION"
  echo "→ Pushing podspec bump to origin"
  git push origin HEAD
else
  echo "→ Podspec already at $VERSION, skipping bump"
fi

# Tag + push to origin
echo "→ Tagging $TAG"
git tag -a "$TAG" -m "Release $VERSION"
git push origin "$TAG"

echo "✓ Released $TAG to GitHub."
