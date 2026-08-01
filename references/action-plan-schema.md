# Run artifacts and action-plan schema

All JSON files use UTF-8, schema version `1`, absolute Windows paths, UTC ISO-8601 timestamps, integer byte counts, and case-insensitive path comparison.

## `scan.json`

```json
{
  "schema_version": 1,
  "run_id": "20260801T120000Z-a1b2c3d4",
  "scanned_at_utc": "2026-08-01T12:00:00.0000000Z",
  "drive": "C",
  "root_path": "C:\\",
  "test_mode": false,
  "language": "zh-CN",
  "volume": { "drive_type": "Fixed", "file_system": "NTFS", "size_bytes": 0, "free_bytes": 0 },
  "target_volume": null,
  "coverage": {
    "directories_attempted": 0,
    "directories_scanned": 0,
    "directories_skipped": 0,
    "coverage_percent": 100.0,
    "files_scanned": 0,
    "bytes_scanned": 0
  },
  "skipped_paths": [],
  "update_state": {},
  "processes": [],
  "installed_applications": [],
  "top_level": [],
  "largest_files": [],
  "candidates": []
}
```

Each candidate contains:

```json
{
  "id": "D01",
  "category": "delete",
  "path": "C:\\absolute\\literal\\path",
  "resolved_path": "C:\\absolute\\literal\\path",
  "entry_type": "Directory",
  "is_reparse_point": false,
  "file_count": 10,
  "size_bytes": 1000,
  "latest_write_utc": "2026-08-01T12:00:00.0000000Z",
  "risk": "low",
  "recommendation": "delete",
  "evidence": ["Known reproducible cache"],
  "side_effects": ["May be downloaded again"],
  "required_processes_stopped": ["ExampleApp"],
  "fingerprint": "sha256-hex"
}
```

Candidate IDs are deterministic for the sorted candidate list but valid only with their `run_id` and fingerprint. `delete`, `caution`, `keep`, and `migrate` map to prefixes `D`, `C`, `K`, and `M`.

## `approved-actions.json`

```json
{
  "schema_version": 1,
  "run_id": "20260801T120000Z-a1b2c3d4",
  "scan_file": "C:\\absolute\\run\\scan.json",
  "approved_at_utc": "2026-08-01T12:10:00.0000000Z",
  "actions": [
    {
      "id": "D01",
      "type": "delete",
      "fingerprint": "sha256-hex",
      "source_path": "C:\\absolute\\literal\\path",
      "resolved_source_path": "C:\\absolute\\literal\\path",
      "entry_type": "Directory",
      "is_reparse_point": false,
      "file_count": 10,
      "size_bytes": 1000,
      "latest_write_utc": "2026-08-01T12:00:00.0000000Z",
      "required_processes_stopped": []
    }
  ]
}
```

A migration action adds `destination_path` and `destination_root`. Only candidate categories `delete`, `caution`, and `migrate` may be approved; a caution action requires the conversation to contain the user's second explicit approval. `keep` is never executable. The executor verifies that every action exactly matches a candidate in the referenced scan.

## Results

`execution-result.json` contains mode, start/end times, disk free-space snapshots when available, per-action state (`completed`, `failed`, or `not_started`), actual bytes affected, and the first failure.

`migration-manifest.json` contains only successfully migrated actions and records source, destination, Junction target, pre-migration file count and bytes, completion time, and rollback state.

`report.md` is a human-readable summary in the requested language. It must show coverage and skipped paths, separate all four categories, explain side effects, state that scanning made no changes outside the run directory, and never represent estimated candidate bytes as guaranteed reclaimable space.
