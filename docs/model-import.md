# Reviewed local model import

The app imports local files and never downloads model weights. Obtain models
outside the app from a separately reviewed source. Never add GGUF files or
private data to this repository.

1. Inspect the actual Hugging Face repository listing for the community-pruned
   model named in ARCHITECTURE.md. Confirm immutable revision, publisher, pruning
   history, architecture, license and permitted uses. Do not assume a filename or
   quantization URL exists.
2. Choose an actual Q8_0 artifact, or a separately reviewed Q4_K_M artifact when
   Q8 is unsuitable. Obtain its exact byte count and SHA-256 independently of an
   untrusted local file. Computing a hash from an untrusted file does not establish
   a trust anchor.
3. Record the metadata in a JSON manifest with the shape below. Substitute actual
   reviewed values; the template deliberately contains no model download link or
   valid checksum. Keep the manifest beside its GGUF in Files for import.
4. In Settings, choose the reviewed manifest, inspect every value, acknowledge
   the source/revision/license/checksum, then select the matching GGUF. The app
   uses security-scoped access, copies and hashes incrementally, checks size and
   GGUF envelope, and installs an immutable private UUID generation. Choose a
   regular file; source symlinks are rejected. Failed validation preserves the
   existing catalog and installed generations and removes its staging files.
5. The private catalog persists reviewed manifests, generation references and
   explicit selected ID/quantization. After restart, selection restores only after
   file and SHA-256 verification. Native loading verifies again and requires an
   explicit load action; foreground activation never automatically loads weights.
6. Import verifies file consistency, not publisher trust or model quality. In an
   opt-in native build, loading also validates native tensor/quantization/template
   compatibility and resource admission. Unsupported artifacts fail visibly.

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

Q4 uses `"quantization": "Q4_K_M"`, its own safe ID, size, hash and reviewed
provenance. Selection is explicit: unload Q8, verify/select the reviewed Q4 catalog
entry, then load at a context no greater than 2048. Q4 has its own resource check.
Never treat generated instructions as approval to scan assets or deploy fixes.

## Persistence and storage limits

Catalog metadata contains no external source paths. Missing, tampered, corrupt or
symlinked catalog/artifact data fails visibly instead of silently dropping records
or selecting another model. M0's uncataloged weight files are left untouched and
never automatically trusted; reimport with reviewed metadata to use the catalog.

Allow space for the staged copy and installed weights. Reimport creates a new
generation; formerly committed generations remain on disk so an older recovered
catalog retains its matching file. A crash before catalog commit can also leave
unreferenced generations. M1 provides no cleanup/storage-management UI, and atomic
catalog replacement is not a general power-loss durability guarantee. Storage
exhaustion and crash recovery require device testing before release.

On iOS, catalog metadata/directories use complete file protection and backup
exclusion. Weights retain the importer's complete-until-first-authentication
protection class; locked-device access may fail. Device tests must verify actual
protection behavior. The sandbox and file protection reduce exposure but do not
remove native parser risk. Do not import unverified multi-gigabyte files merely
to discover memory fit.

See [llama-cpp-metal.md](llama-cpp-metal.md) for native build/admission behavior and
[device-verification.md](device-verification.md) for artifact/device acceptance.
