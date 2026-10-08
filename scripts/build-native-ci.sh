#!/usr/bin/env bash
# Local/CI Apple verification. No model downloads, signing identity, or uploads.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Usage: scripts/build-native-ci.sh
After scripts/prepare-llama-xcframework.sh, verify provenance, run the native
Swift package tests, and build unsigned iOS simulator and arm64 device apps.
Checks that each app links and embeds llama.framework. Requires macOS/Xcode.
This does not run inference on a physical device or satisfy M1 device gates.
HELP
    exit 0
fi
if [[ "$#" -ne 0 || "$(uname -s)" != "Darwin" ]]; then
    echo "Native Apple validation requires macOS/Xcode and accepts no arguments. Use --help." >&2
    exit 1
fi
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIRECTORY="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd)"
HOST_ARCH="$(uname -m)"
cd -- "$REPOSITORY_DIRECTORY"

python3 - "$REPOSITORY_DIRECTORY" "$HOST_ARCH" <<'PY'
import hashlib, json, pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
artifact = root / 'Packages/NativeRuntime/Artifacts/llama.xcframework'
try:
    lock = json.loads((root / 'ThirdParty/llama.cpp.lock.json').read_text())
    provenance = json.loads((artifact / 'BUILD-PROVENANCE.json').read_text())
    info = plistlib.loads((artifact / 'Info.plist').read_bytes())
except (OSError, ValueError) as error:
    sys.exit(f'Native artifact is missing or invalid; run scripts/prepare-llama-xcframework.sh: {error}')
expected_script_hash = hashlib.sha256((root / 'scripts/prepare-llama-xcframework.sh').read_bytes()).hexdigest()
if provenance['commit'] != lock['commit'] or provenance['reviewedUpstreamScriptSHA256'] != lock['buildScriptSHA256']:
    sys.exit('Native artifact source pin differs from the lock; rebuild it.')
if provenance['appBuildScriptSHA256'] != expected_script_hash or provenance['hostArchitecture'] != sys.argv[2]:
    sys.exit('Native artifact build script/host differs; rebuild it on this Mac.')
if not provenance['metalEnabled'] or not provenance['metalEmbedded']:
    sys.exit('Native artifact was not prepared with embedded Metal enabled.')
libraries = info['AvailableLibraries']
if len(libraries) != 3 or {(library['SupportedPlatform'], library.get('SupportedPlatformVariant', '')) for library in libraries} != {('macos', ''), ('ios', ''), ('ios', 'simulator')}:
    sys.exit('Native artifact must contain macOS, iOS device and iOS Simulator slices.')
for library in libraries:
    binary = artifact / library['LibraryIdentifier'] / library['LibraryPath'] / 'llama'
    if hashlib.sha256(binary.read_bytes()).hexdigest() != provenance['frameworkSHA256'][library['LibraryIdentifier']]:
        sys.exit(f'Native framework checksum differs: {library["LibraryIdentifier"]}')
print(f'Native source provenance and {len(libraries)} framework checksums verified.')
PY

export NATIVE_RUNTIME_ENABLE_LLAMA=1
# Separate scratch roots prevent a portable dependency graph from satisfying a
# native build by accident, and keep simulator/device app products independent.
swift test --package-path Packages/NativeRuntime --scratch-path .build/native-package-tests

build_app() {
    local sdk="$1" destination="$2" arch="$3" product_directory="$4"
    local derived_data="$REPOSITORY_DIRECTORY/.build/native-app-$sdk"
    # Keep application code in the executable so the linkage assertion below
    # checks the binary that owns llama symbols on Xcode 16 and newer.
    xcodebuild \
        -project NativeRuntime.xcodeproj \
        -scheme NativeRuntimeApp \
        -configuration Debug \
        -sdk "$sdk" \
        -destination "$destination" \
        -derivedDataPath "$derived_data" \
        "ARCHS=$arch" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
        build
    local app="$derived_data/Build/Products/$product_directory/NativeRuntimeApp.app"
    if [[ ! -f "$app/Frameworks/llama.framework/llama" ]]; then
        echo "Native $sdk build did not embed llama.framework in the app." >&2
        exit 1
    fi
    xcrun otool -L "$app/NativeRuntimeApp" > "$derived_data/native-linkage.txt"
    if ! /usr/bin/grep -q '@rpath/llama.framework/llama' "$derived_data/native-linkage.txt"; then
        echo "Native $sdk application does not link llama.framework." >&2
        exit 1
    fi
    echo "Verified llama.framework linkage and embedding for $sdk ($arch)."
}

build_app iphonesimulator 'generic/platform=iOS Simulator' "$HOST_ARCH" Debug-iphonesimulator
build_app iphoneos 'generic/platform=iOS' arm64 Debug-iphoneos
