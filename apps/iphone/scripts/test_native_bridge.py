#!/usr/bin/env python3
"""Exercise the iPhone C API against pinned host CPU libraries and a tiny fixture.

This is a host correctness smoke, not an iOS/Metal or model-quality test. Nothing
is downloaded. The existing stories260K fixture is copied with synthetic chat
metadata only in the selected private output directory; original bytes stay put.
Run using an existing Python environment containing numpy and tqdm.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from datetime import datetime, timezone


FIXTURE_SHA256 = "270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1 << 20):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llama-source", type=Path, required=True)
    parser.add_argument("--library-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="New directory for private generated fixtures, binary and receipt")
    parser.add_argument("--cxx", default="c++")
    args = parser.parse_args()
    app = Path(__file__).resolve().parents[1]
    repo = app.parents[1]
    source = args.llama_source.resolve(strict=True)
    library = args.library_dir.resolve(strict=True)
    fixture = args.fixture.resolve(strict=True)
    if fixture.stat().st_size > 16 << 20 or digest(fixture) != FIXTURE_SHA256:
        raise ValueError("Use the existing verified stories260K-f32.gguf test fixture.")
    manifest = json.loads((repo / "configs/llama-source.lock.json").read_text())
    actual_commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual_commit != manifest["commit"]:
        raise ValueError("Host source must match the configured exact llama.cpp commit.")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"], text=True):
        raise ValueError("The pinned source checkout must be clean.")
    sys.path.insert(0, str(source / "gguf-py"))
    import gguf
    from gguf.scripts.gguf_new_metadata import copy_with_new_metadata, MetadataDetails

    output = args.output_dir.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    old_umask = os.umask(0o077)
    try:
        chat = output / "stories260K-chatml-fixture.gguf"
        huge_context = output / "stories260K-huge-context-fixture.gguf"
        oversized = output / "oversized-sparse-fixture.gguf"
        for destination, extra in [
            (chat, {}),
            (huge_context, {"llama.context_length": MetadataDetails(gguf.GGUFValueType.UINT32, 1 << 24)}),
        ]:
            reader = gguf.GGUFReader(fixture)
            writer = gguf.GGUFWriter(destination, "llama")
            changes = {"tokenizer.chat_template": MetadataDetails(gguf.GGUFValueType.STRING, "chatml"), **extra}
            copy_with_new_metadata(reader, writer, changes, [])
        with oversized.open("xb") as file:
            file.write(b"GGUF")
            file.truncate((2 << 30) + 1)
        binary = output / "native-smoke"
        compiler = shutil.which(args.cxx)
        if not compiler:
            raise ValueError("The requested C++17 compiler is unavailable.")
        command = [compiler, "-std=c++17", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                   str(app / "KernalMobile/Native/KMLlama.cpp"), str(app / "tests/native_smoke.cpp"),
                   "-I", str(source / "include"), "-I", str(source / "ggml/include"),
                   "-L", str(library), "-Wl,-rpath," + str(library),
                   "-lllama", "-lggml", "-lggml-base", "-lggml-cpu", "-pthread", "-o", str(binary)]
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
        (output / "compile.log").write_text(compiled.stdout + compiled.stderr)
        compiled.check_returncode()
        executed = subprocess.run([str(binary), str(fixture), str(chat), str(huge_context), str(oversized)],
                                  capture_output=True, text=True, timeout=60)
        (output / "native-smoke.log").write_text(executed.stdout + executed.stderr)
        executed.check_returncode()
        if "checks=14" not in executed.stdout or digest(fixture) != FIXTURE_SHA256:
            raise ValueError("Smoke receipt or original fixture verification failed.")
        receipt = {
            "schema": "iphone-native-host-smoke-v1",
            "verified_at": datetime.now(timezone.utc).isoformat(),
            "llama_commit": actual_commit,
            "backend": "host CPU libraries; no iOS or Metal qualification",
            "logical_checks": 14,
            "result": executed.stdout.strip(),
            "fixture_native_context": 2048,
            "fixture_original_sha256": FIXTURE_SHA256,
            "fixture_original_unchanged": True,
            "synthetic_chat_fixture_sha256": digest(chat),
            "synthetic_huge_context_fixture_sha256": digest(huge_context),
            "oversized_weight_fixture_logical_bytes": (2 << 30) + 1,
            "oversized_weight_fixture_removed_after_test": True,
            "source_sha256": {str(path.relative_to(app)): digest(path) for path in [
                app / "KernalMobile/Native/KMLlama.h", app / "KernalMobile/Native/KMLlama.cpp", app / "tests/native_smoke.cpp"]},
            "checks": ["invalid configuration", "insufficient byte budget", "missing template refusal",
                       "excessive native-context admission refusal", "oversized weight refusal",
                       "metadata native context preserved", "model size reporting", "actual bounded generation",
                       "cancellation without output", "over-context prompt refused", "reserved control tokens refused",
                       "maximum token bound", "output buffer bound", "engine reuse after context clearing"],
            "limitations": ["Synthetic chat metadata is a test fixture, not a trained chat model.",
                            "No GPT-OSS model or iPhone inference capacity was tested.",
                            "No Apple SDK, signed app, simulator or Metal build was exercised."],
        }
        oversized.unlink()
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(executed.stdout.strip())
        print("Receipt:", output / "receipt.json")
    finally:
        os.umask(old_umask)


if __name__ == "__main__":
    main()
