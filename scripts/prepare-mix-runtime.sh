#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/adapters/mix-runtime/vendor"
OUTPUT="${1:-}"
NPM_BINARY="${RELAY_NPM_PATH:-$(command -v npm || true)}"

if [[ -z "$OUTPUT" ]]; then
    print -u2 "usage: prepare-mix-runtime.sh OUTPUT_DIRECTORY"
    exit 1
fi

case "$OUTPUT" in
    "$ROOT"/.tooling/*|"$ROOT"/dist/Relay.app/Contents/Resources/mix-runtime)
        ;;
    *)
        print -u2 "refusing to replace unexpected MIX runtime path: $OUTPUT"
        exit 1
        ;;
esac

if [[ ! -x "$NPM_BINARY" ]]; then
    print -u2 "npm executable was not found"
    exit 1
fi

for required in \
    "$SOURCE/package.json" \
    "$SOURCE/package-lock.json" \
    "$SOURCE/bin/dual-claude.mjs" \
    "$SOURCE/prompts/dual-consensus.md" \
    "$SOURCE/src/codex-peer.mjs"; do
    if [[ ! -f "$required" ]]; then
        print -u2 "missing MIX runtime source: $required"
        exit 1
    fi
done

(
    cd "$SOURCE"
    "$NPM_BINARY" ci --ignore-scripts --no-audit --no-fund
)

for required in \
    "$SOURCE/node_modules/@modelcontextprotocol/sdk/package.json" \
    "$SOURCE/node_modules/@openai/codex-sdk/package.json"; do
    if [[ ! -f "$required" ]]; then
        print -u2 "missing MIX runtime dependency: $required"
        exit 1
    fi
done

/bin/rm -rf "$OUTPUT"
/bin/mkdir -p "$OUTPUT/bin" "$OUTPUT/prompts" "$OUTPUT/src" "$OUTPUT/node_modules"
/bin/cp "$SOURCE/bin/dual-claude.mjs" "$OUTPUT/bin/dual-claude.mjs"
/bin/cp "$SOURCE/prompts/dual-consensus.md" "$OUTPUT/prompts/dual-consensus.md"
/bin/cp "$SOURCE"/src/*.mjs "$OUTPUT/src/"
/bin/cp "$ROOT/adapters/mix-runtime/relay-mix.mjs" "$OUTPUT/relay-mix.mjs"
/bin/cp "$SOURCE/package.json" "$OUTPUT/package.json"
/usr/bin/rsync -a \
    --exclude '@openai/codex-darwin-arm64/' \
    --exclude '@openai/codex-darwin-x64/' \
    --exclude '@openai/codex-linux-arm64/' \
    --exclude '@openai/codex-linux-x64/' \
    --exclude '@openai/codex-win32-arm64/' \
    --exclude '@openai/codex-win32-x64/' \
    "$SOURCE/node_modules/" "$OUTPUT/node_modules/"

if ! /usr/bin/grep -q 'codexPathOverride: process.env.RELAY_CODEX_PATH' "$OUTPUT/src/codex-peer.mjs"; then
    print -u2 "failed to configure packaged Codex CLI override"
    exit 1
fi

/bin/chmod 755 "$OUTPUT/relay-mix.mjs" "$OUTPUT/bin/dual-claude.mjs"
