# shellcheck shell=bash
# Publishing the run directory to GitHub.
# Sourced by scripts/researcher-cron.sh; the functions use its globals.

publish_fail() {
    PUBLISH_STATE="failed"
    PUBLISH_ERROR="$1"
    log "ERROR: publishing failed: $1. Results remain local in ${RUN_DIR}; no repo link will be advertised."
}

free_mb() {
    df -Pm "$1" | awk 'NR == 2 {print $4}'
}

check_free_space() {
    # Fails publishing when the run volume has less than MIN_FREE_MB free, or
    # when the free space cannot be measured.
    local free
    if ! free=$(free_mb "$RUN_DIR") || ! [[ "$free" =~ ^[0-9]+$ ]]; then
        publish_fail "could not measure the free space on the run volume (df printed '${free}'; its error is in the log)"
        return 1
    fi
    if [ "$free" -lt "$MIN_FREE_MB" ]; then
        publish_fail "disk nearly full: ${free} MB free on the run volume, publishing needs ${MIN_FREE_MB} MB"
        return 1
    fi
}

prepare_local_repo() {
    # Run inside RUN_DIR. Sets up the repo, the branch and the remote, and keeps
    # wrapper bookkeeping and oversized files out of the commit.
    local branch="$1" remote="$2"
    [ -d .git ] || git init -q
    if git rev-parse -q --verify HEAD >/dev/null; then
        git branch -M "$branch"
    else
        # Name the unborn branch explicitly. Relying on git's default branch
        # name is what left 14 repos empty: runs committed on 'master' and
        # pushed 'main' ("src refspec main does not match any").
        git symbolic-ref HEAD "refs/heads/${branch}"
    fi
    git remote remove origin 2>/dev/null || true
    git remote add origin "$remote"
    load_exclude_notes
    [ -f .gitignore ] || write_gitignore "$RUN_DIR"
    local exclude=".git/info/exclude"
    mkdir -p .git/info
    grep -qxF '/.repo_url' "$exclude" 2>/dev/null \
        || printf '%s\n' '/.repo_url' '/.publish_repo' '/.publish_branch' '/run-outcome.json' '*.runtime.tmp' >> "$exclude"
    grep -qxF '/.email-sent' "$exclude" 2>/dev/null || printf '%s\n' '/.email-sent' >> "$exclude"
}

exclude_with_note() {
    # Keep a path out of the commit, and remember why next to the pattern so a
    # later re-publish (when the path is already ignored) still reports it.
    # One line each: a newline in a file name must not leak into a pattern.
    local note pattern
    note=$(printf '%s' "$2" | tr '\n\r' '  ')
    # Escape glob characters first; only then turn newlines into `?` wildcards.
    pattern=$(printf '%s' "$1" | sed 's/[][*?\\!#]/\\&/g' | tr '\n\r' '??')
    printf '# researcher-note: %s\n' "$note" >> .git/info/exclude
    printf '%s\n' "$pattern" >> .git/info/exclude
    PUBLISH_NOTES+=("$note")
}

load_exclude_notes() {
    local line
    [ -f .git/info/exclude ] || return 0
    while IFS= read -r line; do
        case "$line" in
            "# researcher-note: "*) PUBLISH_NOTES+=("${line#\# researcher-note: }") ;;
        esac
    done < .git/info/exclude
}

exclude_large_files() {
    # GitHub rejects any file over 100 MB, and one such file fails the whole
    # push. Leave oversized files out of the commit (they stay on disk) rather
    # than lose the publication.
    local file bytes limit=$(( MAX_FILE_MB * 1024 * 1024 ))
    while IFS= read -r -d '' file; do
        [ -f "$file" ] || continue
        bytes=$(wc -c < "$file" | tr -d ' ')
        if [ "$bytes" -ge "$limit" ]; then
            exclude_with_note "/${file}" "${file} not published: $(( bytes / 1048576 )) MB is over the ${MAX_FILE_MB} MB limit; it is only in the run directory"
            log "WARN: not publishing ${file} ($(( bytes / 1048576 )) MB, limit ${MAX_FILE_MB} MB); it stays in the run directory."
        fi
    done < <(git ls-files --others --modified --exclude-standard -z)
}

git_reason() {
    # The line of git's (or a hook's) output that says why it stopped, on one
    # line and without colour codes, for the publish reason.
    local text
    text=$(printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
    printf '%s\n' "$text" | grep -m1 -E 'COMMIT BLOCKED|^(fatal|error):' \
        || printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -1
}

exclude_secret_findings() {
    # The global pre-commit hook (~/.git-hooks/pre-commit) runs gitleaks and
    # refuses a commit with anything that looks like a secret. Research output
    # trips it on false positives: on 2026-10-28 a BibTeX cite key in
    # literature/search-001-academic.md read as a generic API key, and the
    # commit failed. Scan the staged changes the way the hook does, and leave
    # each flagged file out of the commit (it stays in the run directory), with
    # the reason. Never bypass or weaken the scan from here: if it was a real
    # secret it must not be published, and if not, Titus decides on an allowlist.
    command -v gitleaks >/dev/null 2>&1 || return 0
    local report args=() rc findings file line rule
    [ -f .gitleaks.toml ] || { [ -f "$HOME/.gitleaks.toml" ] && args+=(--config "$HOME/.gitleaks.toml"); }
    [ -f .gitleaksignore ] || { [ -f "$HOME/.gitleaksignore" ] && args+=(--gitleaks-ignore-path "$HOME/.gitleaksignore"); }
    report=$(mktemp "${TMPDIR:-/tmp}/researcher-gitleaks.XXXXXX") || return 0
    rc=0
    gitleaks git --pre-commit --staged --redact --no-banner --report-format json --report-path "$report" \
        ${args[@]+"${args[@]}"} >/dev/null 2>&1 || rc=$?
    findings=$(jq -r 'group_by(.File)[] | [.[0].File, (map(.StartLine | tostring) | join(", ")), .[0].RuleID] | @tsv' \
        "$report" 2>/dev/null || true)
    rm -f "$report"
    if [ "$rc" -ne 0 ] && [ -z "$findings" ]; then
        log "WARN: the secret scan exited ${rc} without findings; the commit will show why."
        return 0
    fi
    while IFS=$'\t' read -r file line rule; do
        [ -n "$file" ] || continue
        git rm -q --cached --ignore-unmatch -- "$file" >/dev/null 2>&1 || true
        exclude_with_note "/${file}" "${file} not published: the secret scan flagged line ${line} (${rule}); it is only in the run directory"
        log "WARN: not publishing ${file}: the secret scan flagged line ${line} (${rule}). It stays in the run directory."
    done <<< "$findings"
}

commit_all() {
    # $1: add mode ("all" stages deletions; "overlay" keeps files only the
    # remote base has). Returns non-zero unless every change is committed.
    local add_args=(-A) out
    [ "$1" = "overlay" ] && add_args=(--ignore-removal .)
    if ! out=$(git add "${add_args[@]}" 2>&1); then
        publish_fail "git add failed: $(git_reason "$out")"
        return 1
    fi
    exclude_secret_findings
    # Nothing left to commit exits 1 too: the checks below decide, and git's
    # own words become the reason (a hook's refusal was lost here before).
    out=$(git commit -q -m "$2" 2>&1) || true
    [ -z "$out" ] || printf '%s\n' "$out" | tee -a "${LOG_DIR}/gh-commit.log" >&2
    local leftover
    leftover=$(git status --porcelain)
    if [ "$1" = "overlay" ]; then
        # Files only the base branch has show as deleted here, by design.
        leftover=$(printf '%s\n' "$leftover" | grep -v '^ D ' || true)
    fi
    if ! git rev-parse -q --verify HEAD >/dev/null || [ -n "$leftover" ]; then
        publish_fail "git commit failed: $(git_reason "${out:-no output from git}") (see ${LOG_DIR}/gh-commit.log)"
        return 1
    fi
}

push_and_verify() {
    # Success means the remote branch now points at exactly our HEAD — not
    # just that git push exited 0, and not that the repo is non-empty.
    local branch="$1" head remote_head
    head=$(git rev-parse HEAD)
    if ! git push origin "HEAD:refs/heads/${branch}" 2>&1 | tee -a "${LOG_DIR}/gh-push.log"; then
        publish_fail "git push of ${branch} failed (see ${LOG_DIR}/gh-push.log)"
        return 1
    fi
    remote_head=$(git ls-remote origin "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')
    if [ "$remote_head" != "$head" ]; then
        publish_fail "push reported success but remote ${branch} is '${remote_head:-missing}', expected ${head}"
        return 1
    fi
}

commit_and_push() {
    # commit_and_push MODE BRANCH REPO LINK_PATH MESSAGE, inside RUN_DIR after
    # prepare_local_repo: leaves nested repositories and oversized files out,
    # commits the rest with MESSAGE (MODE is commit_all's add mode) and pushes
    # BRANCH. Once the push is verified the run is published: PUBLISH_STATE is
    # pushed, REPO_WEB is the web page of REPO (owner/name), and .repo_url holds
    # that page followed by LINK_PATH (empty, or /tree/<branch> for a branch).
    local mode="$1" branch="$2" repo="$3" link_path="$4" message="$5"
    exclude_nested_repos
    exclude_large_files
    if commit_all "$mode" "$message" && push_and_verify "$branch"; then
        PUBLISH_STATE="pushed"
        REPO_WEB="https://github.com/${repo}"
        printf '%s\n' "${REPO_WEB}${link_path}" > "${RUN_DIR}/.repo_url"
        log "Pushed and verified: ${REPO_WEB}${link_path}"
    fi
}

repo_visibility() {
    # private / public / internal, or nothing when the repo cannot be read.
    gh repo view "$1" --json visibility --jq '.visibility' 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

require_visibility() {
    # require_visibility REPO HINT: sets PUBLISHED_VISIBILITY when GitHub reports
    # REPO (owner/name) with the requested visibility, REPO_VISIBILITY. Otherwise
    # nothing may be pushed there (private results would go public): it fails
    # publishing with the reason and HINT, another way to publish.
    local vis
    vis=$(repo_visibility "$1")
    if [ "$vis" != "$REPO_VISIBILITY" ]; then
        publish_fail "$1 is ${vis:-unreadable}, not ${REPO_VISIBILITY}, so nothing was pushed there; re-run with RESEARCHER_REPO_VISIBILITY=${vis:-<visibility>} if that is intended, or $2"
        return 1
    fi
    PUBLISHED_VISIBILITY="$vis"
}

repo_state() {
    # Prints absent | empty | content for REPO ($1, owner/name). When gh fails
    # for any reason other than the repository not existing, prints gh's
    # message instead and returns 1.
    local out
    if out=$(gh repo view "$1" --json isEmpty --jq '.isEmpty' 2>&1); then
        if [ "$out" = "true" ]; then echo empty; else echo content; fi
        return 0
    fi
    case "$out" in
        *"Could not resolve to a Repository"*) echo absent ;;
        *) printf '%s\n' "$out" | tr '\n' ' '; return 1 ;;
    esac
}

choose_repo_slug() {
    # Prints the first usable name: one that does not exist yet, or an empty
    # repo that already has the requested visibility. Never another run's
    # repo (the push would be rejected), and never an empty repo left public
    # by the old master/main bug (results would go public while every report
    # said private). Returns 1 when every candidate is taken, and 2, printing
    # why, when GitHub could not be asked about one. Diagnostics go to stderr.
    local slug="$1" candidate state vis
    for candidate in "$slug" "${slug}-$(echo "$RUN_ID" | cut -c1-10 | tr -d '-')" "${slug}-$(date +%H%M%S)"; do
        if ! state=$(repo_state "${REPO_OWNER}/${candidate}"); then
            printf 'could not check whether %s exists on GitHub: %s\n' "${REPO_OWNER}/${candidate}" "$state"
            return 2
        fi
        case "$state" in
            absent) printf '%s\n' "$candidate"; return 0 ;;
            empty)
                vis=$(repo_visibility "${REPO_OWNER}/${candidate}")
                if [ "$vis" = "$REPO_VISIBILITY" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
                log "WARN: ${REPO_OWNER}/${candidate} exists (empty, ${vis:-unknown visibility}, not ${REPO_VISIBILITY}); not reusing it." >&2
                ;;
            *) log "WARN: ${REPO_OWNER}/${candidate} already holds another run; trying a new name." >&2 ;;
        esac
    done
    return 1
}

exclude_nested_repos() {
    # A git repository inside the run (a cloned library, an agent's own
    # `git init`) cannot be committed as files: git records it as a bare
    # pointer, or fails outright. Leave it out and say so.
    local nested dir
    while IFS= read -r -d '' nested; do
        dir=$(dirname "${nested#./}")
        git check-ignore -q "$dir" 2>/dev/null && continue
        exclude_with_note "/${dir}/" "${dir}/ not published: it is a separate git repository inside the run directory"
        log "WARN: not publishing ${dir}/: it is a separate git repository inside the run."
    done < <(find . -path ./.git -prune -o -name .git -prune -print0 2>/dev/null)
}

write_run_readme() {
    # Writes RUN_DIR/README.md for a new run repo: the topic, status, run id and
    # agent, the paper's abstract (or a pointer to paper/), and the layout.
    local abstract=""
    if [ -f "${RUN_DIR}/paper/sections/abstract.tex" ]; then
        abstract=$(sed 's/\\[a-zA-Z]*{[^}]*}//g; s/\\[a-zA-Z]*//g; s/[{}]//g' "${RUN_DIR}/paper/sections/abstract.tex" | head -20)
    fi

    cat > "${RUN_DIR}/README.md" << READMEEOF
# ${TOPIC_LINE}

**Status**: ${STATUS}
**Run ID**: ${RUN_ID}
**Mode**: Autonomous research
**Agent**: ${AGENT_LABEL}

## Summary

${abstract:-See paper/ directory for full results.}

## Structure

- \`paper/\` — LaTeX paper and compiled PDF
- \`literature/\` — Literature review artifacts
- \`experiments/\` — Experiment code, results and pre-flight checks
- \`challenge/\` — Adversarial review (assumptions, mentor-review, pre-mortem)
- \`decomposition.md\` — Steinhardt fail-fast decomposition
- \`next-steps.md\` — Ranked next round
- \`state.md\` — Workflow state log

---

*Generated by the autonomous AI safety researcher agent.*
READMEEOF
}

publish_new_repo() {
    local slug topic_slug repo_desc message chosen=0
    if [ -s "${RUN_DIR}/.publish_repo" ]; then
        # Re-publishing this run: reuse the repo it already created.
        slug=$(cat "${RUN_DIR}/.publish_repo")
    else
        topic_slug=$(python3 "$LIB" slug --max-length 40 --word-boundary -- "$TOPIC_LINE")
        slug=$(choose_repo_slug "research-${topic_slug}") || chosen=$?
        case "$chosen" in
            0) ;;
            2) publish_fail "$slug"; return 1 ;;
            *)
                publish_fail "no free repo name for research-${topic_slug} (all candidates hold other runs or have the wrong visibility)"
                return 1
                ;;
        esac
    fi

    log "Publishing to GitHub repo ${REPO_OWNER}/${slug} (${REPO_VISIBILITY})"

    # GitHub caps repo descriptions at 350 chars; the topic can be far longer (a whole
    # paragraph), which makes `gh repo create` fail with a 422. Truncate to stay under.
    repo_desc="AI safety research (autonomous): ${TOPIC_LINE}"
    repo_desc="$(printf '%s' "$repo_desc" | tr '\n' ' ' | head -c 300)"

    # Non-zero when the repo already exists (a re-publish), which is fine:
    # the visibility check and push-and-verify below decide.
    gh repo create "${REPO_OWNER}/${slug}" "--${REPO_VISIBILITY}" --description "$repo_desc" 2>&1 \
        | tee -a "${LOG_DIR}/gh-repo-create.log" \
        || log "WARN: gh repo create returned non-zero for ${REPO_OWNER}/${slug} (may already exist)."
    printf '%s\n' "$slug" > "${RUN_DIR}/.publish_repo"

    require_visibility "${REPO_OWNER}/${slug}" "delete ${RUN_DIR}/.publish_repo to publish under a new name" || return 1
    write_run_readme
    message=$(cat <<COMMITEOF
Research artifacts: ${TOPIC_LINE}

Autonomous research run (${STATUS}).
Run ID: ${RUN_ID}

${COMMIT_ATTRIBUTION}
COMMITEOF
)

    REPO_BRANCH="main"
    cd "$RUN_DIR"
    prepare_local_repo "$REPO_BRANCH" "$(git_remote_for "${REPO_OWNER}/${slug}")"
    commit_and_push all "$REPO_BRANCH" "${REPO_OWNER}/${slug}" "" "$message"
    cd "$REPO_DIR"
}

publish_followup() {
    # Follow-ups push a new branch to the existing repo, in place: the branch
    # starts from the branch the follow-up continues (the prior repo's default
    # branch, or the /tree/<branch> a follow-up of a follow-up names) and this
    # run's files are laid over it. Nothing is copied — the old version cloned
    # the prior repo into /tmp and copied the whole run into it, which filled
    # the root disk and lost both 2026-04 follow-ups (tasks#1919/#1920).
    local branch prior_path base_branch message
    prior_path=$(repo_path_of "$PRIOR_REPO_URL")
    base_branch=$(repo_url_branch "$PRIOR_REPO_URL")
    if [ -s "${RUN_DIR}/.publish_branch" ]; then
        branch=$(cat "${RUN_DIR}/.publish_branch")
    else
        branch="followup-$(date +%Y-%m-%d)-$(echo "$RUN_ID" | tail -c 20 | sed 's/^-//')"
    fi
    REPO_BRANCH="$branch"

    # The prior repo's visibility is not ours to choose.
    require_visibility "$prior_path" "push the follow-up by hand" || return 1

    log "Publishing follow-up results to https://github.com/${prior_path} on branch ${branch} (based on ${base_branch:-its default branch})"
    cd "$RUN_DIR"
    printf '%s\n' "$branch" > .publish_branch
    prepare_local_repo "$branch" "$(git_remote_for "$prior_path")"
    if ! git rev-parse -q --verify HEAD >/dev/null; then
        if git fetch -q --depth 1 origin "${base_branch:-HEAD}" 2>>"${LOG_DIR}/gh-push.log"; then
            # Index = the prior tree; the working tree (this run) is untouched.
            git reset -q --mixed FETCH_HEAD
        else
            local refs
            if ! refs=$(git ls-remote origin 2>/dev/null); then
                publish_fail "could not reach ${prior_path}"
                cd "$REPO_DIR"
                return 1
            elif [ -n "$refs" ]; then
                # Reachable with history, yet the base would not fetch: an
                # orphan branch would cut the line's history, so stop here.
                publish_fail "could not fetch ${base_branch:-the default branch} of ${prior_path}"
                cd "$REPO_DIR"
                return 1
            fi
            log "WARN: ${prior_path} is empty; the branch will hold only this run's files."
        fi
    fi
    message=$(cat <<COMMITEOF
Follow-up research: ${TOPIC_LINE}

Follow-up run (${STATUS}).
Run ID: ${RUN_ID}
Parent issue: #${PARENT_ISSUE}

${COMMIT_ATTRIBUTION}
COMMITEOF
)
    commit_and_push overlay "$branch" "$prior_path" "/tree/${branch}" "$message"
    cd "$REPO_DIR"
}

publish_run() {
    # A stale link from an earlier attempt must never outlive a failed one.
    rm -f "${RUN_DIR}/.repo_url"
    check_free_space || return 0
    if is_followup_run; then
        publish_followup
    else
        publish_new_repo
    fi
}
