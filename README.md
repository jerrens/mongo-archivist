# MongoDB Backup & Restore Scripts

Bash scripts for backing up and restoring all MongoDB databases and collections to timestamped, per-collection compressed archives.

## Files

| File | Description |
|------|-------------|
| `mongodb-backup.sh` | Dumps all MongoDB databases/collections to `.archive.gz` files |
| `mongodb-restore.sh` | Restores archives created by `mongodb-backup.sh` |
| `mongodb-compare.sh` | Compares two MongoDB servers for collection-level synchronization |
| `mongodb-archivist.conf` | Your local configuration file (not committed) |
| `mongodb-archivist.conf.example` | Template — copy to `mongodb-archivist.conf` and fill in values |

---

## Configuration

Both scripts share the same config file. Copy the example and edit it:

```bash
cp mongodb-backup.conf.example mongodb-archivist.conf
```

### Required keys

| Key | Description |
|-----|-------------|
| `mongo_uri` | MongoDB connection string (e.g. `mongodb://user:pass@host:27017/`) |
| `backup_root` | Root directory where timestamped backup folders will be created |

### Optional keys

| Key | Default | Description |
|-----|---------|-------------|
| `parallel_jobs` | `4` | Max concurrent `mongodump` processes |
| `exclude_databases` | `admin config local` | Space-separated list of databases to skip |
| `fallback_required_bytes` | `53687091200` (50 GB) | Assumed disk space needed when no prior backup exists |
| `mongosh_cmd` | `mongosh` | Override to use a containerized `mongosh` |
| `mongodump_cmd` | `mongodump` | Override to use a containerized `mongodump` |
| `mongorestore_cmd` | `mongorestore` | Override to use a containerized `mongorestore` |

### Example config

```ini
mongo_uri=mongodb://mongoadmin:password@127.0.0.1:27017/
backup_root=/var/backups/mongodb
parallel_jobs=4
exclude_databases=admin config local
```

### Container overrides

If `mongosh`, `mongodump`, or `mongorestore` are not installed locally, point them at a container image.

> [!NOTE]
> The backup directory must be mounted so the container can write to it

```ini
mongosh_cmd=podman run --rm docker.io/alpine/mongosh:latest mongosh
mongodump_cmd=podman run --rm --volume /var/backups/mongodb:/var/backups/mongodb docker.io/alpine/mongosh:latest mongodump
mongorestore_cmd=podman run --rm --volume /var/backups/mongodb:/var/backups/mongodb docker.io/alpine/mongosh:latest mongorestore
```

---

## mongodb-backup.sh

Dumps every collection in every non-excluded database to a compressed archive file.

### Output structure

```
BACKUP_ROOT/
  YYYYMMDD_HHmmss/
    <database>/
      <collection>.archive.gz
    ...
  mongodb-backup.YYYYMMDD_HHmmss.log
```

### Usage

```
./mongodb-backup.sh [OPTIONS]

Options:
  --config <file>  Path to config file (default: mongodb-archivist.conf)
  --resume         Reuse the newest backup folder; skip collections that
                   already have a .archive.gz (safe re-run after interruption)
  --dry-run        Print what would be done without executing any mongodump
  --version        Show script version and exit
  -v / -vv / -vvv  Increase log verbosity
  --help           Show help (add -v to also print current config values)
```

### Examples

```bash
# Standard backup using mongodb-archivist.conf
./mongodb-backup.sh

# Explicit config file
./mongodb-backup.sh --config /etc/mongodb-backup.conf

# Preview what would be dumped (no writes)
./mongodb-backup.sh --dry-run -vv

# Resume an interrupted backup
./mongodb-backup.sh --resume

# Show resolved config values before running
./mongodb-backup.sh -v --help
```

---

## mongodb-restore.sh

Restores one or more `.archive.gz` collection archives created by `mongodb-backup.sh`.

### Usage

```
./mongodb-restore.sh [OPTIONS] <path> [path ...]

Path inputs (one or many):
  - Timestamp folder — restores all archives under it recursively
  - Database folder  — restores all archives under it recursively
  - Individual *.archive.gz file

Options:
  --config <file>             Path to config file (default: mongodb-archivist.conf)
  --input <path>              Add an input path (repeatable)
  --mongo-restore-flags <s>   Raw flags forwarded to mongorestore
  --dry-run                   Run mongorestore with --dryRun (no data written)
  --version                   Show script version and exit
  -v / -vv / -vvv             Increase log verbosity
  --help                      Show help (add -v to also print current config values)
```

### Examples

```bash
# Restore an entire timestamped backup
./mongodb-restore.sh /var/backups/mongodb/2026-05-07_02-00-00

# Restore a single database from a backup
./mongodb-restore.sh /var/backups/mongodb/2026-05-07_02-00-00/mydb

# Restore a single collection archive
./mongodb-restore.sh /var/backups/mongodb/2026-05-07_02-00-00/mydb/users.archive.gz

# Dry-run to preview what would be restored
./mongodb-restore.sh --dry-run /var/backups/mongodb/2026-05-07_02-00-00

# Drop existing collections before restoring, and remap namespace
./mongodb-restore.sh \
  --mongo-restore-flags="--drop --nsFrom=old.* --nsTo=new.*" \
  /var/backups/mongodb/2026-05-07_02-00-00

# Restore multiple paths in one call
./mongodb-restore.sh \
  --input /var/backups/mongodb/2026-05-07_02-00-00/mydb \
  --input /var/backups/mongodb/2026-05-07_02-00-00/otherdb
```

---

## mongodb-compare.sh

Compares two MongoDB servers/clusters for collection-level synchronization. Identifies missing collections, document count mismatches, and index count differences.

### Output

Generates three sections:

1. **Source server table**: Database/collection counts, document counts, index counts, min/max `_id` values
2. **Target server table**: Same metrics as source
3. **Comparison table**: Status (`OK`, `DIFF`, `MISSING_SRC`, `MISSING_TGT`), with concise mismatch reasons

### Usage

```
./mongodb-compare.sh --target-uri <uri> [OPTIONS]

Options:
  --config <file>     Path to config file (default: mongodb-archivist.conf)
  --target-uri <uri>  Target MongoDB URI (required)
  --source-uri <uri>  Source MongoDB URI (overrides mongo_uri from config)
  --exclude-dbs <csv> Comma-separated DB names to exclude (appended to config list)
  --only-dbs <csv>    Comma-separated DB names to scan only (ignores exclude list)
  --version           Show script version and exit
  -v / -vv / -vvv     Increase log verbosity
  --help              Show help (add -v to also print current config values)
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All collections are in sync |
| `2` | Differences found (missing collections or metric mismatches) |
| `1` | Runtime error (config, connection, or query failure) |

### Examples

```bash
# Compare source (from config) to target
./mongodb-compare.sh --target-uri mongodb://target-server:27017/

# Override source URI and compare specific databases only
./mongodb-compare.sh \
  --source-uri mongodb://prod-server:27017/ \
  --target-uri mongodb://staging-server:27017/ \
  --only-dbs=production,metrics,analytics

# Compare with extra exclusions
./mongodb-compare.sh \
  --target-uri mongodb://target-server:27017/ \
  --exclude-dbs=test,staging,temporary

# Verbose output for debugging
./mongodb-compare.sh \
  --target-uri mongodb://target-server:27017/ \
  -vv

# Use in scripts (check exit code)
if ./mongodb-compare.sh --target-uri mongodb://target:27017/; then
  echo "Servers are in sync"
else
  echo "Differences found (exit code: $?)"
fi
```

### Metrics explained

- **DOC_COUNT**: Number of documents in the collection (from `estimatedDocumentCount()` or fallback to `countDocuments()`)
- **INDEXES**: Number of indexes on the collection
- **MIN_ID** / **MAX_ID**: Minimum and maximum `_id` values (in sort order), works for ObjectId and other types
- **STATUS**:
  - `OK`: Metrics match exactly between source and target
  - `DIFF`: One or more metrics differ (doc count, index count, or _id bounds)
  - `MISSING_SRC`: Collection exists on target but not on source
  - `MISSING_TGT`: Collection exists on source but not on target

---

## Verbosity levels

Both scripts share the same verbosity model:

| Flag | Level | Output |
|------|-------|--------|
| _(none)_ | 1 | Normal progress → stdout + log file |
| `-v` | 2 | Verbose → stderr + log file |
| `-vv` | 3 | Very verbose → stderr + log file |
| `-vvv` | 4 | Debug → stderr + log file |

Passwords in the MongoDB URI are always redacted in all log output.
