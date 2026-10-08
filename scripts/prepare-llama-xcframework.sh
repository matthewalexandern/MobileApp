#!/usr/bin/env bash
# Developer-only preparation. This script is never included in the iOS app.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: scripts/prepare-llama-xcframework.sh"
    echo "Builds the reviewed llama.cpp pin using its unmodified Apple XCFramework script."
    echo "Requires macOS, full Xcode with iOS/macOS/visionOS/tvOS SDKs, CMake >= 3.28 and Python 3."
    exit 0
fi
if [[ "$#" -ne 0 ]]; then
    echo "Unsupported argument. Use --help for requirements." >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Apple XCFramework preparation requires macOS and full Xcode; no build was attempted." >&2
    exit 1
fi
for tool in git python3 cmake xcodebuild xcrun libtool dsymutil; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required developer tool is missing: $tool" >&2
        exit 1
    fi
done

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
LOCK_PATH="$REPOSITORY_DIRECTORY/ThirdParty/llama.cpp.lock.json"
PIN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$LOCK_PATH")"
SCRIPT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["buildScriptSHA256"])' "$LOCK_PATH")"
UPSTREAM_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstreamURL"])' "$LOCK_PATH")"
if [[ ! "$PIN" =~ ^[0-9a-f]{40}$ || ! "$SCRIPT_SHA" =~ ^[0-9a-f]{64}$ ||
      "$UPSTREAM_URL" != "https://github.com/ggml-org/llama.cpp.git" ]]; then
    echo "The dependency lock must contain a reviewed commit/hash and the allowlisted upstream." >&2
    exit 1
fi
python3 - <<'PY'
import re, subprocess, sys
version = re.search(r'cmake version (\d+)\.(\d+)\.(\d+)', subprocess.check_output(['cmake', '--version'], text=True))
if version is None or tuple(map(int, version.groups())) < (3, 28, 0):
    sys.exit('CMake >= 3.28.0 is required by the reviewed upstream build script.')
PY
for sdk in iphoneos iphonesimulator macosx xros xrsimulator appletvos appletvsimulator; do
    if ! xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1; then
        echo "Full Xcode SDK is missing: $sdk. The upstream script builds every Apple platform." >&2
        exit 1
    fi
done

SCRATCH_DIRECTORY="$REPOSITORY_DIRECTORY/.build"
SOURCE_DIRECTORY="$SCRATCH_DIRECTORY/llama.cpp-$PIN"
if [[ -L "$SCRATCH_DIRECTORY" || -L "$SOURCE_DIRECTORY" ]]; then
    echo "Refusing a symlinked dependency build directory." >&2
    exit 1
fi
mkdir -p -- "$SCRATCH_DIRECTORY"
if [[ ! -e "$SOURCE_DIRECTORY" ]]; then
    git init --quiet "$SOURCE_DIRECTORY"
    git -C "$SOURCE_DIRECTORY" remote add origin "$UPSTREAM_URL"
    git -C "$SOURCE_DIRECTORY" fetch --depth 1 origin "$PIN"
    git -C "$SOURCE_DIRECTORY" checkout --detach "$PIN"
fi
if [[ "$(git -C "$SOURCE_DIRECTORY" rev-parse HEAD)" != "$PIN" ]] ||
   [[ "$(git -C "$SOURCE_DIRECTORY" remote get-url origin)" != "$UPSTREAM_URL" ]] ||
   ! git -C "$SOURCE_DIRECTORY" diff --quiet HEAD --; then
    echo "Dependency checkout differs from the lock; inspect it before rebuilding." >&2
    exit 1
fi
python3 - "$SOURCE_DIRECTORY/build-xcframework.sh" "$SCRIPT_SHA" <<'PY'
import hashlib, pathlib, sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit('Upstream build script checksum differs from the reviewed lock.')
PY

# The pinned upstream script deletes only its own build-* directories here.
cd -- "$SOURCE_DIRECTORY"
bash ./build-xcframework.sh
if [[ ! -d "$SOURCE_DIRECTORY/build-apple/llama.xcframework" ]]; then
    echo "Upstream build returned without the expected XCFramework." >&2
    exit 1
fi
echo "Prepared local dependency: $SOURCE_DIRECTORY/build-apple/llama.xcframework"
echo "M0 has no linked native implementation. Follow docs/llama-cpp-metal.md before enabling inference."
