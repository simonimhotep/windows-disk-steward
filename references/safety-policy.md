# Windows disk safety policy

## Operating boundary

- Support Windows PowerShell 7 and local NTFS fixed disks only.
- Treat scans as read-only outside the caller-supplied run directory.
- Derive user and system paths from the environment and selected volume. Do not hard-code a user name or destination drive.
- Do not follow directory Junctions or symbolic links while measuring or discovering candidates. Record and skip them.
- Restrict `TestRoot` to a random child of `%TEMP%\windows-disk-steward-tests` and keep its run directory outside the synthetic root. Never use test mode to bypass production volume checks.
- Never infer deletion approval from a request to scan, analyze, recommend, or free space.

## Classification

| Code | Category | Execution rule |
|---|---|---|
| `D` | Suggested deletion | May become a delete action after exact approval. |
| `C` | Caution | Explain consequences. Require a second explicit approval naming the ID or path before adding it to a plan. |
| `K` | Keep / forbidden | Report only. Never add to an execution plan. |
| `M` | Suggested migration | May become a migration action after exact approval and target-volume checks. |

Suggested deletion includes completed updater packages, unreferenced staging directories, crash reports, and caches that are reproducible with acceptable side effects.

Caution includes browser site data, Service Worker storage, application configuration, offline data, models, tool runtimes, current update caches, and data whose owner or regeneration cost is uncertain.

Suggested migration includes large, growing models, runtimes, extensions, global development tools, and development caches. Prefer an application's supported setting or environment variable. Use a Junction only when no reliable supported setting can preserve the original path.

## Always refuse

Refuse an action when its normalized or resolved path is any of these or is broader than the approved item:

- A drive root, volume root, user-profile root, `Users`, an entire `AppData`, `ProgramData`, or recycle-bin root.
- `Windows`, `System32`, `WinSxS`, `Windows\Installer`, boot or recovery directories.
- `pagefile.sys`, `hiberfil.sys`, swap files, registry hives, or active WinRE/Windows Update working directories.
- A wildcard path, an unresolved environment variable, a relative path, a path on a non-fixed or non-NTFS volume, or an unknown reparse point.
- A migration destination that already exists, is inside the source, lacks the required free space, or is not explicitly present in the approved plan.
- A source whose path type, resolved path, reparse state, file count, byte count, latest write time, or required-process state differs from the approved snapshot.

Do not manually remove browser cookies, login databases, passwords, offline site data, editor `User` settings, `WebStorage`, snapshots, or application documents merely because their directory name contains `Cache`.

## Approval and process gate

- Present the exact ID, literal source, operation, expected bytes, consequence, close-application requirement, and migration destination before approval.
- Bind approval to one scan `run_id`. Reject stale IDs or mismatched fingerprints.
- If approval is vague, repeat the full proposed action table and ask again.
- Do not stop processes. Fail preflight when a process listed by the approved action is running.
- Stop execution on the first failure. Preserve already completed actions in the result log and leave all later actions untouched.

## Migration and rollback

1. Confirm that source and destination are local NTFS fixed volumes and destination capacity exceeds source bytes plus a 1 GiB safety margin.
2. Copy without following reparse points.
3. Compare recursive file count and total bytes. Do not remove source on mismatch.
4. Remove the exact source and create a Junction to the exact destination.
5. Verify the Junction target and remeasure through the original path.
6. If Junction creation or verification fails, restore the original directory from the verified destination copy and stop.

For rollback, verify that the source is the recorded Junction to the recorded destination. Remove only the Junction, restore source data, and compare file count and bytes. Retain the destination copy unless a separate later cleanup is explicitly approved.
