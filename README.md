# MongoDB Backup & Restore Scripts

Bash scripts for backing up and restoring all MongoDB databases and collections to timestamped, per-collection compressed archives.

## Files

| File | Description |
|------|-------------|
| `mongodb-backup.sh` | Dumps all MongoDB databases/collections to `.archive.gz` files |
| `mongodb-restore.sh` | Restores archives created by `mongodb-backup.sh` |
| `mongodb-backup.conf` | Your local configuration file (not committed) |
| `mongodb-backup.conf.example` | Template — copy to `mongodb-backup.conf` and fill in values |

---

## Configuration

Both scripts share the same config file. Copy the example and edit it:

```bash
cp mongodb-backup.conf.example mongodb-backup.conf
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
  --config <file>  Path to config file (default: mongodb-backup.conf)
  --resume         Reuse the newest backup folder; skip collections that
                   already have a .archive.gz (safe re-run after interruption)
  --dry-run        Print what would be done without executing any mongodump
  --version        Show script version and exit
  -v / -vv / -vvv  Increase log verbosity
  --help           Show help (add -v to also print current config values)
```

### Examples

```bash
# Standard backup using mongodb-backup.conf
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
  --config <file>             Path to config file (default: mongodb-backup.conf)
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

## Verbosity levels

Both scripts share the same verbosity model:

| Flag | Level | Output |
|------|-------|--------|
| _(none)_ | 1 | Normal progress → stdout + log file |
| `-v` | 2 | Verbose → stderr + log file |
| `-vv` | 3 | Very verbose → stderr + log file |
| `-vvv` | 4 | Debug → stderr + log file |

Passwords in the MongoDB URI are always redacted in all log output.
