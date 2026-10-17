#!/usr/bin/env bash
set -euo pipefail

# Patch Instagram with InstaEclipse using LSPatch CLI.
# Args:
#   $1 = base Instagram APK path
#   $2 = module APK path
#   $3 = output dir
#   $4 = instagram version (optional, for logging)

IG_APK="$1"
MODULE_APK="$2"
OUT_DIR="$3"
IG_VERSION="${4:-unknown}"

test -f "$IG_APK"
test -f "$MODULE_APK"
mkdir -p "$OUT_DIR"

echo "[patch] Instagram version: ${IG_VERSION}"
echo "[patch] base apk: ${IG_APK} ($(du -h "$IG_APK" | cut -f1))"
echo "[patch] module apk: ${MODULE_APK}"

# LSPatch needs a Java 17 runtime (provided by setup-java in CI)
java -version 2>&1 | head -1

java -jar lspatch.jar "$IG_APK" \
  -m "$MODULE_APK" \
  --injectdex \
  -l 2 \
  -o "$OUT_DIR" \
  -f \
  -v

echo "[patch] outputs:"
ls -la "$OUT_DIR"

# Verify the patched artifact exposes the LSPosed module entry
PATCHED="$(find "$OUT_DIR" -name '*.apk' -type f | head -1)"
test -n "$PATCHED"
echo "[patch] verifying patched apk: $PATCHED"
echo "[patch] sha256: $(sha256sum "$PATCHED" | cut -d' ' -f1)"

# LSPatch embeds the module as an asset; check for the xposed init marker
if unzip -l "$PATCHED" | grep -q "assets/xposed_init"; then
  echo "[patch] xposed_init entry present in patched apk"
else
  echo "[patch] WARNING: xposed_init not found in patched apk"
fi

# Verify signature (LSPatch re-signs with its built-in keystore)
if command -v apksigner >/dev/null 2>&1; then
  apksigner verify -v "$PATCHED" | head -8 || true
else
  echo "[patch] apksigner not available; skipping signature verification"
fi
