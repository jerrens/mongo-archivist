#!/usr/bin/env bash
# =============================================================================
# mongodb-restore.sh
# Restore MongoDB archive backups created by mongodb-backup.sh.
#
# Usage:
#   ./mongodb-restore.sh [OPTIONS] <path> [path ...]
#
# Path targets may be:
#   - timestamp directory: restore all *.archive.gz under it (recursive)
#   - database directory: restore all *.archive.gz under it (recursive)
#   - archive file: restore one collection archive (*.archive.gz)
#
# Options:
#   --dry-run   Execute mongorestore with --dryRun for detailed preview
#   -v/-vv/-vvv Increase log verbosity (default: 1, -v=2, -vv=3, -vvv=4)
# =============================================================================

set -euo pipefail

__Author="Jerren Saunders"
__Version="26.5.21"
__ExePath="$0" # Executable path as called
__ScriptName=$(basename "$0") # File name with extension
__AppDir=$(dirname "$0") # Path where script is stored
__AppName=${__ScriptName%.*} # File name without extension

# =============================================================================
# CONFIGURATION — loaded from INI file
# =============================================================================
MONGO_URI=""
BACKUP_ROOT=""
MONGORESTORE_CMD="mongorestore"

CONFIG_FILE=""

# =============================================================================
# INTERNAL
# =============================================================================
SCRIPT_START_TIME="$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""

DRY_RUN=false
VERBOSE=1
HELP_REQUESTED=false
MONGO_RESTORE_FLAGS=""
ABORT_REQUESTED=false
CURRENT_CHILD_PID=""

TOTAL=0
SUCCEEDED=0
FAILED=0
DRY_RUN_COUNT=0

declare -a INPUT_PATHS=()
declare -a RESOLVED_ARCHIVES=()
declare -A SEEN_ARCHIVES=()
declare -a EXTRA_RESTORE_ARGS=()

handle_interrupt() {
    if [[ "$ABORT_REQUESTED" == true ]]; then
        return
    fi

    ABORT_REQUESTED=true
    log 0 ""
    log 0 "[WARN ] Interrupt received (CTRL+C). Aborting cleanly..."

    if [[ -n "$CURRENT_CHILD_PID" ]] && kill -0 "$CURRENT_CHILD_PID" 2>/dev/null; then
        kill -INT "$CURRENT_CHILD_PID" 2>/dev/null || true
    fi
}

trap 'handle_interrupt' INT

# log <level> <message>
# Prints message only when VERBOSE >= level.
#   0 = always print (errors, critical output)
#   1 = normal progress (default)
#   2 = verbose  (-v)       -> stderr
#   3 = very verbose  (-vv) -> stderr
#   4 = debug  (-vvv)       -> stderr
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

        if [[ -n "${LOG_FILE:-}" ]]; then
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

        if [[ -n "${LOG_FILE:-}" ]]; then
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
# Returns shell-escaped single command fragment.
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
# Redacts secrets from command string before logging.
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

# map_archive_path_for_restore <archive>
# Maps host archive path to container-visible path when BACKUP_VOLUME is used.
map_archive_path_for_restore() {
    local archive="$1"

    if [[ "$MONGORESTORE_CMD" != *"BACKUP_VOLUME"* ]]; then
        echo "$archive"
        return
    fi

    local container_backup_root
    local host_backup_root_clean
    container_backup_root="$(backup_root_container_path "$BACKUP_ROOT")"
    host_backup_root_clean="$BACKUP_ROOT"

    while [[ "$host_backup_root_clean" == ./* ]]; do
        host_backup_root_clean="${host_backup_root_clean#./}"
    done

    # Archive provided using same style as BACKUP_ROOT from config.
    if [[ "$archive" == "$BACKUP_ROOT"/* ]]; then
        echo "${container_backup_root}/${archive#${BACKUP_ROOT}/}"
        return
    fi

    # Archive already points to container-style absolute path for relative backup roots.
    if [[ "$archive" == "/${host_backup_root_clean}"/* ]]; then
        echo "$archive"
        return
    fi

    # Archive provided as absolute host path while backup_root is relative.
    if [[ "$BACKUP_ROOT" != /* && "$archive" == /* ]]; then
        local host_backup_root_abs=""
        if command -v realpath >/dev/null 2>&1; then
            host_backup_root_abs="$(realpath "$BACKUP_ROOT" 2>/dev/null || true)"
        fi

        if [[ -z "$host_backup_root_abs" ]] && command -v readlink >/dev/null 2>&1; then
            host_backup_root_abs="$(readlink -f "$BACKUP_ROOT" 2>/dev/null || true)"
        fi

        if [[ -n "$host_backup_root_abs" && "$archive" == "$host_backup_root_abs"/* ]]; then
            echo "${container_backup_root}/${archive#${host_backup_root_abs}/}"
            return
        fi
    fi

    echo "$archive"
}

# build_mongorestore_command <archive> [stderr_file]
# Builds exact shell command string used for mongorestore execution.
build_mongorestore_command() {
    local archive="$1"
    local stderr_file="${2:-}"
    local archive_for_cmd

    local restore_cmd
    local cmd
    local extra_args_str=""

    restore_cmd="$(resolve_backup_volume_placeholder "$MONGORESTORE_CMD")"
    archive_for_cmd="$(map_archive_path_for_restore "$archive")"
    cmd="${restore_cmd} --uri=$(shell_double_quote "$MONGO_URI") $(shell_join \
        --archive="$archive_for_cmd" \
        --gzip)"

    if [[ "$DRY_RUN" == true ]]; then
        cmd+=" $(shell_join --dryRun)"
    fi

    if (( ${#EXTRA_RESTORE_ARGS[@]} > 0 )); then
        extra_args_str="$(shell_join "${EXTRA_RESTORE_ARGS[@]}")"
        cmd+=" ${extra_args_str}"
    fi

    if [[ -n "$stderr_file" ]]; then
        cmd+=" 2>$(shell_join "$stderr_file")"
    fi

    echo "$cmd"
}

print_usage() {
    cat <<EOF
Usage: ${__ScriptName} [OPTIONS] <path> [path ...]

Restore MongoDB collection archives (*.archive.gz) created by mongodb-backup.sh.

Path inputs (one or many):
  - backup folder (restores all archives recursively)
  - database folder (restores all archives recursively)
  - individual *.archive.gz files

Options:
  --config <file>            Path to config file (optional)
                               Defaults to <script-dir>/mongodb-archivist.conf
  --input <path>             Add an input path (can repeat)
  --mongo-restore-flags <s>  Raw flags passed to mongorestore
                               Example: --mongo-restore-flags="--drop --nsFrom=old.* --nsTo=new.*"
  --dry-run                  Run mongorestore with --dryRun
  --version                  Show script version and exit
  -v                         Increase verbosity (repeat: -v, -vv, -vvv)
  --help                     Show this help message and exit
                               Use -v --help to see current config file values

Configuration file (simple key=value format):
  mongo_uri=mongodb://user:pass@host/
  backup_root=/path/to/backups
  mongorestore_cmd=mongorestore
        - If mongorestore_cmd contains BACKUP_VOLUME, script replaces it with:
            --volume <backup_root>:<container_backup_root>
            Example:
            backup_root=./scratch/backups -> --volume ./scratch/backups:/scratch/backups
            backup_root=/var/backups/mongodb -> --volume /var/backups/mongodb:/var/backups/mongodb

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
        --input)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --input requires a path" >&2
                exit 1
            fi
            shift
            INPUT_PATHS+=("$1")
            ;;
        --mongo-restore-flags)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --mongo-restore-flags requires a value" >&2
                exit 1
            fi
            shift
            # Allow multiple --mongo-restore-flags by concatenating with space
            if [[ -n "$MONGO_RESTORE_FLAGS" ]]; then
                MONGO_RESTORE_FLAGS+=" $1"
            else
                MONGO_RESTORE_FLAGS="$1"
            fi
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
        # End-of-options marker: everything after -- is a positional argument,
        # not an option flag. Shift to remove --, add all remaining args, break.
        --)
            shift
            INPUT_PATHS+=("$@")
            break
            ;;
        # Unrecognized option starting with dash
        -*)
            echo "Unknown option: $arg" >&2
            print_usage >&2
            exit 1
            ;;
        # Positional argument (path)
        *)
            INPUT_PATHS+=("$arg")
            ;;
    esac
    shift
done

# Resolve config file path if not provided.
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="${__AppDir}/mongodb-archivist.conf"
fi

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

    while IFS='=' read -r key value; do
        (( line_no++ )) || true
        log 4 "[CFG ] Raw line ${line_no}: key='${key}' value='${value}'"

        key="${key#[ $'\t']}"
        key="${key%[ $'\t']}"
        value="${value#[ $'\t']}"
        value="${value%[ $'\t']}"

        key="${key%$'\r'}"
        value="${value%$'\r'}"

        if [[ -z "$key" || "$key" == \#* ]]; then
            (( ignored_lines++ )) || true
            continue
        fi

        if [[ "$value" == "\""* && "$value" == *"\"" ]]; then
            value="${value#\"}"
            value="${value%\"}"
        fi

        case "${key,,}" in
            mongo_uri)
                MONGO_URI="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] Applied key 'mongo_uri'"
                ;;
            backup_root)
                BACKUP_ROOT="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] Applied key 'backup_root'"
                ;;
            mongorestore_cmd)
                MONGORESTORE_CMD="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] Applied key 'mongorestore_cmd'"
                ;;
            mongodump_cmd)
                log 3 "[CFG ] Ignoring key 'mongodump_cmd' for restore script"
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
        errors+="  - MONGO_URI is required\\n"
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
    echo " MONGORESTORE_CMD           : ${MONGORESTORE_CMD}"
    echo "================================================="
    echo ""
}

check_prerequisites() {
    local ok=true

    local mongorestore_bin
    mongorestore_bin="$(echo "$MONGORESTORE_CMD" | awk '{print $1}')"
    if ! command -v "$mongorestore_bin" &>/dev/null; then
        echo "ERROR: mongorestore command not found: '${MONGORESTORE_CMD}'" >&2
        ok=false
    fi

    if [[ "$ok" == false ]]; then
        exit 1
    fi
}

add_archive_if_new() {
    local archive="$1"
    if [[ -z "${SEEN_ARCHIVES[$archive]:-}" ]]; then
        SEEN_ARCHIVES[$archive]=1
        RESOLVED_ARCHIVES+=("$archive")
        log 3 "[SCAN] Added archive: ${archive}"
    else
        log 3 "[SCAN] Duplicate archive ignored: ${archive}"
    fi
}

collect_archives_from_input() {
    local input_path="$1"

    if [[ ! -e "$input_path" ]]; then
        log 0 "[ERROR] Input path not found: ${input_path}"
        return 1
    fi

    if [[ -f "$input_path" ]]; then
        if [[ "$input_path" != *.archive.gz ]]; then
            log 0 "[ERROR] Input file is not a .archive.gz file: ${input_path}"
            return 1
        fi

        if [[ ! -r "$input_path" ]]; then
            log 0 "[ERROR] Input file not readable: ${input_path}"
            return 1
        fi

        add_archive_if_new "$input_path"
        return 0
    fi

    if [[ -d "$input_path" ]]; then
        local found_any=false
        while IFS= read -r -d '' archive; do
            found_any=true
            add_archive_if_new "$archive"
        done < <(find "$input_path" -type f -name '*.archive.gz' -print0 | sort -z)

        if [[ "$found_any" == false ]]; then
            log 1 "[WARN ] No archive files found under directory: ${input_path}"
        fi
        return 0
    fi

    log 0 "[ERROR] Unsupported input type: ${input_path}"
    return 1
}

parse_mongo_restore_flags() {
    EXTRA_RESTORE_ARGS=()
    if [[ -n "$MONGO_RESTORE_FLAGS" ]]; then
        # Flags are provided as a shell-like string and split on whitespace.
        # Use quotes in the invoking shell to preserve intended grouping.
        read -r -a EXTRA_RESTORE_ARGS <<< "$MONGO_RESTORE_FLAGS"
    fi
}

execute_restore() {
    local archive="$1"
    local stderr_file
    stderr_file="${archive}.restore.stderr.$$"

    local cmd
    cmd="$(build_mongorestore_command "$archive" "$stderr_file")"
    log_stderr 2 "  CMD      ${archive}: $(sanitize_command_for_log "$cmd")"

    eval "$cmd" &
    CURRENT_CHILD_PID="$!"

    local rc=0
    if wait "$CURRENT_CHILD_PID"; then
        rc=0
    else
        rc=$?
    fi
    CURRENT_CHILD_PID=""

    if [[ "$ABORT_REQUESTED" == true ]] || (( rc == 130 )); then
        rm -f "$stderr_file"
        return 130
    fi

    if (( rc == 0 )); then
        rm -f "$stderr_file"
        return 0
    fi

    if (( VERBOSE >= 2 )); then
        if [[ -s "$stderr_file" ]]; then
            while IFS= read -r line; do
                log 2 "  STDERR   ${archive}: ${line}"
            done < "$stderr_file"
        else
            log 2 "  STDERR   ${archive}: <no stderr output>"
        fi
    fi

    rm -f "$stderr_file"
    return "$rc"
}

if [[ "$HELP_REQUESTED" == true ]]; then
    print_usage
    if (( VERBOSE >= 2 )) && [[ -f "$CONFIG_FILE" ]]; then
        load_config_file "$CONFIG_FILE" 2>/dev/null || true
        print_config_values
    fi
    exit 0
fi

if [[ ${#INPUT_PATHS[@]} -eq 0 ]]; then
    echo "ERROR: At least one restore path is required." >&2
    print_usage >&2
    exit 1
fi

main() {
    load_config_file "$CONFIG_FILE"
    validate_config
    check_prerequisites
    parse_mongo_restore_flags

    LOG_FILE=""

    log 0 "=================================================="
    log 0 " MongoDB Restore — ${SCRIPT_START_TIME}"
    log 0 " Dry-run: ${DRY_RUN}  |  Verbosity: ${VERBOSE}"
    log 0 "=================================================="

    local input_errors=0
    for input_path in "${INPUT_PATHS[@]}"; do
        if [[ "$ABORT_REQUESTED" == true ]]; then
            break
        fi

        log 1 "Scanning input: ${input_path}"
        if ! collect_archives_from_input "$input_path"; then
            (( input_errors++ )) || true
        fi
    done

    if (( input_errors > 0 )); then
        log 0 "[ERROR] One or more input paths were invalid."
        exit 1
    fi

    if [[ ${#RESOLVED_ARCHIVES[@]} -eq 0 ]]; then
        log 0 "[ERROR] No archive files found to restore."
        exit 1
    fi

    mapfile -t RESOLVED_ARCHIVES < <(printf '%s\n' "${RESOLVED_ARCHIVES[@]}" | sort)

    log 1 "Archive files to process: ${#RESOLVED_ARCHIVES[@]}"

    for archive in "${RESOLVED_ARCHIVES[@]}"; do
        if [[ "$ABORT_REQUESTED" == true ]]; then
            break
        fi

        (( TOTAL++ )) || true
        log 1 "  START    ${archive}"

        if execute_restore "$archive"; then
            log 1 "  DONE     ${archive}"
            (( SUCCEEDED++ )) || true
            if [[ "$DRY_RUN" == true ]]; then
                (( DRY_RUN_COUNT++ )) || true
            fi
        else
            local rc=$?
            if (( rc == 130 )) || [[ "$ABORT_REQUESTED" == true ]]; then
                break
            fi

            log 0 "[ERROR]   FAILED   ${archive}"
            (( FAILED++ )) || true
        fi
    done

    log 0 ""
    log 0 "=================================================="
    log 0 " SUMMARY"
    log 0 "--------------------------------------------------"
    log 0 " Total archives      : ${TOTAL}"
    log 0 " Succeeded           : ${SUCCEEDED}"
    log 0 " Failed              : ${FAILED}"
    if [[ "$DRY_RUN" == true ]]; then
        log 0 " Dry-run operations  : ${DRY_RUN_COUNT}"
    fi
    if [[ "$ABORT_REQUESTED" == true ]]; then
        log 0 " Aborted             : yes"
    fi
    log 0 "=================================================="

    if [[ "$ABORT_REQUESTED" == true ]]; then
        exit 130
    fi

    if (( FAILED > 0 )); then
        exit 1
    fi

    exit 0
}

main "$@"
