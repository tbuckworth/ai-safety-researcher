# shellcheck shell=bash
# Small helpers shared by the runner: truthy values, GitHub repo URLs, the run
# host's SSH alias, time limits, logging. Sourced by scripts/researcher-cron.sh
# and scripts/send-run-report.sh; the functions use their globals.

is_true() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# Repo URLs come as owner/name, https://github.com/owner/name[.git], or a
# follow-up's https://github.com/owner/name/tree/<branch>. results_report.py
# split_repo_url reads them the same way in Python; a change of form goes in both.
repo_path_of() {
    local path="${1%/}"
    path="${path#"${GITHUB_WEB}/"}"
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

issue_url() {
    # The address of the run's original issue (ISSUE_NUMBER), or nothing for a
    # run without one.
    if [ -n "${ISSUE_NUMBER:-}" ] && [ "$ISSUE_NUMBER" != "none" ]; then
        printf '%s/%s/issues/%s\n' "$GITHUB_WEB" "$TASKS_REPO" "$ISSUE_NUMBER"
    fi
}

# resolve_host_alias: prints how the reader of the results email reaches this
# machine, so the email's "How to Continue This Research" steps are literally
# runnable. This is an SSH *alias* as configured in the reader's ~/.ssh/config,
# not a hostname: RESEARCHER_HOST_ALIAS, else this machine's entry in
# RESEARCHER_HOST_ALIASES (space-separated hostname=alias pairs, by short
# hostname). The value "local" suppresses the ssh step entirely (run and reader
# on the same machine). Returns 2, saying why on stderr, when neither names one.
resolve_host_alias() {
    local run_hostname pair alias="" pairs=()
    if [ -n "${RESEARCHER_HOST_ALIAS:-}" ]; then
        printf '%s\n' "$RESEARCHER_HOST_ALIAS"
        return 0
    fi
    if ! run_hostname=$(hostname -s); then
        echo "ERROR: could not read this machine's hostname (hostname -s failed); set RESEARCHER_HOST_ALIAS to the SSH alias the email's reader uses for it, or to 'local'." >&2
        return 2
    fi
    read -ra pairs <<< "${RESEARCHER_HOST_ALIASES:-}"
    for pair in ${pairs[@]+"${pairs[@]}"}; do
        if [ "${pair%%=*}" = "$run_hostname" ]; then
            alias="${pair#*=}"
        fi
    done
    if [ -z "$alias" ]; then
        echo "ERROR: host '${run_hostname}' is not in RESEARCHER_HOST_ALIASES; set RESEARCHER_HOST_ALIAS to the SSH alias the email's reader uses for this machine, or to 'local'." >&2
        return 2
    fi
    printf '%s\n' "$alias"
}

# run_limited LIMIT CMD...: runs CMD and returns its status. Unless LIMIT is
# "none", CMD is stopped after LIMIT seconds (TERM, then KILL 30 s later), and
# the status is then 124 (137 if it had to be killed), as timeout(1) gives it.
run_limited() {
    local limit="$1"
    shift
    if [ "$limit" = none ]; then
        "$@"
    else
        timeout --kill-after=30 "$limit" "$@"
    fi
}
