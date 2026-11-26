#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift_bin="${SWIFT_BIN:-swift}"
wasm_sdk="${SWIFT_WASM_SDK:-}"
if [[ -z "$wasm_sdk" ]]; then
  wasm_sdk="$("$swift_bin" sdk list | grep -E '_wasm$' | head -n 1 || true)"
fi
if [[ -z "$wasm_sdk" ]]; then
  echo "Install the matching Swift SDK for WebAssembly before building." >&2
  exit 1
fi

wasi_shim=node_modules/@bjorn3/browser_wasi_shim
if [[ ! -f "$wasi_shim/dist/index.js" ]]; then
  echo "Run npm ci to install the pinned browser WASI runtime." >&2
  exit 1
fi

runtime=".build/plugins/PackageToJS/outputs/Package"
SWIFTWASM_BUILD=1 "$swift_bin" package --swift-sdk "$wasm_sdk" --only-use-versions-from-resolved-file \
  js --product MunchiesApp --configuration release --no-optimize

stage="$(mktemp -d .build/munchies-dist.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
cp -R public/. "$stage/"
mkdir -p "$stage/runtime/platforms" "$stage/runtime/wasi"
cp "$runtime/MunchiesApp.wasm" "$stage/munchies.wasm"
cp "$runtime/"{index,instantiate,runtime}.js "$stage/runtime/"
cp "$runtime/platforms/browser.js" "$stage/runtime/platforms/"
cp "$wasi_shim/dist/"*.js "$stage/runtime/wasi/"
cp "$wasi_shim/"LICENSE-* "$stage/runtime/wasi/"

node scripts/prepare-pages.mjs "$stage"
rm -rf dist
mv "$stage" dist
echo "Built the Munchies PWA in dist/"
