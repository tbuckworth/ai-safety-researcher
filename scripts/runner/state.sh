# shellcheck shell=bash
# Reading and writing the run's state.md frontmatter.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

# state_field FILE KEY: the value of a frontmatter field of a state.md, or nothing
# when the field is absent. researcher_lib.py's read_frontmatter is the one
# parser, so a value a model quoted or commented reads the same everywhere.
# A missing FILE is an error.
state_field() {
    python3 "$LIB" state-field "$1" "$2"
}

get_current_step() {
    state_field "${RUN_DIR}/state.md" current_step
}

get_status() {
    state_field "${RUN_DIR}/state.md" status
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

    # Key and value go in through the environment: `awk -v` would turn the
    # backslash escapes yaml_quote writes back into raw quotes and backslashes.
    if ! FIELD_KEY="$key" FIELD_VALUE="$value" awk '
        BEGIN {
            key = ENVIRON["FIELD_KEY"]
            value = ENVIRON["FIELD_VALUE"]
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

# The frontmatter fields the wrapper owns, one "key<TAB>value" line each, the
# value as it is written to YAML. A run is created with them and they are
# restored after every step, so resuming, publishing and the compute limits never
# depend on a model keeping them. Free text goes through yaml_quote; ids, numbers,
# booleans and the owner (RESEARCHER_OWNER is checked to be one plain word) are
# written bare. On a resume, researcher-cron.sh reads the run's own values (issue,
# follow-up fields, owner) back into the globals used here; change the two
# together.
runtime_fields() {
    printf '%s\t%s\n' \
        run_id "$(basename "$RUN_DIR")" \
        mode autonomous \
        agent_backend "$BACKEND" \
        agent_model "$(yaml_quote "$MODEL")" \
        issue_number "${ISSUE_NUMBER:-none}" \
        compute_profile "$(yaml_quote "$COMPUTE_PROFILE")" \
        knowledge_base "$(yaml_quote "${KB_DIR:-none}")"
    if [ -n "${RUN_DIR_OWNER:-}" ]; then
        printf 'owner\t%s\n' "$RUN_DIR_OWNER"
    fi
    if is_followup_run; then
        followup_fields
    fi
}

# A follow-up run's own fields, in the same form; followup-context.md has them too.
followup_fields() {
    printf '%s\t%s\n' \
        is_followup true \
        parent_issue "${PARENT_ISSUE:-none}" \
        prior_repo "$(yaml_quote "$PRIOR_REPO_URL")" \
        prior_run_id "$(yaml_quote "$PRIOR_RUN_ID")" \
        followup_key "${FOLLOWUP_KEY:-none}"
}

ensure_runtime_state() {
    local key value fields
    fields=$(runtime_fields)
    while IFS=$'\t' read -r key value; do
        upsert_frontmatter_field "$key" "$value" || return 1
    done <<< "$fields"
}

write_new_state() {
    # A fresh state.md for a new run: the topic title ($1), the starting step and
    # status, the wrapper-owned fields, and $2 as its body.
    printf -- '---\n---\n\n%s\n' "$2" > "${RUN_DIR}/state.md"
    upsert_frontmatter_field topic "$(yaml_quote "$1")" \
        && upsert_frontmatter_field current_step 0 \
        && upsert_frontmatter_field status initialized \
        && ensure_runtime_state \
        && upsert_frontmatter_field clarifications '[]' \
        && upsert_frontmatter_field decisions '[]'
}

set_status() {
    # Frontmatter only: a bare `sed s/^status:/` also rewrote any body line
    # that happened to start with "status:".
    upsert_frontmatter_field "status" "$1" \
        || sed -i.bak "s/^status:.*/status: $1/" "${RUN_DIR}/state.md"
}
