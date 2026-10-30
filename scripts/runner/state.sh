# shellcheck shell=bash
# Reading and writing the run's state.md frontmatter.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

# Both read state.md written by a model; a missing key must not abort the
# wrapper under set -e (that skipped publishing and reporting silently).
get_current_step() {
    { grep '^current_step:' "${RUN_DIR}/state.md" || true; } | head -1 | awk '{print $2}'
}

get_status() {
    { grep '^status:' "${RUN_DIR}/state.md" || true; } | head -1 | awk '{print $2}'
}

yaml_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

upsert_frontmatter_field() {
    local key="$1"
    local value="$2"
    local state_file="${RUN_DIR}/state.md"
    local temp_file="${state_file}.runtime.tmp"

    if ! awk -v key="$key" -v value="$value" '
        BEGIN {
            delimiter_count = 0
            wrote_field = 0
        }
        /^[[:space:]]*---[[:space:]]*$/ {
            delimiter_count++
            if (delimiter_count == 2 && !wrote_field) {
                print key ": " value
                wrote_field = 1
            }
            print
            next
        }
        delimiter_count == 1 && index($0, key ":") == 1 {
            print key ": " value
            wrote_field = 1
            next
        }
        {
            print
        }
        END {
            if (delimiter_count < 2 || !wrote_field) {
                exit 65
            }
        }
    ' "$state_file" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    mv "$temp_file" "$state_file"
}

ensure_runtime_state() {
    # These fields are owned by the wrapper, not by a model step. Restore them
    # after every provider call so resumability and compute limits do not depend
    # on an LLM preserving YAML keys during an otherwise valid state rewrite.
    upsert_frontmatter_field "agent_backend" "$BACKEND" \
        && upsert_frontmatter_field "run_id" "$(basename "$RUN_DIR")" \
        && upsert_frontmatter_field "mode" "autonomous" \
        && upsert_frontmatter_field "issue_number" "${ISSUE_NUMBER:-none}" \
        && upsert_frontmatter_field "agent_model" "$(yaml_quote "$MODEL")" \
        && upsert_frontmatter_field "compute_profile" "$(yaml_quote "$COMPUTE_PROFILE")" \
        && upsert_frontmatter_field "knowledge_base" "$(yaml_quote "${KB_DIR:-none}")" \
        && { [ -z "${RUN_DIR_OWNER:-}" ] || upsert_frontmatter_field "owner" "$RUN_DIR_OWNER"; }
}

set_status() {
    # Frontmatter only: a bare `sed s/^status:/` also rewrote any body line
    # that happened to start with "status:".
    upsert_frontmatter_field "status" "$1" \
        || sed -i.bak "s/^status:.*/status: $1/" "${RUN_DIR}/state.md"
}
