#!/usr/bin/env bash
set -euo pipefail

PATCHED="$1"
BASE="$2"
MODULE="$3"

python3 - "$PATCHED" "$BASE" "$MODULE" <<'PY'
import sys, zipfile, io, re, os, json

def read_manifest_strings(b):
    try:
        text = b.decode('utf-16-le', errors='ignore')
        return set(re.findall(r'[\x20-\x7e]{3,}', text))
    except Exception:
        return set()

patched_path, base_path, module_path = sys.argv[1:4]
errors = []

zp = zipfile.ZipFile(patched_path)
patched_entries = set(zp.namelist())
module_zip = zipfile.ZipFile(module_path)

# 1. app package identity still intact in patched manifest
if b'com.instagram.android' not in zp.read('AndroidManifest.xml'):
    errors.append("patched manifest missing 'com.instagram.android' package string")

# 2. origin.apk preserved inside the patch
if 'assets/lspatch/origin.apk' not in patched_entries:
    errors.append("missing assets/lspatch/origin.apk inside patched apk")

# 3. lspatch config sanity
if 'assets/lspatch/config.json' not in patched_entries:
    errors.append("missing assets/lspatch/config.json")
else:
    cfg = json.loads(zp.read('assets/lspatch/config.json'))
    if cfg.get('useManager') is not False:
        errors.append("useManager must be false for embedded modules")
    if int(cfg.get('sigBypassLevel', 0)) < 2:
        errors.append(f"sigBypassLevel too low: {cfg.get('sigBypassLevel')}")

# 4. embedded module apk present and well-formed
mod_assets = [n for n in patched_entries if n.startswith('assets/lspatch/modules/')]
if len(mod_assets) != 1:
    errors.append(f"expected 1 embedded module, got {len(mod_assets)}")
else:
    inner = zipfile.ZipFile(io.BytesIO(zp.read(mod_assets[0])))
    if 'assets/xposed_init' not in inner.namelist():
        errors.append("embedded module has no assets/xposed_init")
    else:
        init = inner.read('assets/xposed_init').decode().strip()
        dexes = [n for n in inner.namelist() if n.endswith('.dex')]
        entrypoint = init.replace('.', '/')
        if not any(entrypoint.encode() in inner.read(d) for d in dexes):
            errors.append(f"module entrypoint {entrypoint} not found in embedded dex")

# 5. loader dex + native lib
if 'assets/lspatch/loader.dex' not in patched_entries:
    errors.append("missing assets/lspatch/loader.dex")
if 'assets/lspatch/so/arm64-v8a/liblspatch.so' not in patched_entries:
    errors.append("missing arm64-v8a liblspatch.so")

# 6. apksigner if available
apksigner = None
for root in (os.environ.get('ANDROID_HOME', ''), os.environ.get('ANDROID_SDK_ROOT', '')):
    if root:
        bt_dir = os.path.join(root, 'build-tools')
        if os.path.isdir(bt_dir):
            for bt in sorted(os.listdir(bt_dir)):
                cand = os.path.join(bt_dir, bt, 'apksigner')
                if os.path.isfile(cand):
                    apksigner = cand
                    break
    if apksigner:
        break
if apksigner:
    import subprocess
    r = subprocess.run([apksigner, 'verify', patched_path], capture_output=True, text=True)
    if r.returncode != 0:
        errors.append(f"apksigner verify failed: {r.stderr.strip()[:200]}")
    else:
        print("  ok  apksigner verify passed")
else:
    print("  skip apksigner not on this machine")

if errors:
    for e in errors:
        print(f"  FAIL {e}")
    sys.exit(1)
print("patched apk deep-verified OK")
PY
