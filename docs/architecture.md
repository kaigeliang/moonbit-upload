# Crash recovery contract

## Representation
Each upload has `manifest.json` plus immutable committed chunk files named by their starting offset.
The manifest contains version, total length, committed offset and ordered chunk names/sizes.
The committed offset equals the sum of referenced chunk sizes. Serving or resuming fails if any referenced chunk is missing or has the wrong size.

## PATCH sequence
1. Reject stale offset, unsupported request form, or oversized chunk before touching storage.
2. Acquire the per-upload busy flag. A conflicting request gets 409; it must query HEAD and retry.
3. Read the body in at most 64 KiB units into `chunk.pending`; a short request aborts without changing manifest.
4. Sync the staging file; rename it to the file for the old committed offset.
5. Write and sync `manifest.pending`; atomically rename it over `manifest.json`.
6. Return 204 with the new Upload-Offset.

The committed manifest is the authoritative acknowledgment boundary. A failed response after step 5 does not roll back committed data: HEAD reports the new offset, and the client resumes there.

## Crash windows
| Crash position | State after restart |
|---|---|
| During/in completion of staging | Old manifest. Ignore/replace `chunk.pending`. |
| After chunk rename, before manifest commit | Old manifest. The unreferenced chunk may be overwritten on retry. |
| After manifest commit, before HTTP response | New manifest. HEAD reports the advanced offset. |

The fault harness waits for a marker at the chosen stage, sends SIGKILL to the exact test child PID, launches a new process and verifies both offset and downloaded bytes.
The OS releases the exclusive store advisory lock when that child dies.

## Scope of durability
This is process-crash recovery on local macOS/APFS. It is not a proof of power-loss durability: directory entries are not synced, and network filesystems/other OSes are untested.
An external writer modifying the store is outside the locking contract. Same-sized corrupt content is not detected internally.

## Scaling
Request buffering is bounded by a 64 KiB read plus transport buffers, independent of total file length.
The JSON manifest and its chunk array grow with the number of PATCHes; validation checks all committed chunk sizes on each access. These metadata costs are not constant.

## Next engineering gates
Extract reusable library APIs; verify Linux; add request timeout/quotas, storage-integrity policy, orphan cleanup, and user-level access control before any public endpoint.
