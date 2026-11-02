# shellcheck shell=bash
# A run's settings: restoring them from its run-config.json on a resume, and
# writing run-config.json at each launch. researcher_lib.py decides what a
# resume may change and owns the file's format.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

json_object() {
    # json_object KEY VALUE [KEY VALUE ...]: a JSON object of the string VALUEs,
    # with null for an empty one (the runner treats an empty setting as unset).
    local args=()
    while [ "$#" -gt 0 ]; do
        args+=(--arg "$1" "$2")
        shift 2
    done
    jq -n '$ARGS.named | map_values(if . == "" then null else . end)' ${args[@]+"${args[@]}"}
}

settings_json() {
    # settings_json NAME...: a JSON object of each variable NAME's value (json_object).
    local name pairs=()
    for name in "$@"; do
        pairs+=("$name" "${!name:-}")
    done
    json_object ${pairs[@]+"${pairs[@]}"}
}

restore_run_settings() {
    # restore_run_settings DIR: for a resume of the run in DIR, sets each run
    # setting (RUN_SETTINGS) this launch's environment does not set to the value
    # the run saved, and lists in RUN_CONFIG_CHANGES the settings it sets to
    # another value. Only the run's owner (RESEARCHER_OWNER equal to its owner),
    # RESEARCHER_ALLOW_CONFIG_CHANGE=true or, for the backend alone,
    # RESEARCHER_ALLOW_BACKEND_SWITCH=true may change one; any other change
    # exits 2, naming the setting. Exits 1 when the saved settings cannot be
    # read. Logs each accepted change, and a run that predates run-config.json.
    local dir="$1" name value line owner out rc=0 given=() leave=()
    for name in "${RUN_SETTINGS[@]}"; do
        if [ -n "${!name:-}" ] && ! config_from_file "$name"; then
            given+=("$name")
        fi
    done
    owner=$(state_field "${dir}/state.md" owner)
    if [ -n "$RUN_OWNER" ] && [ "$owner" = "$RUN_OWNER" ]; then
        leave+=(--change-allowed-by "the run's owner, ${RUN_OWNER}")
    elif is_true "$ALLOW_CONFIG_CHANGE"; then
        leave+=(--change-allowed-by RESEARCHER_ALLOW_CONFIG_CHANGE)
    fi
    if is_true "$ALLOW_BACKEND_SWITCH"; then
        leave+=(--allow-backend-switch)
    fi
    out=$(settings_json ${given[@]+"${given[@]}"} \
        | python3 "$LIB" resume-settings --run-dir "$dir" ${leave[@]+"${leave[@]}"}) || rc=$?
    case "$rc" in
        0) ;;
        2) exit 2 ;;
        *)
            log "ERROR: could not read the saved settings of ${dir} (the error is above)."
            exit 1
            ;;
    esac
    while IFS= read -r -d '' name && IFS= read -r -d '' value; do
        printf -v "$name" '%s' "$value"
    done < <(jq -j '.restore | to_entries[] | .key, "\u0000", (.value // ""), "\u0000"' <<< "$out")
    RUN_CONFIG_CHANGES=$(jq -c '.changes' <<< "$out")
    if [ "$(jq -r '.older_run' <<< "$out")" = true ]; then
        log "WARN: ${dir} predates run-config.json: it keeps its backend, and its other settings come from this launch; run-config.json records them from now on."
    fi
    while IFS= read -r line; do
        log "$line"
    done < <(jq -r '.changes[] | "Resuming with a changed \(.setting) (accepted: \(.accepted_by)); run-config.json records the saved and the new value."' <<< "$out")
}

resolved_settings_json() {
    # What the run's settings resolved to at this launch, as a JSON object (json_object).
    json_object model "$MODEL" codex_deep_model "${CODEX_DEEP_MODEL:-}" \
        codex_deep_reasoning "${CODEX_DEEP_REASONING:-}" email_claude_model "$EMAIL_CLAUDE_MODEL" \
        compute_profile_preset "$COMPUTE_PROFILE_NAME" compute_profile "$COMPUTE_PROFILE" \
        job_wait_cmd "$JOB_WAIT_CMD" knowledge_base "${KB_DIR:-none}"
}

write_run_config() {
    # Writes RUN_DIR/run-config.json: the run's settings and what they resolved
    # to, with this launch (its start, timeout, launcher's owner and the
    # plugin's commit) and RUN_CONFIG_CHANGES added to the earlier ones. A run
    # whose settings cannot be saved could not be resumed with them, so a
    # failure stops the run (exit 1).
    local input launch temp="${RUN_DIR}/run-config.runtime.tmp"
    launch=$(json_object started "$(date -Iseconds)" plugin_commit "$PLUGIN_COMMIT" owner "$RUN_OWNER" \
        | jq --argjson timeout "$TIMEOUT_SECONDS" '. + {timeout_seconds: $timeout}')
    input=$(jq -n --argjson settings "$(settings_json "${RUN_SETTINGS[@]}")" \
        --argjson resolved "$(resolved_settings_json)" --argjson changes "$RUN_CONFIG_CHANGES" \
        --argjson launch "$launch" \
        '{settings: $settings, resolved: $resolved, changes: $changes, launch: $launch}')
    if ! python3 "$LIB" run-config --run-dir "$RUN_DIR" <<< "$input" > "$temp" \
        || ! mv "$temp" "${RUN_DIR}/run-config.json"; then
        rm -f "$temp"
        log "ERROR: could not write ${RUN_DIR}/run-config.json (the error is above). Stopping."
        exit 1
    fi
}
