#!/usr/bin/env bash
# The deployment configuration: config/researcher.env, or the file
# RESEARCHER_CONFIG_FILE names, read as data (its format is in config/CLAUDE.md).
# The runner and the helper scripts source this file and call load_config, then
# require_config with the keys they use. Run directly, it prints the value of
# each key it is given, one per line, or exits 2 saying what is wrong:
#
#   scripts/config.sh RESEARCHER_TASKS_REPO

RESEARCHER_CONFIG_FILE="${RESEARCHER_CONFIG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/researcher.env}"

# load_config: sets each key of RESEARCHER_CONFIG_FILE that the environment
# leaves unset or empty to the file's value, and lists those keys in
# CONFIG_FILE_KEYS. The file is never sourced or evaluated: a value is the text
# after the first "=", taken literally except that a leading "~/" is the home
# directory. Returns 2, saying why on stderr, when the file cannot be read or a
# line is not blank, a "#" comment or RESEARCHER_KEY=value.
load_config() {
    local line key value number=0
    CONFIG_FILE_KEYS=()
    if [ ! -r "$RESEARCHER_CONFIG_FILE" ]; then
        echo "ERROR: cannot read the configuration file ${RESEARCHER_CONFIG_FILE}." >&2
        return 2
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        case "$line" in ''|'#'*) continue ;; esac
        if ! [[ "$line" =~ ^(RESEARCHER_[A-Z0-9_]+)=(.*)$ ]]; then
            echo "ERROR: line ${number} of ${RESEARCHER_CONFIG_FILE} is not RESEARCHER_KEY=value: ${line}" >&2
            return 2
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$value" in "~/"*) value="${HOME}/${value#"~/"}" ;; esac
        if [ -z "${!key:-}" ]; then
            printf -v "$key" '%s' "$value"
            CONFIG_FILE_KEYS+=("$key")
        fi
    done < "$RESEARCHER_CONFIG_FILE"
}

# require_config KEY...: returns 2, naming the first KEY that is unset or
# empty on stderr, unless the environment or the configuration file set them all.
require_config() {
    local key
    for key in "$@"; do
        if [ -z "${!key:-}" ]; then
            echo "ERROR: ${key} is not set: define it in ${RESEARCHER_CONFIG_FILE} or the environment." >&2
            return 2
        fi
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
        echo "usage: config.sh RESEARCHER_KEY..." >&2
        exit 2
    fi
    for key in "$@"; do
        if ! [[ "$key" =~ ^RESEARCHER_[A-Z0-9_]+$ ]]; then
            echo "ERROR: '${key}' is not a RESEARCHER_ key." >&2
            exit 2
        fi
    done
    load_config || exit 2
    require_config "$@" || exit 2
    for key in "$@"; do
        printf '%s\n' "${!key}"
    done
fi
