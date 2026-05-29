#!/bin/bash
#
# init-git.sh — initialize the local repo and push it to the existing GitHub
# remote at github.com/Xpycode/Manifest.
#
# The remote currently has only an auto-generated "Initial commit". This script
# replaces it with the real project history. Review the staged file list it
# prints BEFORE it pushes — make sure no build artifacts or secrets slipped past
# .gitignore.
#
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

REMOTE="https://github.com/Xpycode/Manifest.git"

if [[ -d .git ]]; then
    echo "==> .git already exists; skipping init"
else
    echo "==> git init"
    git init -b main
fi

echo "==> Staging files (respecting .gitignore)"
git add -A

echo ""
echo "==> Files that WILL be committed:"
git status --short
echo ""
echo "==> Sanity check — these should NOT appear above:"
echo "    DerivedData/, *.app, *.dmg, .claude/, AuthKey_*.p8, *.p12"
echo ""
read -r -p "Proceed with commit + push (overwrites remote 'Initial commit')? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }

git commit -m "Manifest v1.0.0 — floating macOS input HUD

Floating NSPanel HUD that surfaces keyboard, mouse, scroll, and app-switch
events with per-event frontmost-app attribution and local + UTC timestamps.
Swift 6 strict-concurrency CGEventTap pipeline, AX enrichment, three placement
modes, CSV/JSON export, local-only JSONL log, secure-input dropping.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"

if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE"
else
    git remote add origin "$REMOTE"
fi

echo "==> Pushing to $REMOTE (force — replaces the stub initial commit)"
git push --force -u origin main

echo ""
echo "✅ Pushed. View: https://github.com/Xpycode/Manifest"
