#!/usr/bin/env python3
"""Build pinned device/simulator llama.xcframework on a Mac with full Xcode."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def run(args, *, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, text=True).strip()


def verify(source: Path, pin: dict, env: dict) -> None:
    def git(*args): return run(["git", "--no-replace-objects", *args], cwd=source, env=env)
    if git("rev-parse", "HEAD") != pin["commit"] or git("rev-parse", "HEAD^{tree}") != pin["git_tree_sha"]:
        raise SystemExit("Source commit/tree differs from the approved pin.")
    entries = subprocess.check_output(["git", "ls-tree", "-rz", "HEAD"], cwd=source, env=env)
    for raw in entries.split(b"\0"):
        if not raw: continue
        metadata, name = raw.split(b"\t", 1)
        mode, kind, sha = metadata.decode().split()
        file = source / os.fsdecode(name)
        if kind != "blob" or mode not in ("100644", "100755", "120000"):
            raise SystemExit("Unsupported source tree entry.")
        if mode == "120000":
            if not file.is_symlink() or not file.resolve().is_relative_to(source.resolve()):
                raise SystemExit("Unsafe source symlink.")
            content = os.fsencode(os.readlink(file))
        else:
            if file.is_symlink() or not file.is_file(): raise SystemExit("Source file type changed.")
            content = file.read_bytes()
            if bool(file.stat().st_mode & 0o111) != (mode == "100755"):
                raise SystemExit("Source executable mode changed.")
        digest = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        if digest != sha: raise SystemExit("Actual source bytes differ from the pin.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2, help="maximum CMake compile jobs (1...4)")
    args = parser.parse_args()
    if platform.system() != "Darwin": raise SystemExit("A Mac with full Xcode and iOS SDKs is required.")
    if not 1 <= args.jobs <= 4: raise SystemExit("Choose 1...4 compile jobs.")
    for command in ["git", "xcodebuild", "cmake"]:
        if not shutil.which(command): raise SystemExit(f"Missing build dependency: {command}")
    pin = json.loads((REPO / "configs/llama-source.lock.json").read_text())
    if pin.get("repository_url") != "https://github.com/ggml-org/llama.cpp" or pin.get("source_mode") != "git-tree" or not re.fullmatch(r"[0-9a-f]{40}", pin.get("commit", "")) or not re.fullmatch(r"[0-9a-f]{40}", pin.get("git_tree_sha", "")):
        raise SystemExit("Invalid official Git-tree source pin.")
    destination = ROOT / "Vendor/llama.xcframework"
    if destination.exists(): raise SystemExit("Framework already exists; preserve it or remove it explicitly before rebuilding.")
    state = REPO / ".tools/iphone-builds"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    work = Path(tempfile.mkdtemp(prefix=pin["commit"][:12] + "-", dir=state))
    os.chmod(work, 0o700)
    home = work / "home"; home.mkdir(mode=0o700)
    source = work / "source"
    # Public source only. Never pass ambient tokens, global Git rewrites or loader overrides.
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"), "HOME": str(home), "LANG": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "protocol.allow", "GIT_CONFIG_VALUE_0": "never", "GIT_CONFIG_KEY_1": "protocol.https.allow", "GIT_CONFIG_VALUE_1": "always"}
    run(["git", "init", str(source)], env=env)
    run(["git", "-c", "http.followRedirects=false", "fetch", "--depth=1", pin["repository_url"], pin["commit"]], cwd=source, env=env)
    run(["git", "checkout", "--detach", "FETCH_HEAD"], cwd=source, env=env)
    verify(source, pin, env)
    if run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source, env=env): raise SystemExit("Fresh source is not clean.")
    # Upstream uses sysctl hw.logicalcpu for inner CMake jobs. Override just that
    # CPU-budget observation, keeping the approved build script byte-for-byte.
    tools = work / "tools"; tools.mkdir(mode=0o700)
    shim = tools / "sysctl"
    shim.write_text('#!/bin/sh\nif [ "$1" = "-n" ] && [ "$2" = "hw.logicalcpu" ]; then\n  echo ' + str(args.jobs) + '\nelse\n  exec /usr/sbin/sysctl "$@"\nfi\n')
    shim.chmod(0o700)
    env["PATH"] = str(tools) + os.pathsep + env["PATH"]
    subprocess.run(["bash", "build-xcframework.sh", "ios-device", "ios-sim"], cwd=source, env=env, check=True, timeout=7200)
    verify(source, pin, env)
    framework = source / "build-apple/llama.xcframework"
    if not (framework / "Info.plist").is_file(): raise SystemExit("Expected XCFramework was not produced.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(framework, destination, symlinks=True)
    files = []
    for file in sorted(destination.rglob("*")):
        if file.is_file(): files.append({"path": file.relative_to(destination).as_posix(), "sha256": hashlib.sha256(file.read_bytes()).hexdigest(), "bytes": file.stat().st_size})
    (work / "receipt.json").write_text(json.dumps({"source": pin, "jobs": args.jobs, "framework": str(destination), "files": files}, indent=2) + "\n")
    print(f"Framework built at {destination}. Private source/receipt retained at {work}.")


if __name__ == "__main__": main()
