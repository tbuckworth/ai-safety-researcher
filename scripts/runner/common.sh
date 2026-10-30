# shellcheck shell=bash
# Small helpers shared by the runner: truthy values, GitHub repo URLs, logging.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# Repo URLs come as owner/name, https://github.com/owner/name[.git], or a
# follow-up's https://github.com/owner/name/tree/<branch>.
repo_path_of() {
    local path="${1%/}"
    path="${path#https://github.com/}"
    path=$(printf '%s' "$path" | cut -d/ -f1-2)
    printf '%s\n' "${path%.git}"
}

repo_url_branch() {
    local url="${1%/}"
    case "$url" in
        */tree/*) url="${url#*/tree/}"; printf '%s\n' "${url%%/*}" ;;
    esac
}

# The git remote to fetch from / push to for a repo URL.
git_remote_for() {
    printf '%s/%s.git\n' "$GIT_REMOTE_BASE" "$(repo_path_of "$1")"
}

log() { echo "$(date -Iseconds) $*"; }
