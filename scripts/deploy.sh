#!/bin/sh
# Deploys the project with Swift Cloud.
#
# Usage: scripts/deploy.sh [stage]    (stage defaults to prod)
#
# Run it from a terminal with direnv loaded (see .envrc) so it deploys to the
# sports-home-automation account. Swift Cloud's progress UI needs a real
# terminal; it crashes when the terminal width is 0, such as in CI.
set -eu
cd "$(dirname "$0")/.."
stage="${1:-prod}"

# Swift 6.4's default build system (swiftbuild) writes static Linux products to
# .build/out/Products/Release-staticlinux-aarch64, but Swift Cloud packages each
# Lambda from .build/aarch64-swift-linux-musl/release, where only the deprecated
# native build system writes. Without this link, a deploy builds fresh binaries
# and then uploads whatever stale ones are left at the old path.
legacy_release=.build/aarch64-swift-linux-musl/release
mkdir -p .build/aarch64-swift-linux-musl
if [ -d "$legacy_release" ] && [ ! -L "$legacy_release" ]; then
  rm -rf "$legacy_release"
fi
ln -sfn ../out/Products/Release-staticlinux-aarch64 "$legacy_release"

exec swift run Infra deploy --stage "$stage"
