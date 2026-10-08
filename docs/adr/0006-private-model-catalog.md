# ADR 0006: Private catalog and explicit verified model restoration

Status: Implemented; device protection and power-loss recovery pending.

Catalog schema v1 stores reviewed manifests, UUID generation references and an
explicit selected ID/quantization. It never stores external file paths. Imports
install a new immutable private generation, then atomically replace catalog
metadata. A failed metadata commit removes only the uncommitted generation and
preserves the previous catalog/artifact. Actor ownership and a nonblocking file
lock prevent overlapping registry instances from committing conflicting state.

Rehash before restored selection and before native load. Missing, tampered,
corrupt or symlinked metadata/artifacts fail visibly rather than silently removing
records or selecting another model. Q8/Q4 selections remain explicit. M0's
uncataloged files are left intact and never automatically trusted.

Former committed generations are retained in M1, so recovering an older catalog
still has its matching artifact. This consumes extra disk space; cleanup and user
storage controls are later work. Crashes before catalog commit can also leave
unreferenced private generations. Atomic replacement gives process-level
consistency, not a general power-loss durability guarantee. Device/filesystem
crash testing and a transactional retention policy are required before that claim.

iOS metadata/directories use complete protection and backup exclusion. Imported
weights retain the importer's protection class. Locked-device access can fail.
Restoration verifies local metadata/file integrity only; it neither authenticates
a publisher nor automatically loads a model on foreground activation.
