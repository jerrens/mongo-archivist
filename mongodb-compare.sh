#!/usr/bin/env bash
# =============================================================================
# mongodb-compare.sh
# Compare two MongoDB servers/clusters for collection-level synchronization.
# Identifies schema differences, missing collections, and document/index counts.
#
# Usage:
#   ./mongodb-compare.sh --target-uri <uri> [OPTIONS]
#
# Options:
#   --config <file>     Path to config file (default: mongodb-archivist.conf)
#   --target-uri <uri>  Target MongoDB URI (required)
#   --source-uri <uri>  Source MongoDB URI (overrides mongo_uri from config)
#   --exclude-dbs <csv> Comma-separated list of DBs to exclude (appended to config)
#   --only-dbs <csv>    Comma-separated list of DBs to scan only (ignores excludes)
#   --version           Show script version and exit
#   -v/-vv/-vvv         Increase log verbosity (default: 1, -v=2, -vv=3, -vvv=4)
#   --help              Show this help message and exit
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
# Default values (used if not specified in config file)
MONGO_URI=""
MONGOSH_CMD="mongosh"
EXCLUDE_DATABASES="admin config local"

CONFIG_FILE=""

# =============================================================================
# CLI OVERRIDES — set by argument parsing
# =============================================================================
TARGET_URI=""
SOURCE_URI_OVERRIDE=""
EXTRA_EXCLUDE_DBS=""
ONLY_DBS=""

# =============================================================================
# INTERNAL — do not edit below unless you know what you are doing
# =============================================================================

SCRIPT_START_TIME="$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""

VERBOSE=1
HELP_REQUESTED=false
ABORT_REQUESTED=false
CURRENT_SCAN_PID=""

# Counters and results storage
TOTAL_COLLECTIONS=0
MATCHED_COLLECTIONS=0
DIFF_COLLECTIONS=0
MISSING_SOURCE=0
MISSING_TARGET=0

# Data structure: arrays parallel to source/target collection lists
declare -a SOURCE_DB_NAMES=()
declare -a SOURCE_COLLECTION_NAMES=()
declare -a SOURCE_DOC_COUNTS=()
declare -a SOURCE_INDEX_COUNTS=()
declare -a SOURCE_ID_MIN=()
declare -a SOURCE_ID_MAX=()
declare -a SOURCE_ID_TYPE=()

declare -a TARGET_DB_NAMES=()
declare -a TARGET_COLLECTION_NAMES=()
declare -a TARGET_DOC_COUNTS=()
declare -a TARGET_INDEX_COUNTS=()
declare -a TARGET_ID_MIN=()
declare -a TARGET_ID_MAX=()
declare -a TARGET_ID_TYPE=()

# Composite key map for fast lookups: "db.collection" -> index
declare -A SOURCE_INDEX_MAP=()
declare -A TARGET_INDEX_MAP=()

handle_interrupt() {
    if [[ "$ABORT_REQUESTED" == true ]]; then
        return
    fi

    ABORT_REQUESTED=true
    log 0 ""
    log 0 "[WARN ] Interrupt received (CTRL+C). Aborting cleanly..."

    if [[ -n "$CURRENT_SCAN_PID" ]] && kill -0 "$CURRENT_SCAN_PID" 2>/dev/null; then
        kill -INT "$CURRENT_SCAN_PID" 2>/dev/null || true
    fi
}

trap 'handle_interrupt' INT

# =============================================================================
# LOGGING
# =============================================================================

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

# =============================================================================
# STRING HELPERS
# =============================================================================

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
    if [[ -n "${TARGET_URI:-}" ]]; then
        cmd="${cmd//${TARGET_URI}/$(redact_uri "${TARGET_URI}")}"
    fi
    echo "$cmd"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
print_usage() {
    cat <<EOF
Usage: ${__ScriptName} --target-uri <uri> [OPTIONS]

Compare two MongoDB servers for collection-level synchronization.
Identifies missing collections, document count mismatches, and index differences.

Output:
  - Per-server metric tables (source and target)
  - Combined comparison table showing status and differences
  - Summary with total collections and mismatch counts

Required:
  --target-uri <uri>  Target MongoDB connection URI

Optional:
  --config <file>     Path to config file (default: <script-dir>/mongodb-archivist.conf)
  --source-uri <uri>  Source MongoDB URI (overrides mongo_uri from config)
  --exclude-dbs <csv> Comma-separated DB names to exclude (appended to config list)
                        Example: --exclude-dbs=test,staging
  --only-dbs <csv>    Comma-separated DB names to scan only (ignores exclude list)
                        Example: --only-dbs=production,metrics
  --version           Show script version and exit
  -v                  Increase verbosity (may be repeated: -v, -vv, -vvv)
                        default (1): normal progress
                        -v    (2): verbose   [goes to stderr]
                        -vv   (3): very verbose [goes to stderr]
                        -vvv  (4): debug     [goes to stderr]
  --help              Show this help message and exit
                        Use -v --help to see current config file values

Exit codes:
  0   All collections are in sync
  2   Differences found (missing collections or metric mismatches)
  1   Runtime error (config, connection, or query failure)

Configuration File (simple key=value format, defaults to mongodb-archivist.conf):

Required keys:
  mongo_uri=mongodb://user:pass@host/

Optional keys:
  mongosh_cmd=mongosh
  exclude_databases=admin config local

Example usage:
    ./${__ScriptName} --target-uri mongodb://target:27017/
    ./${__ScriptName} --target-uri mongodb://target:27017/ --source-uri mongodb://prod:27017/
    ./${__ScriptName} --target-uri mongodb://target:27017/ --only-dbs=db1,db2,db3
    ./${__ScriptName} --target-uri mongodb://target:27017/ --exclude-dbs=test,staging
    ./${__ScriptName} --target-uri mongodb://target:27017/ -vv

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
        --config)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --config requires a file path" >&2
                exit 1
            fi
            shift
            CONFIG_FILE="$1"
            ;;
        --target-uri)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --target-uri requires a URI" >&2
                exit 1
            fi
            shift
            TARGET_URI="$1"
            ;;
        --source-uri)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --source-uri requires a URI" >&2
                exit 1
            fi
            shift
            SOURCE_URI_OVERRIDE="$1"
            ;;
        --exclude-dbs)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --exclude-dbs requires a CSV string" >&2
                exit 1
            fi
            shift
            EXTRA_EXCLUDE_DBS="$1"
            ;;
        --only-dbs)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --only-dbs requires a CSV string" >&2
                exit 1
            fi
            shift
            ONLY_DBS="$1"
            ;;
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
            mongosh_cmd)
                MONGOSH_CMD="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] mongosh_cmd='${MONGOSH_CMD}'"
                ;;
            exclude_databases)
                EXCLUDE_DATABASES="$value"
                (( applied_keys++ )) || true
                log 3 "[CFG ] exclude_databases='${EXCLUDE_DATABASES}'"
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

    # After overrides, check which URI is being used
    local source_uri_to_use="${SOURCE_URI_OVERRIDE:-$MONGO_URI}"

    if [[ -z "$source_uri_to_use" ]]; then
        errors="${errors}  - MONGO_URI is required (or --source-uri must be provided)\n"
    fi

    if [[ -z "$TARGET_URI" ]]; then
        errors="${errors}  - --target-uri is required\n"
    fi

    if [[ -n "$errors" ]]; then
        echo -e "ERROR: Configuration validation failed:\n${errors}" >&2
        exit 1
    fi
}

print_config_values() {
    local source_uri_display="${SOURCE_URI_OVERRIDE:-$MONGO_URI}"
    echo ""
    echo "================================================="
    echo " Current Configuration Values"
    echo "================================================="
    echo " Config file                : ${CONFIG_FILE}"
    echo " SOURCE URI                 : $(redact_uri "${source_uri_display}")"
    echo " TARGET URI                 : $(redact_uri "${TARGET_URI}")"
    echo " MONGOSH_CMD                : ${MONGOSH_CMD}"
    echo " EXCLUDE_DATABASES (config) : ${EXCLUDE_DATABASES}"
    if [[ -n "$EXTRA_EXCLUDE_DBS" ]]; then
        echo " EXCLUDE_DATABASES (CLI)    : ${EXTRA_EXCLUDE_DBS}"
    fi
    if [[ -n "$ONLY_DBS" ]]; then
        echo " ONLY_DBS (CLI)             : ${ONLY_DBS}"
    fi
    echo "================================================="
    echo ""
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================
check_prerequisites() {
    local ok=true

    local mongosh_bin
    mongosh_bin="$(echo "$MONGOSH_CMD" | awk '{print $1}')"
    if ! command -v "$mongosh_bin" &>/dev/null; then
        echo "ERROR: mongosh command not found: '${MONGOSH_CMD}'" >&2
        ok=false
    fi

    if [[ "$ok" == false ]]; then
        exit 1
    fi
}

# =============================================================================
# MONGOSH QUERY EXECUTION
# =============================================================================

# build_mongosh_eval_command <uri> <js_code>
# Builds the exact shell command string used for mongosh evaluation.
build_mongosh_eval_command() {
    local uri="$1"
    local js="$2"

    local cmd
    cmd="${MONGOSH_CMD} --quiet $(shell_double_quote "$uri") --eval $(shell_join "$js")"
    echo "$cmd"
}

# =============================================================================
# DATA COLLECTION — SERVER SCANS
# =============================================================================

# build_scan_js <exclude_pattern> <only_dbs>
# Builds JavaScript code for mongosh to scan a server.
# exclude_pattern: regex pattern of DBs to exclude (e.g., "admin|config|local")
# only_dbs: regex pattern of DBs to include only (empty = use exclusion)
# Output: JSON lines (one per collection) with db, collection, count, indexes, minId, maxId, idType
build_scan_js() {
    local exclude_pattern="$1"
    local only_dbs="$2"

    cat <<'ENDJS'
// Determine which databases to scan based on filter mode
let dbsToScan;
ENDJS

    if [[ -n "$only_dbs" ]]; then
        cat <<ENDJS
const onlyDbsRegex = /^(${only_dbs})$/;
dbsToScan = db.adminCommand({listDatabases:1})
  .databases
  .filter(d => onlyDbsRegex.test(d.name))
  .map(d => d.name);
ENDJS
    else
        cat <<ENDJS
const excludeDbsRegex = /^(${exclude_pattern})$/;
dbsToScan = db.adminCommand({listDatabases:1})
  .databases
  .filter(d => !excludeDbsRegex.test(d.name))
  .map(d => d.name);
ENDJS
    fi

    cat <<'ENDJS'

// For each database, scan collections and gather metrics
dbsToScan.forEach(dbName => {
  try {
    const targetDb = db.getSiblingDB(dbName);
        // mongosh compatibility: getCollectionInfos exists across shell variants.
        const collList = targetDb.getCollectionInfos({type: 'collection'});
    
    collList.forEach(collInfo => {
      const collName = collInfo.name;
      try {
        const collection = targetDb[collName];
        
        // Get document count (use estimatedDocumentCount for speed, fall back to countDocuments)
        let docCount;
        try {
          docCount = collection.estimatedDocumentCount();
        } catch (e) {
          docCount = collection.countDocuments({});
        }
        
        // Get index count
        const indexCount = collection.getIndexes().length;
        
        // Get min and max _id values (sorted order)
        let minIdObj = null;
        let maxIdObj = null;
        let idType = 'missing';
        
        try {
          minIdObj = collection.findOne({}, {sort: {_id: 1}, projection: {_id: 1}});
          if (minIdObj) {
            idType = typeof minIdObj._id === 'object' ? 
              (minIdObj._id.constructor ? minIdObj._id.constructor.name : 'object') : 
              typeof minIdObj._id;
          }
        } catch (e) {
          // Ignore find errors
        }
        
        try {
          maxIdObj = collection.findOne({}, {sort: {_id: -1}, projection: {_id: 1}});
        } catch (e) {
          // Ignore find errors
        }
        
                const minIdStr = minIdObj ? EJSON.stringify(minIdObj._id) : 'null';
                const maxIdStr = maxIdObj ? EJSON.stringify(maxIdObj._id) : 'null';
                // Output tab-separated row for robust shell parsing.
                print([
                    'ROW',
                    dbName,
                    collName,
                    String(docCount),
                    String(indexCount),
                    minIdStr,
                    maxIdStr,
                    String(idType)
                ].join('\t'));
        
      } catch (collError) {
                print([
                    'ERR',
                    dbName,
                    collName,
                    String(collError.message || collError)
                ].join('\t'));
      }
    });
    
  } catch (dbError) {
        print([
            'ERR',
            dbName,
            '',
            'DB access failed: ' + String(dbError.message || dbError)
        ].join('\t'));
  }
});
ENDJS
}

# parse_scan_output <row_line> <array_prefix>
# Parses one tab-separated line from mongosh and appends to SOURCE_* or TARGET_* arrays.
# array_prefix: "SOURCE" or "TARGET"
# Returns 0 on success, 1 on error.
parse_scan_output() {
        local row_line="$1"
    local prefix="$2"

    local -n db_names_ref="${prefix}_DB_NAMES"
    local -n collection_names_ref="${prefix}_COLLECTION_NAMES"
    local -n doc_counts_ref="${prefix}_DOC_COUNTS"
    local -n index_counts_ref="${prefix}_INDEX_COUNTS"
    local -n id_min_ref="${prefix}_ID_MIN"
    local -n id_max_ref="${prefix}_ID_MAX"
    local -n id_type_ref="${prefix}_ID_TYPE"
    local -n index_map_ref="${prefix}_INDEX_MAP"

        local kind
    local db
    local collection
    local doc_count
    local index_count
    local min_id
    local max_id
    local id_type
    local error

    IFS=$'\t' read -r kind db collection doc_count index_count min_id max_id id_type error <<< "$row_line"

    if [[ "$kind" == "ERR" ]]; then
        log 2 "  [WARN] ${prefix} ${db}/${collection}: ${error}"
        return 0
    fi

    if [[ "$kind" != "ROW" ]]; then
        log 3 "  [DBG ] Ignoring non-row output: $row_line"
        return 0
    fi

    doc_count="${doc_count:-0}"
    index_count="${index_count:-0}"
    min_id="${min_id:-null}"
    max_id="${max_id:-null}"
    id_type="${id_type:-unknown}"

    # Append to arrays
    db_names_ref+=("$db")
    collection_names_ref+=("$collection")
    doc_counts_ref+=("$doc_count")
    index_counts_ref+=("$index_count")
    id_min_ref+=("$min_id")
    id_max_ref+=("$max_id")
    id_type_ref+=("$id_type")

    # Add to index map for fast lookup
    local key="${db}.${collection}"
    local idx=$(( ${#db_names_ref[@]} - 1 ))
    index_map_ref["$key"]="$idx"

    log 3 "  Parsed ${prefix} ${db}/${collection}: ${doc_count} docs, ${index_count} indexes"

    return 0
}

# print_scan_table <array_prefix> <server_label>
# Prints a formatted table of scan results for one server.
print_scan_table() {
    local prefix="$1"
    local label="$2"

    local -n db_names_ref="${prefix}_DB_NAMES"
    local -n collection_names_ref="${prefix}_COLLECTION_NAMES"
    local -n doc_counts_ref="${prefix}_DOC_COUNTS"
    local -n index_counts_ref="${prefix}_INDEX_COUNTS"
    local -n id_min_ref="${prefix}_ID_MIN"
    local -n id_max_ref="${prefix}_ID_MAX"

    local count=${#db_names_ref[@]}

    if (( count == 0 )); then
        log 1 "  (No collections found)"
        return
    fi

    # Print header
    printf "%-30s %-30s %12s %8s %20s %20s\n" "DATABASE" "COLLECTION" "DOC_COUNT" "INDEXES" "MIN_ID" "MAX_ID"
    printf "%-30s %-30s %12s %8s %20s %20s\n" "$(printf '=%.0s' {1..30})" "$(printf '=%.0s' {1..30})" "$(printf '=%.0s' {1..12})" "$(printf '=%.0s' {1..8})" "$(printf '=%.0s' {1..20})" "$(printf '=%.0s' {1..20})"

    local i
    for (( i=0; i<count; i++ )); do
        local db_name="${db_names_ref[$i]}"
        local coll_name="${collection_names_ref[$i]}"
        local doc_count="${doc_counts_ref[$i]}"
        local index_count="${index_counts_ref[$i]}"
        local id_min="${id_min_ref[$i]}"
        local id_max="${id_max_ref[$i]}"

        # Truncate long values for display
        [[ ${#id_min} -gt 20 ]] && id_min="${id_min:0:17}..."
        [[ ${#id_max} -gt 20 ]] && id_max="${id_max:0:17}..."

        printf "%-30s %-30s %12s %8s %20s %20s\n" "$db_name" "$coll_name" "$doc_count" "$index_count" "$id_min" "$id_max"
    done

    log 1 "  Total: ${count} collections"
}

# scan_server <uri> <server_label>
# Scans the given MongoDB server and populates the corresponding arrays.
# Uses SOURCE_* or TARGET_* arrays based on context.
# Returns 0 on success, 1 on error.
scan_server() {
    local uri="$1"
    local label="$2"

    log 1 ""
    log 1 "=== Scanning ${label} ==="
    log 1 ""

    # Determine which arrays to populate
    local prefix
    if [[ "$label" == "Source" ]]; then
        prefix="SOURCE"
    else
        prefix="TARGET"
    fi

    # Build exclude pattern from EXCLUDE_DATABASES config
    local exclude_pattern
    exclude_pattern="$(echo "$EXCLUDE_DATABASES" | tr ' ' '|')"

    # Build scan JS code
    local scan_js
    scan_js="$(build_scan_js "$exclude_pattern" "$ONLY_DBS")"

    # Execute scan
    local cmd
    cmd="$(build_mongosh_eval_command "$uri" "$scan_js")"
    log_stderr 2 "  CMD      $(sanitize_command_for_log "$cmd")"

    # Run scan and parse output
    local line_count=0
    local scan_output_file
    scan_output_file="$(mktemp)"

    eval "$cmd" >"$scan_output_file" 2>/dev/null &
    CURRENT_SCAN_PID="$!"

    local scan_rc=0
    if wait "$CURRENT_SCAN_PID"; then
        scan_rc=0
    else
        scan_rc=$?
    fi
    CURRENT_SCAN_PID=""

    if [[ "$ABORT_REQUESTED" == true ]] || (( scan_rc == 130 )); then
        rm -f "$scan_output_file"
        return 130
    fi

    if (( scan_rc != 0 )); then
        rm -f "$scan_output_file"
        return 1
    fi

    while IFS= read -r line; do
        (( line_count++ )) || true
        if [[ -n "$line" ]]; then
            if ! parse_scan_output "$line" "$prefix"; then
                rm -f "$scan_output_file"
                log 0 "[ERROR] Failed to parse output line ${line_count}"
                return 1
            fi
        fi
    done < "$scan_output_file"

    rm -f "$scan_output_file"

    if (( line_count == 0 )); then
        log 2 "  [WARN] No collections found during scan (check connectivity and filters)"
    fi

    # Print results table
    print_scan_table "$prefix" "$label"

    return 0
}

# =============================================================================
# COMPARISON AND REPORTING
# =============================================================================

# ids_equal <id1> <id2>
# Compares two _id values (as JSON strings).
# Returns 0 if equal, 1 if different.
ids_equal() {
    local id1="$1"
    local id2="$2"

    # Handle null values
    if [[ "$id1" == "null" ]] && [[ "$id2" == "null" ]]; then
        return 0
    fi

    if [[ "$id1" == "null" ]] || [[ "$id2" == "null" ]]; then
        return 1
    fi

    # Simple string comparison (both are JSON-serialized)
    if [[ "$id1" == "$id2" ]]; then
        return 0
    else
        return 1
    fi
}

# collections_in_sync <src_idx> <tgt_idx>
# Compares two collections (by their array indices) for metrics.
# Returns 0 if in sync, 1 if differences found.
collections_in_sync() {
    local src_idx="$1"
    local tgt_idx="$2"

    local src_doc_count="${SOURCE_DOC_COUNTS[$src_idx]}"
    local tgt_doc_count="${TARGET_DOC_COUNTS[$tgt_idx]}"

    local src_index_count="${SOURCE_INDEX_COUNTS[$src_idx]}"
    local tgt_index_count="${TARGET_INDEX_COUNTS[$tgt_idx]}"

    local src_min="${SOURCE_ID_MIN[$src_idx]}"
    local tgt_min="${TARGET_ID_MIN[$tgt_idx]}"

    local src_max="${SOURCE_ID_MAX[$src_idx]}"
    local tgt_max="${TARGET_ID_MAX[$tgt_idx]}"

    # Strict sync check: all metrics must match
    if [[ "$src_doc_count" != "$tgt_doc_count" ]]; then
        return 1
    fi

    if [[ "$src_index_count" != "$tgt_index_count" ]]; then
        return 1
    fi

    if ! ids_equal "$src_min" "$tgt_min"; then
        return 1
    fi

    if ! ids_equal "$src_max" "$tgt_max"; then
        return 1
    fi

    return 0
}

# get_mismatch_reason <src_idx> <tgt_idx>
# Returns a short description of why two collections differ.
get_mismatch_reason() {
    local src_idx="$1"
    local tgt_idx="$2"

    local reasons=""

    local src_doc_count="${SOURCE_DOC_COUNTS[$src_idx]}"
    local tgt_doc_count="${TARGET_DOC_COUNTS[$tgt_idx]}"

    if [[ "$src_doc_count" != "$tgt_doc_count" ]]; then
        reasons+="docs(${src_doc_count}→${tgt_doc_count}) "
    fi

    local src_index_count="${SOURCE_INDEX_COUNTS[$src_idx]}"
    local tgt_index_count="${TARGET_INDEX_COUNTS[$tgt_idx]}"

    if [[ "$src_index_count" != "$tgt_index_count" ]]; then
        reasons+="idx(${src_index_count}→${tgt_index_count}) "
    fi

    local src_min="${SOURCE_ID_MIN[$src_idx]}"
    local tgt_min="${TARGET_ID_MIN[$tgt_idx]}"

    if ! ids_equal "$src_min" "$tgt_min"; then
        reasons+="minId "
    fi

    local src_max="${SOURCE_ID_MAX[$src_idx]}"
    local tgt_max="${TARGET_ID_MAX[$tgt_idx]}"

    if ! ids_equal "$src_max" "$tgt_max"; then
        reasons+="maxId "
    fi

    echo "${reasons% }"  # Remove trailing space
}

# compare_and_report
# Merges source and target data, detects differences, and prints final table.
compare_and_report() {
    log 1 ""
    log 1 "=== Comparison Results ==="
    log 1 ""

    # Merge all collection keys from both servers
    declare -A all_collections
    declare -a all_keys

    local i
    for (( i=0; i<${#SOURCE_DB_NAMES[@]}; i++ )); do
        local key="${SOURCE_DB_NAMES[$i]}.${SOURCE_COLLECTION_NAMES[$i]}"
        if [[ -z "${all_collections[$key]:-}" ]]; then
            all_collections[$key]="src"
            all_keys+=("$key")
        else
            all_collections[$key]="both"
        fi
    done

    for (( i=0; i<${#TARGET_DB_NAMES[@]}; i++ )); do
        local key="${TARGET_DB_NAMES[$i]}.${TARGET_COLLECTION_NAMES[$i]}"
        if [[ -z "${all_collections[$key]:-}" ]]; then
            all_collections[$key]="tgt"
            all_keys+=("$key")
        else
            all_collections[$key]="both"
        fi
    done

    # Sort keys for consistent output
    IFS=$'\n' all_keys=($(sort <<<"${all_keys[*]}"))
    unset IFS

    TOTAL_COLLECTIONS=${#all_keys[@]}

    if (( TOTAL_COLLECTIONS == 0 )); then
        log 1 "  (No collections to compare)"
        return
    fi

    # Print comparison header
    printf "%-30s %-30s %10s %10s %10s\n" "DATABASE" "COLLECTION" "STATUS" "SRC_DOCS" "TGT_DOCS"
    printf "%-30s %-30s %10s %10s %10s\n" "$(printf '=%.0s' {1..30})" "$(printf '=%.0s' {1..30})" "$(printf '=%.0s' {1..10})" "$(printf '=%.0s' {1..10})" "$(printf '=%.0s' {1..10})"

    # Compare each collection
    for key in "${all_keys[@]}"; do
        local mode="${all_collections[$key]}"
        local db
        local collection
        local status="UNKNOWN"
        local src_docs="-"
        local tgt_docs="-"
        local reason=""

        IFS='.' read -r db collection <<<"$key"

        case "$mode" in
            both)
                local src_idx="${SOURCE_INDEX_MAP[$key]}"
                local tgt_idx="${TARGET_INDEX_MAP[$key]}"

                if collections_in_sync "$src_idx" "$tgt_idx"; then
                    status="OK"
                    (( MATCHED_COLLECTIONS++ )) || true
                else
                    status="DIFF"
                    reason="$(get_mismatch_reason "$src_idx" "$tgt_idx")"
                    (( DIFF_COLLECTIONS++ )) || true
                fi

                src_docs="${SOURCE_DOC_COUNTS[$src_idx]}"
                tgt_docs="${TARGET_DOC_COUNTS[$tgt_idx]}"
                ;;
            src)
                status="MISSING_TGT"
                (( MISSING_TARGET++ )) || true
                local src_idx="${SOURCE_INDEX_MAP[$key]}"
                src_docs="${SOURCE_DOC_COUNTS[$src_idx]}"
                ;;
            tgt)
                status="MISSING_SRC"
                (( MISSING_SOURCE++ )) || true
                local tgt_idx="${TARGET_INDEX_MAP[$key]}"
                tgt_docs="${TARGET_DOC_COUNTS[$tgt_idx]}"
                ;;
        esac

        printf "%-30s %-30s %10s %10s %10s" "$db" "$collection" "$status" "$src_docs" "$tgt_docs"
        if [[ -n "$reason" ]]; then
            printf " (%s)" "$reason"
        fi
        echo ""

        log 3 "Comparison result: ${key} = ${status}"
    done

    log 1 "  Total: ${TOTAL_COLLECTIONS} collections"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
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

    # Load and validate configuration
    log 2 "[CFG ] About to load configuration from: ${CONFIG_FILE}"
    log 3 "[CFG ] CLI overrides: source_uri='${SOURCE_URI_OVERRIDE}', target_uri='${TARGET_URI}', exclude_dbs='${EXTRA_EXCLUDE_DBS}', only_dbs='${ONLY_DBS}'"
    load_config_file "$CONFIG_FILE"
    log 2 "[CFG ] Config load completed"

    # Apply CLI overrides
    if [[ -n "$SOURCE_URI_OVERRIDE" ]]; then
        log 2 "[CFG ] Overriding source URI from CLI"
        MONGO_URI="$SOURCE_URI_OVERRIDE"
    fi

    if [[ -n "$EXTRA_EXCLUDE_DBS" ]]; then
        log 2 "[CFG ] Appending CLI exclude list to config exclude list"
        EXCLUDE_DATABASES="${EXCLUDE_DATABASES} ${EXTRA_EXCLUDE_DBS}"
        # Normalize spacing
        EXCLUDE_DATABASES="$(echo "$EXCLUDE_DATABASES" | tr ',' ' ' | xargs)"
    fi

    validate_config

    log 0 "=================================================="
    log 0 " MongoDB Compare — ${SCRIPT_START_TIME}"
    log 0 " Verbosity: ${VERBOSE}"
    log 0 "=================================================="

    check_prerequisites

    # Scan source and target servers
    if ! scan_server "$MONGO_URI" "Source"; then
        if [[ "$ABORT_REQUESTED" == true ]]; then
            exit 130
        fi
        log 0 "[ERROR] Failed to scan source server"
        exit 1
    fi

    if ! scan_server "$TARGET_URI" "Target"; then
        if [[ "$ABORT_REQUESTED" == true ]]; then
            exit 130
        fi
        log 0 "[ERROR] Failed to scan target server"
        exit 1
    fi

    if [[ "$ABORT_REQUESTED" == true ]]; then
        exit 130
    fi

    # Compare and report
    compare_and_report

    # Print final summary
    log 0 ""
    log 0 "=================================================="
    log 0 " SUMMARY"
    log 0 "--------------------------------------------------"
    log 0 " Total collections     : ${TOTAL_COLLECTIONS}"
    log 0 " Matched               : ${MATCHED_COLLECTIONS}"
    log 0 " Differences           : ${DIFF_COLLECTIONS}"
    log 0 " Missing in source     : ${MISSING_SOURCE}"
    log 0 " Missing in target     : ${MISSING_TARGET}"
    if [[ "$ABORT_REQUESTED" == true ]]; then
        log 0 " Aborted               : yes"
    fi
    log 0 "=================================================="
    log 1 "Compare complete."

    if [[ "$ABORT_REQUESTED" == true ]]; then
        exit 130
    fi

    # Exit with appropriate code based on findings
    if (( DIFF_COLLECTIONS > 0 || MISSING_SOURCE > 0 || MISSING_TARGET > 0 )); then
        exit 2
    fi

    exit 0
}

main "$@"
