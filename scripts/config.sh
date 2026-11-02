#!/usr/bin/env bash
# The deployment configuration: config/researcher.env, or the file
# RESEARCHER_CONFIG_FILE names, read as data (its format is in config/CLAUDE.md),
# and the compute-profile presets in config/compute-profiles/. The runner and the
# helper scripts source this file and call load_config, then require_config with
# the keys they use. Run directly, it prints the value of each key it is given,
# one per line, or the compute profile a RESEARCHER_COMPUTE_PROFILE value
# describes, or exits 2 saying what is wrong:
#
#   scripts/config.sh RESEARCHER_TASKS_REPO
#   scripts/config.sh --compute-profile lambda   # with RESEARCHER_COMPUTE_BUDGET_USD set

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config"
RESEARCHER_CONFIG_FILE="${RESEARCHER_CONFIG_FILE:-${CONFIG_DIR}/researcher.env}"

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

# config_from_file KEY: true when load_config set KEY from the file, that is,
# the environment did not set it.
config_from_file() {
    local key
    for key in ${CONFIG_FILE_KEYS[@]+"${CONFIG_FILE_KEYS[@]}"}; do
        if [ "$key" = "$1" ]; then
            return 0
        fi
    done
    return 1
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

# joined_lines FILE: the text of FILE on one line, its lines joined with spaces.
joined_lines() {
    local text
    text=$(tr -s '\n' ' ' < "$1") || return 1
    printf '%s\n' "${text% }"
}

# resolve_compute_profile VALUE: sets COMPUTE_PROFILE to the compute profile
# RESEARCHER_COMPUTE_PROFILE=VALUE describes, and COMPUTE_PROFILE_NAME to its
# preset, or "custom" for profile text. A preset is the name of a file in
# config/compute-profiles/ (any case); its {{paid_compute}} is replaced by
# config/paid-compute.md, the rules every paid preset shares. Any other VALUE
# is the profile text, which has more than one word: a single word that names
# no preset returns 2, listing the presets on stderr; a preset that cannot be
# read returns 1. The runner resolves the `mats` value itself.
resolve_compute_profile() {
    local name="${1,,}" presets paid
    if ! [[ "$name" =~ ^[a-z0-9-]+$ ]]; then
        COMPUTE_PROFILE="$1"
        COMPUTE_PROFILE_NAME=custom
        return 0
    fi
    if [ ! -f "${CONFIG_DIR}/compute-profiles/${name}.md" ]; then
        presets=$(cd "${CONFIG_DIR}/compute-profiles" && ls -- *.md | sed 's/\.md$//' | paste -sd' ')
        echo "ERROR: '$1' is not a compute-profile preset (those in config/compute-profiles/ are: ${presets}); a profile written out as text has more than one word." >&2
        return 2
    fi
    COMPUTE_PROFILE=$(joined_lines "${CONFIG_DIR}/compute-profiles/${name}.md") || return 1
    COMPUTE_PROFILE_NAME="$name"
    if [[ "$COMPUTE_PROFILE" == *"{{paid_compute}}"* ]]; then
        paid=$(joined_lines "${CONFIG_DIR}/paid-compute.md") || return 1
        COMPUTE_PROFILE="${COMPUTE_PROFILE//"{{paid_compute}}"/"$paid"}"
    fi
}

# apply_compute_budget: puts RESEARCHER_COMPUTE_BUDGET_USD in place of
# {{budget_usd}} in COMPUTE_PROFILE. Returns 2, saying why on stderr, when a
# profile with the placeholder (a paid one) has no budget, or one without it has.
apply_compute_budget() {
    if [[ "$COMPUTE_PROFILE" == *"{{budget_usd}}"* ]]; then
        if [ -z "${RESEARCHER_COMPUTE_BUDGET_USD:-}" ]; then
            echo "ERROR: the ${COMPUTE_PROFILE_NAME} compute profile is paid: set RESEARCHER_COMPUTE_BUDGET_USD to the budget for the whole run, in US dollars." >&2
            return 2
        fi
        COMPUTE_PROFILE="${COMPUTE_PROFILE//"{{budget_usd}}"/"$RESEARCHER_COMPUTE_BUDGET_USD"}"
    elif [ -n "${RESEARCHER_COMPUTE_BUDGET_USD:-}" ]; then
        echo "ERROR: RESEARCHER_COMPUTE_BUDGET_USD is set, but the ${COMPUTE_PROFILE_NAME} compute profile takes no budget." >&2
        return 2
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
        echo "usage: config.sh RESEARCHER_KEY... | config.sh --compute-profile VALUE" >&2
        exit 2
    fi
    if [ "$1" = "--compute-profile" ]; then
        if [ "$#" -ne 2 ]; then
            echo "usage: config.sh --compute-profile VALUE" >&2
            exit 2
        fi
        resolve_compute_profile "$2" || exit
        apply_compute_budget || exit 2
        printf '%s\n' "$COMPUTE_PROFILE"
        exit 0
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
