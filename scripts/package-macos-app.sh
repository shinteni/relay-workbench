#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Relay.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
RUST_TARGET="$ROOT/.tooling/target-relay"
SWIFT_BUILD="$ROOT/.tooling/swift-build"
NODE_BINARY="${RELAY_NODE_PATH:-$(command -v node)}"
NPM_BINARY="${RELAY_NPM_PATH:-$(command -v npm)}"

if [[ ! -x "$NODE_BINARY" ]]; then
    print -u2 "Node.js executable was not found"
    exit 1
fi
if [[ ! -x "$NPM_BINARY" ]]; then
    print -u2 "npm executable was not found"
    exit 1
fi

export CARGO_HOME="$ROOT/.tooling/cargo"
export RUSTUP_HOME="$ROOT/.tooling/rustup"
export CARGO_TARGET_DIR="$RUST_TARGET"
export PATH="$(dirname "$NODE_BINARY"):$CARGO_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export RELAY_NPM_PATH="$NPM_BINARY"

cd "$ROOT"
cargo build --release --workspace
swift build \
    --configuration release \
    --package-path "$ROOT/apps/RelayGUI" \
    --scratch-path "$SWIFT_BUILD"

if [[ "$APP" != "$ROOT/dist/Relay.app" ]]; then
    print -u2 "unexpected app output path"
    exit 1
fi
/bin/rm -rf "$APP"
/bin/mkdir -p "$MACOS" "$RESOURCES/bin" "$RESOURCES/adapters"
/bin/cp "$ROOT/apps/RelayGUI/Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$SWIFT_BUILD/release/RelayGUI" "$MACOS/RelayGUI"
/bin/cp \
    "$ROOT/apps/RelayGUI/Sources/RelayGUI/Resources/protocol-version.txt" \
    "$RESOURCES/protocol-version.txt"
/bin/cp "$RUST_TARGET/release/relayd" "$RESOURCES/bin/relayd"
/bin/cp "$RUST_TARGET/release/relayctl" "$RESOURCES/bin/relayctl"
/bin/cp "$RUST_TARGET/release/codex-adapter" "$RESOURCES/bin/codex-adapter"
/bin/cp "$RUST_TARGET/release/claude-adapter" "$RESOURCES/bin/claude-adapter"
/bin/cp "$RUST_TARGET/release/mix-adapter" "$RESOURCES/bin/mix-adapter"
/bin/cp "$RUST_TARGET/release/generic-adapter" "$RESOURCES/bin/generic-adapter"
/bin/cp "$ROOT/adapters/manifests/"*.json "$RESOURCES/adapters/"
/bin/cp "$NODE_BINARY" "$RESOURCES/bin/node"
"$ROOT/scripts/prepare-mix-runtime.sh" "$RESOURCES/mix-runtime"
/bin/chmod 755 \
    "$MACOS/RelayGUI" \
    "$RESOURCES/bin/relayd" \
    "$RESOURCES/bin/relayctl" \
    "$RESOURCES/bin/codex-adapter" \
    "$RESOURCES/bin/claude-adapter" \
    "$RESOURCES/bin/mix-adapter" \
    "$RESOURCES/bin/generic-adapter" \
    "$RESOURCES/bin/node" \
    "$RESOURCES/mix-runtime/relay-mix.mjs"
/usr/bin/codesign --force --deep --sign - "$APP"

print "$APP"
