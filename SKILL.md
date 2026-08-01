---
name: windows-disk-steward
description: Safely inspect, classify, delete, migrate, verify, or roll back disk-space usage on local Windows fixed disks. Use when a user asks to scan a Windows drive, find removable files, free disk space, distinguish caches from application or system data, move growing application data to another drive, or execute an approved cleanup. Require an exact approval gate before every deletion or migration.
---

# Windows Disk Steward

Manage Windows disk space through a fail-closed scan, approval, execution, and verification workflow.

## Workflow

1. Require Windows PowerShell 7 and local NTFS fixed disks. Refuse unsupported environments.
2. Read [references/safety-policy.md](references/safety-policy.md) before classifying or changing any path.
3. Run `scripts/scan-windows-disk.ps1`. Treat scanning as read-only except for artifacts written under `RunDirectory`.
4. Present the generated report and exact candidate IDs. State clearly that no cleanup has occurred.
5. Treat a scan request as zero execution authorization. If the user says “clean all” or gives similarly vague approval, restate the complete action table and obtain approval for exact IDs or paths.
6. Read [references/action-plan-schema.md](references/action-plan-schema.md). Build `approved-actions.json` only from the current scan and only with explicitly approved actions. Never add a forbidden candidate.
7. Run `scripts/execute-approved-actions.ps1 -Mode Preflight`. Stop on any drift, active required process, unsafe path, unsupported volume, or schema failure and request fresh approval when required.
8. Run `-Mode Execute` only after a clean preflight. Do not close applications on the user's behalf. Report completed, failed, and untouched actions plus actual space changes.
9. Run `-Mode Rollback` only on an explicit rollback request. Restore source data and verify it; retain the destination copy by default.

## Commands

```powershell
pwsh -File scripts/scan-windows-disk.ps1 -Drive C -RunDirectory <run-directory> [-TargetDrive D] [-Language zh-CN]
pwsh -File scripts/execute-approved-actions.ps1 -PlanFile <approved-actions.json> -Mode Preflight
pwsh -File scripts/execute-approved-actions.ps1 -PlanFile <approved-actions.json> -Mode Execute
pwsh -File scripts/execute-approved-actions.ps1 -PlanFile <approved-actions.json> -Mode Rollback
```

Use `-TestRoot` only for synthetic tests created beneath `%TEMP%\windows-disk-steward-tests\<random-id>`, with `RunDirectory` outside that root. Never use it to present a partial directory as a real volume scan.

## Non-negotiable gates

- Use exact literal paths; reject wildcards, unresolved variables, roots, broad user or system directories, and unknown reparse points.
- Bind approvals to `run_id`, candidate ID, fingerprint, and snapshot. Re-scan after material drift.
- Migrate in this order: copy, compare file count and bytes, remove source, create Junction, verify through the original path.
- Preserve source data when copy or verification fails. Restore it automatically if Junction creation fails.
- Keep unapproved paths unchanged and include them in the final verification.
