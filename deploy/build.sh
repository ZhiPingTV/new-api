#!/usr/bin/env bash
#
# Build a self-contained linux/amd64 new-api binary on your local machine.
#
# new-api embeds BOTH frontends (web/default/dist and web/classic/dist) via
# //go:embed, so both must be built before `go build`. The SQLite driver
# (github.com/glebarez/sqlite) is pure Go, so we cross-compile with
# CGO_ENABLED=0 — no C toolchain needed.
#
# Output: ./build/new-api-linux-amd64

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(cat VERSION 2>/dev/null || echo dev)"

export PATH="$HOME/.bun/bin:$PATH"
command -v bun >/dev/null || { echo "bun not found; install from https://bun.sh"; exit 1; }

echo "==> building default frontend"
( cd web/default && bun install && \
  DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION="$VERSION" bun run build )

echo "==> building classic frontend"
( cd web/classic && bun install && \
  VITE_REACT_APP_VERSION="$VERSION" bun run build )

echo "==> cross-compiling backend (linux/amd64, CGO disabled)"
mkdir -p build
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -ldflags "-s -w -X 'github.com/QuantumNous/new-api/common.Version=${VERSION}'" \
  -o build/new-api-linux-amd64 .

echo "==> done: $ROOT/build/new-api-linux-amd64"
ls -lh build/new-api-linux-amd64
