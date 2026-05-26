#!/usr/bin/env bash
# =============================================================================
# mongodb-backup.sh
# Backup all MongoDB databases/collections to timestamped compressed archives.
#
# Usage:
#   ./mongodb-backup.sh [--resume] [--dry-run] [-v|-vv|-vvv]
#
# Options:
#   --resume    Reuse the newest backup folder; skip collections that already
#               have a .archive.gz (allows safe re-run after interruption)
#   --dry-run   Print what would be done without executing any mongodump
#   -v/-vv/-vvv Increase log verbosity (default: 1, -v=2, -vv=3, -vvv=4)
# =============================================================================

set -euo pipefail

__Author="Jerren Saunders"
__Version="26.5.26"
__ExePath="$0" # Executable path as called
__ScriptName=$(basename "$0") # File name with extension
__AppDir=$(dirname "$0") # Path where script is stored
__AppName=${__ScriptName%.*} # File name without extension

# =============================================================================
# CONFIGURATION — loaded from INI file
# =============================================================================
# Default values (used if not specified in config file)
MONGO_URI=""
BACKUP_ROOT=""
SOURCE_URI=""  # Override MONGO_URI via command line
PARALLEL_JOBS=4
EXCLUDE_DATABASES="admin config local"
FALLBACK_REQUIRED_BYTES=$(( 50 * 1024 * 1024 * 1024 ))
MONGOSH_CMD="mongosh"
MONGODUMP_CMD="mongodump"

CONFIG_FILE=""

# =============================================================================
# INTERNAL — do not edit below unless you know what you are doing
# =============================================================================

SCRIPT_START_TIME="$(date +%Y%m%d_%H%M%S)"
# BACKUP_DIR and LOG_FILE are resolved in main() after argument parsing
BACKUP_DIR=""
LOG_FILE=""

RESUME=false
DRY_RUN=false
VERBOSE=1
HELP_REQUESTED=false
ABORT_REQUESTED=false

# Counters (modified only in main process)
TOTAL=0
SKIPPED=0
SUCCEEDED=0
FAILED=0

# Job tracking
declare -a PIDS=()
declare -A PID_LABEL=()   # pid → "db/collection"
declare -A PID_STATUS=()  # pid → exit code (populated after wait)

handle_interrupt() {
    if [[ "$ABORT_REQUESTED" == true ]]; then
        return
    fi

    ABORT_REQUESTED=true
    log 0 ""
    log 0 "[WARN ] Interrupt received (CTRL+C). Aborting cleanly..."

    local pid
    for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -INT "$pid" 2>/dev/null || true
        fi
    done
}

trap 'handle_interrupt' INT

# log <level> <message>
# Prints message only when VERBOSE >= level.
#   0 = always print (errors, critical output)
#   1 = normal progress (default)
#   2 = verbose  (-v)       → stderr
#   3 = very verbose  (-vv) → stderr
#   4 = debug  (-vvv)       → stderr
log() {
    local level="$1"
    local msg="$2"
    if (( VERBOSE >= level )); then
        local ts
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        local line="[${ts}] ${msg}"

        if (( level >= 2 )); then
            echo "$line" >&2
        else
            echo "$line"
        fi

        # Print to the log file if it has been defined and exists
        if [[ -n "${LOG_FILE:-}" ]] && [[ -f "$LOG_FILE" ]]; then
            echo "$line" >> "$LOG_FILE"
        fi
    fi
}

# log_stderr <level> <message>
# Same as log(), but always writes to stderr for pipeline-safe diagnostics.
log_stderr() {
    local level="$1"
    local msg="$2"
    if (( VERBOSE >= level )); then
        local ts
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        local line="[${ts}] ${msg}"

        echo "$line" >&2

        if [[ -n "${LOG_FILE:-}" ]] && [[ -f "$LOG_FILE" ]]; then
            echo "$line" >> "$LOG_FILE"
        fi
    fi
}

# redact_uri <uri>
# Replaces the password component of a MongoDB URI with REDACTED.
# e.g. mongodb://user:secret@host:27017/ → mongodb://user:REDACTED@host:27017/
redact_uri() {
    echo "$1" | sed 's|\(://[^:@]*\):[^@]*@|\1:REDACTED@|'
}

# shell_join <arg1> [arg2 ...]
# Returns a shell-escaped single command fragment.
shell_join() {
    local out=""
    local arg
    for arg in "$@"; do
        out+=" $(printf '%q' "$arg")"
    done
    echo "${out# }"
}

# shell_double_quote <value>
# Returns value wrapped in double quotes with shell-safe escaping.
shell_double_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\$}"
    s="${s//\`/\\\`}"
    printf '"%s"' "$s"
}

# sanitize_command_for_log <cmd>
# Redacts secrets from a command string before logging.
sanitize_command_for_log() {
    local cmd="$1"
    if [[ -n "${MONGO_URI:-}" ]]; then
        cmd="${cmd//${MONGO_URI}/$(redact_uri "${MONGO_URI}")}"
    fi
    echo "$cmd"
}

# backup_root_container_path
# Converts BACKUP_ROOT into container path for volume bind.
# - Absolute host paths stay same in container.
# - Relative host paths (e.g. ./scratch/backups) map to absolute container paths (/scratch/backups).
backup_root_container_path() {
    local path="$1"

    if [[ "$path" == /* ]]; then
        echo "$path"
        return
    fi

    # Strip leading ./ segments and force absolute path in container.
    while [[ "$path" == ./* ]]; do
        path="${path#./}"
    done

    echo "/${path}"
}

# resolve_backup_volume_placeholder <command>
# Replaces BACKUP_VOLUME token with --volume <host_backup_root>:<container_backup_root>.
resolve_backup_volume_placeholder() {
    local command="$1"

    if [[ "$command" != *"BACKUP_VOLUME"* ]]; then
        echo "$command"
        return
    fi

    local container_backup_root
    local mount_spec
    local replacement

    container_backup_root="$(backup_root_container_path "$BACKUP_ROOT")"
    mount_spec="${BACKUP_ROOT}:${container_backup_root}"
    replacement="--volume $(shell_join "$mount_spec")"

    echo "${command//BACKUP_VOLUME/${replacement}}"
}

# build_mongodump_command <db> <collection> <target> [stderr_file]
# Builds the exact shell command string used for mongodump execution.
build_mongodump_command() {
    local db="$1"
    local collection="$2"
    local target="$3"
    local stderr_file="${4:-}"

    local dump_cmd
    local cmd

    dump_cmd="$(resolve_backup_volume_placeholder "$MONGODUMP_CMD")"
    cmd="${dump_cmd} --uri=$(shell_double_quote "$MONGO_URI") $(shell_join \
        --db="$db" \
        --collection="$collection" \
        --archive="$target" \
        --gzip \
        --quiet)"

    if [[ -n "$stderr_file" ]]; then
        cmd+=" 2>$(shell_join "$stderr_file")"
    fi

    echo "$cmd"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
print_usage() {
    cat <<EOF
Usage: ${__ScriptName} [OPTIONS]

Backup all MongoDB databases and collections to timestamped compressed archives.
Each collection is exported via mongodump and stored as a .archive.gz file under:

  BACKUP_ROOT/
    YYYY-MM-DD_HH-MM-SS/
      <database>/
        <collection>.archive.gz

Options:
  --config <file> Path to config file (optional)
                    Defaults to <script-dir>/mongodb-archivist.conf if not provided
  --source-uri <uri> MongoDB source URI (overrides mongo_uri from config file)
  --resume        Reuse the newest backup folder; skip collections that already
                    have a .archive.gz (allows safe re-run after interruption)
  --dry-run       Print what would be done without executing any mongodump
  --version       Show script version and exit
  -v              Increase verbosity (may be repeated: -v, -vv, -vvv)
                    default (1): normal progress
                    -v    (2): verbose   [goes to stderr]
                    -vv   (3): very verbose [goes to stderr]
                    -vvv  (4): debug     [goes to stderr]
  --help          Show this help message and exit
                  Use -v --help to see current config file values

Configuration File (simple key=value format):

Required keys:
  mongo_uri=mongodb://user:pass@host/
  backup_root=/path/to/backups

Optional keys:
  parallel_jobs=4
  exclude_databases=admin config local
  fallback_required_bytes=53687091200
  mongosh_cmd=mongosh
    mongodump_cmd=mongodump
        - If mongodump_cmd contains BACKUP_VOLUME, script replaces it with:
            --volume <backup_root>:<container_backup_root>
            Example:
            backup_root=./scratch/backups -> --volume ./scratch/backups:/scratch/backups
            backup_root=/var/backups/mongodb -> --volume /var/backups/mongodb:/var/backups/mongodb

Example config file:
  mongo_uri=mongodb://mongoadmin:password@127.0.0.1:27017/
  backup_root=/var/backups/mongodb
  parallel_jobs=4
  exclude_databases=admin config local

Example usage:
    ./${__ScriptName}                              # Uses ./mongodb-archivist.conf if it exists
    ./${__ScriptName} --config backup.conf         # Explicit config file
    ./${__ScriptName} -v --help                    # Show help with config values
    ./${__ScriptName} --dry-run -vv                # Dry-run with verbose output
    ./${__ScriptName} --resume                     # Resume interrupted backup


EOF
}

# Parse arguments: single pass, detect --help and process all options.
while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
        --help)
            HELP_REQUESTED=true
            ;;
        --version)
            echo "${__Version}"
            exit 0
            ;;
        # Options with required argument: shift once to consume the option,
        # then "$1" on next line is the argument value. Loop's final shift handles the argument.
        --config)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --config requires a file path" >&2
                exit 1
            fi
            shift
            CONFIG_FILE="$1"
            ;;
        --source-uri)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --source-uri requires a URI" >&2
                exit 1
            fi
            shift
            SOURCE_URI="$1"
            ;;
        --resume)
            RESUME=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        # Verbosity: -v, -vv, -vvv all match this pattern.
        # Count the number of 'v' characters and add to VERBOSE.
        -v*)
            vs="${arg#-}"
            VERBOSE=$(( VERBOSE + ${#vs} ))
            ;;
        -*)
            echo "Unknown option: $arg" >&2
            print_usage >&2
            exit 1
            ;;
    esac
    shift
done

# Resolve config file path if not provided.
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="${__AppDir}/mongodb-archivist.conf"
fi

# =============================================================================
# CONFIGURATION FILE PARSING
# =============================================================================
load_config_file() {
    local config_file="$1"
    local line_no=0
    local applied_keys=0
    local ignored_lines=0
    local unknown_keys=0

    log 2 "[CFG ] Loading config file: ${config_file}"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: '${config_file}'" >&2
        exit 1
    fi

    if [[ ! -r "$config_file" ]]; then
        echo "ERROR: Configuration file not readable: '${config_file}'" >&2
        exit 1
    fi

    # Simple key=value parser (no sections)
    while IFS='=' read -r key value; do
        (( line_no++ )) || true
        log 3 "[CFG ] Raw line ${line_no}: key='${key}' value='${value}'"

        # Remove leading/trailing whitespace
        key="${key#[ $'\t']}"  # Remove leading whitespace
        key="${key%[ $'\t']}"  # Remove trailing whitespace
        value="${value#[ $'\t']}"  # Remove leading whitespace
        value="${value%[ $'\t']}"  # Remove trailing whitespace

        # Normalize CRLF files by dropping trailing carriage returns.
        key="${key%$'\r'}"
        value="${value%$'\r'}"

        # Skip empty lines and comments
        if [[ -z "$key" || "$key" == \#* ]]; then
            (( ignored_lines++ )) || true
            log 3 "[CFG ] Ignoring line ${line_no} (empty/comment)"
            continue
        fi

        # Unquote value if it's quoted
        if [[ "$value" == "\""* && "$value" == *"\"" ]]; then
            value="${value#\"}"
            value="${value%\"}"
        fi

        # Set the corresponding variable (convert snake_case to UPPER_CASE)
        case "${key,,}" in
            mongo_uri)
                MONGO_URI="$value"
                (( applied_keys++ )) || true
                log 2 "[CFG ] Applied key 'mongo_uri'"
                log 3 "[CFG ] mongo_uri value length: ${#MONGO_URI}"
                ;;
            backup_root)
                BACKUP_ROOT="$value"
                (( applied_keys++ )) || true
                log 2 "[CFG ] Applied key 'backup_root'"
                log 3 "[CFG ] backup_root='${BACKUP_ROOT}'"
                ;;
            parallel_jobs)
                PARALLEL_JOBS="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] parallel_jobs='${PARALLEL_JOBS}'"
                ;;
            exclude_databases)
                EXCLUDE_DATABASES="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] exclude_databases='${EXCLUDE_DATABASES}'"
                ;;
            fallback_required_bytes)
                FALLBACK_REQUIRED_BYTES="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] fallback_required_bytes='${FALLBACK_REQUIRED_BYTES}'"
                ;;
            mongosh_cmd)
                MONGOSH_CMD="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] mongosh_cmd='${MONGOSH_CMD}'"
                ;;
            mongodump_cmd)
                MONGODUMP_CMD="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] mongodump_cmd='${MONGODUMP_CMD}'"
                ;;
            *)
                (( unknown_keys++ )) || true
                log 2 "[CFG ] Unknown config key '${key}' on line ${line_no} (ignored)"
                ;;
        esac
    done < "$config_file"

    log 2 "[CFG ] Config parse summary: lines=${line_no}, applied=${applied_keys}, ignored=${ignored_lines}, unknown=${unknown_keys}"
}

validate_config() {
    local errors=""

    if [[ -z "$MONGO_URI" ]]; then
        errors="${errors}  - MONGO_URI is required\n"
    fi

    if [[ -z "$BACKUP_ROOT" ]]; then
        errors="${errors}  - BACKUP_ROOT is required\n"
    fi

    if [[ -n "$errors" ]]; then
        echo -e "ERROR: Configuration validation failed:\n${errors}" >&2
        exit 1
    fi
}

print_config_values() {
    echo ""
    echo "================================================="
    echo " Current Configuration Values"
    echo "================================================="
    echo " Config file                : ${CONFIG_FILE}"
    echo " MONGO_URI                  : $(redact_uri "${MONGO_URI}")"
    echo " BACKUP_ROOT                : ${BACKUP_ROOT}"
    echo " PARALLEL_JOBS              : ${PARALLEL_JOBS}"
    echo " EXCLUDE_DATABASES          : ${EXCLUDE_DATABASES}"
    echo " FALLBACK_REQUIRED_BYTES    : ${FALLBACK_REQUIRED_BYTES} bytes ($(( FALLBACK_REQUIRED_BYTES / 1024 / 1024 / 1024 )) GB)"
    echo " MONGOSH_CMD                : ${MONGOSH_CMD}"
    echo " MONGODUMP_CMD              : ${MONGODUMP_CMD}"
    echo "================================================="
    echo ""
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================
check_prerequisites() {
    local ok=true

    local mongodump_bin
    mongodump_bin="$(echo "$MONGODUMP_CMD" | awk '{print $1}')"
    if ! command -v "$mongodump_bin" &>/dev/null; then
        echo "ERROR: mongodump command not found: '${MONGODUMP_CMD}'" >&2
        ok=false
    fi

    local mongosh_bin
    mongosh_bin="$(echo "$MONGOSH_CMD" | awk '{print $1}')"
    if ! command -v "$mongosh_bin" &>/dev/null; then
        echo "ERROR: mongosh command not found: '${MONGOSH_CMD}'" >&2
        ok=false
    fi

    if [[ "$ok" == false ]]; then
        exit 1
    fi

    mkdir -p "$BACKUP_ROOT"
    if [[ ! -w "$BACKUP_ROOT" ]]; then
        echo "ERROR: BACKUP_ROOT '${BACKUP_ROOT}' is not writable" >&2
        exit 1
    fi

    # Initialize log file only when not in dry-run mode.
    if [[ "$DRY_RUN" == false ]]; then
        touch "$LOG_FILE"
    fi
}

# =============================================================================
# DISK SPACE CHECK
# =============================================================================
check_disk_space() {
    local required_bytes

    # Find most recent backup timestamp folder (directories only, sort descending)
    local prev_backup
    prev_backup="$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d \
        | sort -r | head -1)"

    if [[ -n "$prev_backup" ]]; then
        local prev_size_kb
        prev_size_kb="$(du -sk "$prev_backup" | awk '{print $1}')"
        local prev_size_bytes=$(( prev_size_kb * 1024 ))
        # Add 5% margin
        required_bytes=$(( prev_size_bytes + prev_size_bytes / 20 ))
        log 1 "Previous backup: ${prev_backup}"
        log 1 "Previous backup size: $(( prev_size_bytes / 1024 / 1024 )) MB"
        log 1 "Required disk (prev * 1.05): $(( required_bytes / 1024 / 1024 )) MB"
    else
        required_bytes="$FALLBACK_REQUIRED_BYTES"
        log 1 "[WARN ] No previous backup found — assuming $(( required_bytes / 1024 / 1024 / 1024 )) GB required"
    fi

    # Available bytes on the filesystem containing BACKUP_ROOT
    local available_kb
    available_kb="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
    local available_bytes=$(( available_kb * 1024 ))

    log 1 "Available disk: $(( available_bytes / 1024 / 1024 )) MB"

    if (( available_bytes < required_bytes )); then
        log 0 "[ERROR] Insufficient disk space. Required: $(( required_bytes / 1024 / 1024 )) MB, Available: $(( available_bytes / 1024 / 1024 )) MB"
        exit 1
    fi

    log 1 "Disk space check passed."
}

# =============================================================================
# MONGODB QUERIES
# =============================================================================
get_databases() {
    # Returns newline-separated list of database names, with exclusions applied
    local exclude_pattern
    exclude_pattern="$(echo "$EXCLUDE_DATABASES" | tr ' ' '|')"

    local js
    js="db.adminCommand({listDatabases:1}).databases.filter(d => !/^(${exclude_pattern})$/.test(d.name)).forEach(d => print(d.name))"

    local cmd
    cmd="${MONGOSH_CMD} --quiet $(shell_double_quote "$MONGO_URI") --eval $(shell_join "$js")"
    log_stderr 2 "  CMD      $(sanitize_command_for_log "$cmd")"

    eval "$cmd" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' || true
}

get_collections() {
    local db="$1"
    # Keep auth context from the original URI; switch DB in mongosh instead.
    local db_escaped="${db//\'/\\\'}"
    local js
    js="db.getSiblingDB('${db_escaped}').getCollectionNames().forEach(c => print(c))"

    local cmd
    cmd="${MONGOSH_CMD} --quiet $(shell_double_quote "$MONGO_URI") --eval $(shell_join "$js")"
    log_stderr 2 "  CMD      $(sanitize_command_for_log "$cmd")"

    eval "$cmd" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

# =============================================================================
# BACKUP A SINGLE COLLECTION (runs in subshell / background job)
# =============================================================================
backup_collection() {
    local db="$1"
    local collection="$2"
    local db_dir="$3"
    local target="${db_dir}/${collection}.archive.gz"
    local stderr_file="${target}.stderr.log.$$"

    local cmd
    cmd="$(build_mongodump_command "$db" "$collection" "$target" "$stderr_file")"
    log_stderr 2 "  CMD      ${db}/${collection}: $(sanitize_command_for_log "$cmd")"

    if eval "$cmd"; then
        # Success: clean up old stderr logs, then clean current log if empty
        rm -f "${target}".stderr.log.* 2>/dev/null || true
        [[ ! -s "$stderr_file" ]] && rm -f "$stderr_file"
        return 0
    fi

    local rc=$?

    if (( VERBOSE >= 2 )); then
        if [[ -s "$stderr_file" ]]; then
            while IFS= read -r line; do
                log 2 "  STDERR   ${db}/${collection}: ${line}"
            done < "$stderr_file"
        else
            log 2 "  STDERR   ${db}/${collection}: <no stderr output>"
        fi
    fi

    [[ ! -s "$stderr_file" ]] && rm -f "$stderr_file"
    return "$rc"
}

# =============================================================================
# CONCURRENCY HELPERS
# =============================================================================

# Wait until fewer than PARALLEL_JOBS background jobs are running.
# Only checks process status; does not reap. Reaping is handled by reap_finished_jobs().
wait_for_job_slot() {
    while (( ${#PIDS[@]} >= PARALLEL_JOBS )); do
        if [[ "$ABORT_REQUESTED" == true ]]; then
            break
        fi

        local new_pids=()
        for pid in "${PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            fi
        done
        PIDS=("${new_pids[@]+"${new_pids[@]}"}")
        (( ${#PIDS[@]} < PARALLEL_JOBS )) && break
        sleep 0.2
    done
}

# Wait for all remaining background jobs to complete.
drain_jobs() {
    for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
        wait "$pid" && PID_STATUS[$pid]=0 || PID_STATUS[$pid]=$?
    done
    PIDS=()
}

# Evaluate finished-job outcomes and update counters + log.
# Idempotent: only waits on processes that haven't been reaped yet (checks PID_STATUS).
reap_finished_jobs() {
    local new_pids=()
    for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
        if kill -0 "$pid" 2>/dev/null; then
            new_pids+=("$pid")
        else
            # Only wait if we haven't already reaped this pid
            if [[ -z "${PID_STATUS[$pid]:-}" ]]; then
                wait "$pid" && PID_STATUS[$pid]=0 || PID_STATUS[$pid]=$?
            fi
            local label="${PID_LABEL[$pid]}"
            if [[ "${PID_STATUS[$pid]}" -eq 0 ]]; then
                log 1 "  DONE     ${label}"
                (( SUCCEEDED++ )) || true
            else
                log 0 "[ERROR]   FAILED   ${label} (exit ${PID_STATUS[$pid]})"
                (( FAILED++ )) || true
            fi
            unset "PID_LABEL[$pid]"
        fi
    done
    PIDS=("${new_pids[@]+"${new_pids[@]}"}")
}


# Handle --help with optional verbose config display
if [[ "$HELP_REQUESTED" == true ]]; then
    print_usage
    # If verbose and config file provided, load and show config values
    if (( VERBOSE >= 2 )) && [[ -f "$CONFIG_FILE" ]]; then
        load_config_file "$CONFIG_FILE" 2>/dev/null || true
        print_config_values
    fi
    exit 0
fi

# =============================================================================
# MAIN
# =============================================================================
main() {
    # Load and validate configuration
    log 2 "[CFG ] About to load configuration from: ${CONFIG_FILE}"
    log 3 "[CFG ] Flags: resume=${RESUME}, dry_run=${DRY_RUN}, verbose=${VERBOSE}"
    load_config_file "$CONFIG_FILE"
    log 2 "[CFG ] Config load completed"
    log 3 "[CFG ] Post-load checks: MONGO_URI_set=$([[ -n "$MONGO_URI" ]] && echo yes || echo no), BACKUP_ROOT='${BACKUP_ROOT}'"

    # Override MONGO_URI with command-line --source-uri if provided
    if [[ -n "$SOURCE_URI" ]]; then
        log 2 "[CFG ] Overriding mongo_uri with --source-uri"
        MONGO_URI="$SOURCE_URI"
    fi

    validate_config
    log 2 "[CFG ] Configuration validation passed"

    # Resolve BACKUP_DIR based on --resume flag
    mkdir -p "$BACKUP_ROOT"
    if [[ "$RESUME" == true ]]; then
        BACKUP_DIR="$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r | head -1)"
        if [[ -z "$BACKUP_DIR" ]]; then
            echo "ERROR: --resume specified but no previous backup found in ${BACKUP_ROOT}" >&2
            exit 1
        fi
    else
        BACKUP_DIR="${BACKUP_ROOT}/${SCRIPT_START_TIME}"
    fi

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$BACKUP_DIR"
    fi

    LOG_FILE="${BACKUP_DIR}/${__AppName}.log"

    log 0 "=================================================="
    log 0 " MongoDB Backup — ${SCRIPT_START_TIME}"
    log 0 " Resume: ${RESUME}  |  Dry-run: ${DRY_RUN}  |  Verbosity: ${VERBOSE}"
    log 0 "=================================================="

    check_prerequisites
    check_disk_space

    if [[ "$DRY_RUN" == false ]]; then
        log 1 "Backup directory: ${BACKUP_DIR}"
    else
        log 1 "[DRY-RUN] Would create backup directory: ${BACKUP_DIR}"
    fi

    log 1 "Fetching database list..."
    mapfile -t databases < <(get_databases)

    if [[ ${#databases[@]} -eq 0 ]]; then
        log 1 "[WARN ] No databases found (after exclusions). Exiting."
        exit 0
    fi

    for db in "${databases[@]}"; do
        if [[ "$ABORT_REQUESTED" == true ]]; then
            break
        fi

        local db_dir="${BACKUP_DIR}/${db}"

        log 1 "--- Database: ${db}"

        mapfile -t collections < <(get_collections "$db")

        if [[ ${#collections[@]} -eq 0 ]]; then
            log 1 "[WARN ]   No collections found in '${db}', skipping."
            continue
        fi

        if [[ "$DRY_RUN" == false ]]; then
            mkdir -p "$db_dir"
        fi

        for collection in "${collections[@]}"; do
            if [[ "$ABORT_REQUESTED" == true ]]; then
                break
            fi

            (( TOTAL++ )) || true
            local label="${db}/${collection}"
            local target="${db_dir}/${collection}.archive.gz"

            # Reap finished jobs and log results (even if we're about to skip this collection)
            # This ensures DONE messages are printed as jobs finish, not batched at the end
            reap_finished_jobs

            # Resume: skip collections that already have a completed archive
            if [[ "$RESUME" == true && -f "$target" && -s "$target" ]]; then
                log 1 "  SKIP     ${label} (exists)"
                (( SKIPPED++ )) || true
                # Clean up any orphaned stderr logs from previous attempts
                rm -f "${target}".stderr.log.*
                continue
            fi

            if [[ "$DRY_RUN" == true ]]; then
                local dry_cmd
                dry_cmd="$(build_mongodump_command "$db" "$collection" "$target")"
                log 1 "  [DRY-RUN] Would dump ${label}"
                log_stderr 2 "  CMD      ${label}: $(sanitize_command_for_log "$dry_cmd")"
                (( SKIPPED++ )) || true
                continue
            fi

            # Wait for a free job slot
            wait_for_job_slot
            if [[ "$ABORT_REQUESTED" == true ]]; then
                break
            fi

            log 1 "  START    ${label}"
            backup_collection "$db" "$collection" "$db_dir" &
            local pid=$!
            PIDS+=("$pid")
            PID_LABEL[$pid]="$label"
        done
    done

    # Drain remaining background jobs
    log 1 "Waiting for remaining jobs to finish..."
    drain_jobs
    # Final reap pass for counters
    for pid in "${!PID_LABEL[@]}"; do
        local label="${PID_LABEL[$pid]}"
        if [[ "${PID_STATUS[$pid]:-}" -eq 0 ]]; then
            log 1 "  DONE     ${label}"
            (( SUCCEEDED++ )) || true
        else
            log 0 "[ERROR]   FAILED   ${label} (exit ${PID_STATUS[$pid]:-?})"
            (( FAILED++ )) || true
        fi
    done

    log 0 ""
    log 0 "=================================================="
    log 0 " SUMMARY"
    log 0 "--------------------------------------------------"
    log 0 " Total collections : ${TOTAL}"
    log 0 " Succeeded         : ${SUCCEEDED}"
    log 0 " Skipped           : ${SKIPPED}"
    log 0 " Failed            : ${FAILED}"
    log 0 " Backup location   : ${BACKUP_DIR}"
    log 0 " Log file          : ${LOG_FILE}"
    if [[ "$ABORT_REQUESTED" == true ]]; then
        log 0 " Aborted           : yes"
    fi
    if [[ "$DRY_RUN" == false && -d "$BACKUP_DIR" ]]; then
        local used
        used="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
        log 0 " Disk used         : ${used}"
    fi
    log 0 "=========================================="
    log 1 "Backup complete. Succeeded: ${SUCCEEDED}, Failed: ${FAILED}, Skipped: ${SKIPPED}"

    if [[ "$ABORT_REQUESTED" == true ]]; then
        exit 130
    fi

    if (( FAILED > 0 )); then
        exit 1
    fi

    exit 0
}

main "$@"
