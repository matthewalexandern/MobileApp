#!/usr/bin/env bash
# Developer-only source build. This script is never shipped inside the iOS app.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Usage: scripts/prepare-llama-xcframework.sh
Builds the locked llama.cpp source for this Mac, its iOS Simulator, and arm64 iOS.
Requires macOS, full Xcode (macOS/iOS SDKs), CMake >= 3.28 and Python 3.
Writes ignored Packages/NativeRuntime/Artifacts/llama.xcframework.
Enable it explicitly with NATIVE_RUNTIME_ENABLE_LLAMA=1 for Swift/Xcode builds.
No model files are downloaded. No binaries are published.
HELP
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
for tool in git python3 cmake xcodebuild xcrun libtool sysctl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required developer tool is missing: $tool" >&2
        exit 1
    fi
done
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "arm64" && "$HOST_ARCH" != "x86_64" ]]; then
    echo "Unsupported Apple build host architecture: $HOST_ARCH" >&2
    exit 1
fi

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
    sys.exit('CMake >= 3.28.0 is required for the reviewed Apple integration.')
PY
for sdk in iphoneos iphonesimulator macosx; do
    if ! xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1; then
        echo "Full Xcode SDK is missing: $sdk." >&2
        exit 1
    fi
done

SCRATCH_DIRECTORY="$REPOSITORY_DIRECTORY/.build"
SOURCE_DIRECTORY="$SCRATCH_DIRECTORY/llama.cpp-$PIN"
BUILD_DIRECTORY="$SCRATCH_DIRECTORY/llama-apple-$PIN-$HOST_ARCH"
ARTIFACT_DIRECTORY="$REPOSITORY_DIRECTORY/Packages/NativeRuntime/Artifacts"
ARTIFACT_PATH="$ARTIFACT_DIRECTORY/llama.xcframework"
for path in "$SCRATCH_DIRECTORY" "$SOURCE_DIRECTORY" "$BUILD_DIRECTORY" "$ARTIFACT_DIRECTORY" "$ARTIFACT_PATH"; do
    if [[ -L "$path" ]]; then
        echo "Refusing a symlinked dependency build/artifact directory: $path" >&2
        exit 1
    fi
done
mkdir -p -- "$SCRATCH_DIRECTORY" "$ARTIFACT_DIRECTORY"
if [[ ! -e "$SOURCE_DIRECTORY" ]]; then
    git init --quiet "$SOURCE_DIRECTORY"
    git -C "$SOURCE_DIRECTORY" remote add origin "$UPSTREAM_URL"
    git -C "$SOURCE_DIRECTORY" fetch --depth 1 origin "$PIN"
    git -C "$SOURCE_DIRECTORY" checkout --detach "$PIN"
fi
if [[ "$(git -C "$SOURCE_DIRECTORY" rev-parse HEAD)" != "$PIN" ]] ||
   [[ "$(git -C "$SOURCE_DIRECTORY" remote get-url origin)" != "$UPSTREAM_URL" ]] ||
   ! git -C "$SOURCE_DIRECTORY" diff --quiet HEAD -- ||
   [[ -n "$(git -C "$SOURCE_DIRECTORY" ls-files --others --exclude-standard)" ]]; then
    echo "Dependency checkout differs from the lock; inspect it before rebuilding." >&2
    exit 1
fi
python3 - "$SOURCE_DIRECTORY/build-xcframework.sh" "$SCRIPT_SHA" <<'PY'
import hashlib, pathlib, sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit('Upstream build script checksum differs from the reviewed lock.')
PY

# The pinned upstream wrapper has no platform-selection option and requires all
# seven Apple variants. Use its documented CMake settings and framework layout,
# with this app's deployment targets and only its three required platform slices.
# Disable common/tools/server code and both upstream network client integrations.
# GGML_METAL_USE_BF16 from the upstream wrapper is not an option at this pin;
# do not pass an ignored flag or claim it selects a kernel implementation.
COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_COMMON=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_CURL=OFF
    -DLLAMA_HTTPLIB=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS=ON
    -DGGML_BLAS_VENDOR=Apple
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
)
BUILD_JOBS="$(sysctl -n hw.logicalcpu)"
if (( BUILD_JOBS > 8 )); then BUILD_JOBS=8; fi

build_slice() {
    local slice="$1" sdk="$2" arch="$3" minimum_os="$4" system_name="$5" release_dir="$6"
    local slice_directory="$BUILD_DIRECTORY/$slice"
    # Keep this array nonempty for macOS's Bash 3.2 with `set -u`.
    local platform_args=("-DCMAKE_SYSTEM_NAME=$system_name")
    if [[ "$system_name" == "iOS" ]]; then
        platform_args+=("-DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=$sdk")
    fi
    cmake -S "$SOURCE_DIRECTORY" -B "$slice_directory" -G Xcode \
        "${COMMON_CMAKE_ARGS[@]}" "${platform_args[@]}" \
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=$minimum_os" \
        "-DCMAKE_OSX_SYSROOT=$sdk" "-DCMAKE_OSX_ARCHITECTURES=$arch"
    cmake --build "$slice_directory" --config Release --parallel "$BUILD_JOBS" -- -quiet

    local framework="$slice_directory/framework/llama.framework"
    local contents="$framework" install_name="@rpath/llama.framework/llama"
    if [[ "$system_name" == "Darwin" ]]; then
        contents="$framework/Versions/A"
        install_name="@rpath/llama.framework/Versions/A/llama"
    fi
    mkdir -p -- "$contents/Headers" "$contents/Modules"
    for header in llama.h ggml.h ggml-opt.h ggml-alloc.h ggml-backend.h ggml-metal.h ggml-cpu.h ggml-blas.h gguf.h; do
        if [[ "$header" == "llama.h" ]]; then
            cp -- "$SOURCE_DIRECTORY/include/$header" "$contents/Headers/"
        else
            cp -- "$SOURCE_DIRECTORY/ggml/include/$header" "$contents/Headers/"
        fi
    done
    cat > "$contents/Modules/module.modulemap" <<'MODULE'
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"
    export *
}
MODULE
    local libraries=(
        "$slice_directory/src/$release_dir/libllama.a"
        "$slice_directory/ggml/src/$release_dir/libggml.a"
        "$slice_directory/ggml/src/$release_dir/libggml-base.a"
        "$slice_directory/ggml/src/$release_dir/libggml-cpu.a"
        "$slice_directory/ggml/src/ggml-metal/$release_dir/libggml-metal.a"
        "$slice_directory/ggml/src/ggml-blas/$release_dir/libggml-blas.a"
    )
    xcrun libtool -static -o "$slice_directory/combined.a" "${libraries[@]}"
    local target="$arch-apple-ios$minimum_os"
    local supported_platform="iPhoneOS"
    local plist_path="$contents/Info.plist"
    if [[ "$sdk" == "iphonesimulator" ]]; then
        target+="-simulator"
        supported_platform="iPhoneSimulator"
    elif [[ "$system_name" == "Darwin" ]]; then
        target="$arch-apple-macos$minimum_os"
        supported_platform="MacOSX"
        mkdir -p -- "$contents/Resources"
        plist_path="$contents/Resources/Info.plist"
        ln -sfn A "$framework/Versions/Current"
        ln -sfn Versions/Current/Headers "$framework/Headers"
        ln -sfn Versions/Current/Modules "$framework/Modules"
        ln -sfn Versions/Current/Resources "$framework/Resources"
        ln -sfn Versions/Current/llama "$framework/llama"
    fi
    xcrun --sdk "$sdk" clang++ -dynamiclib \
        -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        "-Wl,-force_load,$slice_directory/combined.a" \
        -framework Foundation -framework Metal -framework MetalKit -framework Accelerate \
        -install_name "$install_name" -o "$contents/llama"
    python3 - "$plist_path" "$minimum_os" "$supported_platform" <<'PY'
import plistlib, sys
info = {
    'CFBundleDevelopmentRegion': 'en', 'CFBundleExecutable': 'llama',
    'CFBundleIdentifier': 'org.ggml.llama', 'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleName': 'llama', 'CFBundlePackageType': 'FMWK',
    'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
    'MinimumOSVersion': sys.argv[2], 'CFBundleSupportedPlatforms': [sys.argv[3]],
}
if sys.argv[3] != 'MacOSX':
    info['UIDeviceFamily'] = [1, 2]
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(info, output)
PY
    mkdir -p -- "$contents/Resources"
    cp -- "$SOURCE_DIRECTORY/LICENSE" "$contents/Resources/llama.cpp-LICENSE.txt"
    # Embedded Metal source symbols must survive archive aggregation and linking.
    xcrun nm -gU "$contents/llama" > "$slice_directory/exported-symbols.txt"
    if ! /usr/bin/grep -q '_ggml_metallib_start' "$slice_directory/exported-symbols.txt"; then
        echo "Linked $slice framework lacks embedded Metal library symbols." >&2
        exit 1
    fi
    # An ad-hoc signature allows macOS package tests to load the locally built
    # framework. Xcode replaces it when embedding/signing a physical-device app.
    xcrun codesign --force --sign - "$framework"
}

build_slice macos macosx "$HOST_ARCH" 14.0 Darwin Release
build_slice ios-simulator iphonesimulator "$HOST_ARCH" 17.0 iOS Release-iphonesimulator
build_slice ios-device iphoneos arm64 17.0 iOS Release-iphoneos

TEMP_ARTIFACT_DIRECTORY="$(mktemp -d "$ARTIFACT_DIRECTORY/.llama-XXXXXX")"
trap 'rm -rf -- "$TEMP_ARTIFACT_DIRECTORY"' EXIT
xcodebuild -create-xcframework \
    -framework "$BUILD_DIRECTORY/macos/framework/llama.framework" \
    -framework "$BUILD_DIRECTORY/ios-simulator/framework/llama.framework" \
    -framework "$BUILD_DIRECTORY/ios-device/framework/llama.framework" \
    -output "$TEMP_ARTIFACT_DIRECTORY/llama.xcframework"
python3 - "$TEMP_ARTIFACT_DIRECTORY/llama.xcframework" "$PIN" "$SCRIPT_SHA" "$HOST_ARCH" "$0" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys
artifact = pathlib.Path(sys.argv[1])
info = plistlib.loads((artifact / 'Info.plist').read_bytes())
expected = {('macos', ''), ('ios', 'simulator'), ('ios', '')}
actual = {(entry['SupportedPlatform'], entry.get('SupportedPlatformVariant', '')) for entry in info['AvailableLibraries']}
if actual != expected:
    sys.exit(f'Unexpected XCFramework slices: {actual}')
frameworks = {}
for entry in info['AvailableLibraries']:
    expected_arch = 'arm64' if entry['SupportedPlatform'] == 'ios' and not entry.get('SupportedPlatformVariant') else sys.argv[4]
    if entry['SupportedArchitectures'] != [expected_arch]:
        sys.exit(f'Unexpected architecture in {entry["LibraryIdentifier"]}')
    binary = artifact / entry['LibraryIdentifier'] / entry['LibraryPath'] / 'llama'
    frameworks[entry['LibraryIdentifier']] = hashlib.sha256(binary.read_bytes()).hexdigest()
provenance = {
    'commit': sys.argv[2], 'reviewedUpstreamScriptSHA256': sys.argv[3],
    'appBuildScriptSHA256': hashlib.sha256(pathlib.Path(sys.argv[5]).read_bytes()).hexdigest(),
    'hostArchitecture': sys.argv[4], 'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'metalEnabled': True, 'metalEmbedded': True, 'frameworkSHA256': frameworks,
}
(artifact / 'BUILD-PROVENANCE.json').write_text(json.dumps(provenance, indent=2) + '\n')
PY
if [[ -e "$ARTIFACT_PATH" ]]; then rm -rf -- "$ARTIFACT_PATH"; fi
mv -- "$TEMP_ARTIFACT_DIRECTORY/llama.xcframework" "$ARTIFACT_PATH"
echo "Prepared local dependency: $ARTIFACT_PATH"
echo "Build with NATIVE_RUNTIME_ENABLE_LLAMA=1. This build does not establish device inference or memory fit."
