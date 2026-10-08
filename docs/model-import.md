# Reviewed local model import

M0 imports a local file; it does not download or execute model weights. Obtain
models outside the app using a separately reviewed source. Never add GGUF files
or private data to this repository.

1. Inspect the actual Hugging Face repository listing for the community-pruned
   model named in ARCHITECTURE.md. Confirm the immutable revision, publisher,
   pruning history, architecture, license and permitted uses. Do not assume any
   filename or quantization URL exists.
2. Choose an actual Q8_0 artifact, or a separately reviewed Q4_K_M artifact when
   Q8 is unsuitable. Obtain its exact byte count and SHA-256 independently of an
   untrusted local file. A hash you compute from a file you have not trusted is
   not independent verification.
3. Record the metadata in a JSON manifest with the shape below. Substitute actual
   reviewed values; the template deliberately contains no model download link or
   valid checksum. Keep this manifest beside the file in Files for import.
4. In Settings, import the reviewed manifest and choose the matching GGUF. The
   app copies with security-scoped access, hashes incrementally, checks size and
   GGUF envelope, then commits to app-private storage. Failure preserves existing
   installed models and removes staging files. Select an actual regular file;
   source symlinks are rejected. The verified model selection is session-only in
   M0; select the file and metadata again after restarting the app.
5. A successful import is file verification only. M0 cannot run that GGUF. Native
   load must subsequently validate architecture, tensor layout, quantization,
   tokenizer/template behavior, and memory budget before M1 readiness.

```json
{
  "id": "reviewed-model-q8",
  "displayName": "Reviewed experimental model",
  "quantization": "Q8_0",
  "expectedByteCount": 0,
  "sha256": "REPLACE_WITH_REVIEWED_64_HEX_SHA256",
  "provenance": {
    "sourceURL": "https://huggingface.co/REVIEWED_OWNER/REVIEWED_REPOSITORY",
    "revision": "REPLACE_WITH_IMMUTABLE_REVISION",
    "license": "REPLACE_WITH_REVIEWED_LICENSE"
  }
}
```

Q4 uses `"quantization": "Q4_K_M"`, its own safe ID, size, hash, and reviewed
provenance. Fallback is explicit: release the Q8 context, select the verified Q4
artifact, and retry at the default context after examining the failure. Never
treat the model's instructions as approval to scan assets or deploy fixes.

Allow space for the staged copy in addition to installed weights. Do not import
unverified multi-gigabyte files merely to discover if they fit. App sandbox and
Apple file protection reduce exposure but do not remove the native parser risk.
