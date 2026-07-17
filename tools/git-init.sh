#!/usr/bin/env bash
# Initialize git for wand-term and make the first commits.
# Run this from a native filesystem — the /mnt/linux_share FUSE mount rejects the
# chmod operations git needs. Either copy the project to a local disk first, or run
# this inside an environment where chmod works.
set -euo pipefail

cd "$(dirname "$0")/.."

git init -b master
git add -A
git commit -m "feat: wand-term scaffold + P0/P1 (wand-agent WebSocket terminal)

P0: import libghostty-ohos base, rename example module to entry, app identity.
P1: TerminalDriver abstraction, Utf8Framer, WandUrl, Backoff, WandWebSocketDriver,
TerminalSession wiring, wand-agent connect screen.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"

echo "Done. Review with: git log --stat"
