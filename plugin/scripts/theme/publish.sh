#!/usr/bin/env bash
# publish.sh prepare|commit|abort|run|resolve --project <dir> [--config <ssh.json>]
#            [--confirm-deletions] [--take-over-stale] [--accept-live-failure]
# publish.sh resolve --project <dir> <path> local|server
#
# The versioned theme publish — references/publish.md. It comes in two halves
# because a script can't wait for a person while holding the server's lock:
#
#   prepare  Finishes any interrupted publish first (recover.sh — the only
#            step that may lock and write on the server). Then, with no lock
#            and no writes there: reads the server, decides, merges what
#            changed there into the local theme (backing the local copy up
#            first) — UP_TO_DATE when nothing is left to publish — checks the
#            site isn't failing already (else LIVE_ALREADY_FAILING, with what
#            the merge took in: the failure isn't this publish's;
#            --accept-live-failure, after asking, lets those same failures
#            only warn later), checks locally, writes .deploy/publish/plan.json.
#   commit   Takes the lock; re-checks the server is still exactly what the
#            plan saw (else STALE_PLAN — prepare again); stages, checks the
#            staging copy, swaps it in, validates it live — swapping back on
#            any failure — records the new version, cleans up.
#   abort    Puts the theme files and their starting point back as they were
#            before the first prepare touched them.
#   run      prepare, then commit when nothing needs a person. Prints
#            commit's outcome, plus prepare's GONE_FROM_SERVER, WARN and
#            RECOVERED lines.
#   resolve  Settles a conflict by keeping one side whole: "local" keeps this
#            copy's, "server" the live one — either may be a deletion. A
#            conflict written with markers also settles once its markers are
#            gone; one that leaves none (a binary, a file changed on one side
#            and deleted on the other) only by resolve, and an invalid
#            site.json once it decodes. Until every conflict is settled,
#            prepare and commit refuse to go on.
#
# stdout: STATUS=… first, then DECISION, SERVER_VERSION, NEXT_VERSION/VERSION,
#         TOOK_THEIRS=…, GONE_FROM_SERVER=…, MERGED=…, CONFLICT=<kind> <path>,
#         CONFLICT_FILE=…, DELETE=…, WARN=…, PHP_LINT=…, DETAIL=…, FAILURE=…,
#         RECOVERED=… lines.
# Exit:   0 done or ready · 2 bad arguments, or no plan · 3 conflicts ·
#         4 deletions to confirm · 5 someone else's lock · 6 local starting
#         point ahead of the server · 7 local checks failed, or source leftovers in the theme · 8 the server
#         changed since prepare · 9 the server refused the new theme (it
#         never went live, or was swapped back) · 10 the site was already
#         failing before this publish · 11 the server has no Velk (the first
#         deploy is init) · anything else: an error (1 from die, or the
#         failing command's own code)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

action="${1:-}"
shift || true
project_args "$@"
confirm_deletions="" take_stale="" accept_live="" POS=()
for a in ${REST[@]+"${REST[@]}"}; do
    case "$a" in
        --confirm-deletions) confirm_deletions=1 ;;
        --take-over-stale)   take_stale=--take-over-stale ;;
        --accept-live-failure) accept_live=1 ;;
        --*) err "Unknown arg: $a"; exit 2 ;;
        *) POS+=("$a") ;;
    esac
done
if [[ "$action" != resolve && ${#POS[@]} -gt 0 ]]; then err "Unexpected argument: ${POS[0]}"; exit 2; fi
if [[ -n "$confirm_deletions" && "$action" != commit ]]; then
    err "--confirm-deletions goes to commit, after the person has seen the DELETE list prepare printed."
    exit 2
fi
build_ssh_args
load_theme_filters

THEME="${PROJECT_DIR}/theme"
BASE_DIR="${PROJECT_DIR}/.deploy/theme-base"
BASE_JSON="${PROJECT_DIR}/.deploy/theme-base.json"
W="${PROJECT_DIR}/.deploy/publish"
OPEN="${W}/open-conflicts.json"        # conflicts waiting for a decision
RECOVERY_NOTES=""
warnings=()
gone_from_server=""

# ── shared steps ─────────────────────────────────────────────────────────

# refuse_source_leftovers — pages of a converted site's source left in the
# theme (theme_leftovers, ssh-lib.sh): the same rule init applies. The root
# PHPs among them never reach the server anyway — the filters keep the
# theme's root to functions.php — but skipping them in silence is how a theme
# ends up different from the one on disk without anyone noticing. Local only:
# nothing has been sent when this stops.
refuse_source_leftovers() {
    local found
    found=$(theme_leftovers "$THEME")
    [[ -z "$found" ]] && return 0
    echo "STATUS=SOURCE_LEFTOVERS"
    printf '%s\n' "$found" | sed 's/^/LEFTOVER=/'
    exit 7
}

# warn_server_leftovers — PHPs in the root of the live theme other than
# functions.php. The filters keep them out of every manifest, so a publish
# can neither see nor delete them: they're reported, for someone to remove by
# hand. (A live theme/includes/ needs no warning: it IS part of the published
# theme, and a copy without it lists it under DELETE.)
warn_server_leftovers() {
    local found
    found=$(remote_in_root 'cd theme 2>/dev/null || exit 0; for f in *.php; do if [ -f "$f" ] && [ "$f" != functions.php ]; then echo "theme/$f"; fi; done; exit 0' </dev/null 2>/dev/null || true)
    [[ -z "$found" ]] && return 0
    warnings+=("SERVER_LEFTOVERS $(tr '\n' ' ' <<< "$found" | sed 's/ *$//')")
}

# refuse_unresolved_markers — conflict markers left in a theme file. Only
# files that get published count: a .bak copy of a conflicted file is fine.
refuse_unresolved_markers() {
    local f files=""
    while IFS= read -r f; do
        [[ -z "$f" || "$f" == */ ]] && continue
        if grep -qIE '^(<<<<<<< local|>>>>>>> server)' "${THEME}/${f}" 2>/dev/null; then
            files="${files}${f}"$'\n'
        fi
    done < <(theme_list "$THEME")
    if [[ -n "$files" ]]; then
        echo "STATUS=UNRESOLVED_CONFLICTS"
        printf '%s' "$files" | sed 's/^/CONFLICT_FILE=/'
        exit 3
    fi
}

# refuse_open_conflicts — every conflict is kept in open-conflicts.json until
# it is decided (resolve). One written with markers settles by itself once its
# markers are gone, an invalid-json one once site.json decodes. Nothing moves
# on before that.
refuse_open_conflicts() {
    [[ -f "$OPEN" ]] || return 0
    local kind path settled="[]"
    if jq -e 'any(.[]; .kind == "invalid-json")' "$OPEN" >/dev/null \
       && jq -e . "${THEME}/site.json" >/dev/null 2>&1; then
        settled='["site.json"]'
    fi
    while IFS=$'\t' read -r kind path; do
        if ! grep -qE '^(<<<<<<< local|>>>>>>> server)' "${THEME}/${path}" 2>/dev/null; then
            settled=$(jq -c --arg p "$path" '. + [$p]' <<< "$settled")
        fi
    done < <(jq -r '.[] | select(.kind == "text" or .kind == "added-both") | [.kind, .path] | @tsv' "$OPEN")
    jq --argjson s "$settled" '[.[] | select(.path as $p | any($s[]; . == $p) | not)]' "$OPEN" > "${OPEN}.tmp" \
        && mv "${OPEN}.tmp" "$OPEN"
    if [[ "$(jq 'length' "$OPEN")" == 0 ]]; then rm -f "$OPEN"; return 0; fi
    echo "STATUS=UNRESOLVED_CONFLICTS"
    jq -r '.[] | "CONFLICT=\(.kind) \(.path)"' "$OPEN"
    exit 3
}

recover_first() {
    local out code
    set +e
    out=$(bash "${SCRIPT_DIR}/recover.sh" --project "$PROJECT_DIR" --config "$CONFIG_PATH" $take_stale)
    code=$?
    set -e
    if (( code == 5 )); then printf '%s\n' "$out"; exit 5; fi
    (( code == 0 )) || die "Recovering the server failed."
    RECOVERY_NOTES=$(sed -n 's/^ACTION=/RECOVERED=/p; /^WARN=/p' <<< "$out")
}

# local_checks — only in "local" mode, where there is an engine and a PHP:
# php -l on every theme .php and schema:validate. Fills LOCAL_PROBLEMS.
local_checks() {
    local php f prod mine
    LOCAL_PROBLEMS=()
    [[ "$(cfg_get '.mode')" == local && -f "${PROJECT_DIR}/bin/velk" ]] || return 0
    php=$(cfg_get '.local.php_bin'); [[ -n "$php" ]] || php=$(command -v php || true)
    if [[ -z "$php" || ! -x "$php" ]]; then warn "No local PHP — local checks skipped."; return 0; fi
    while IFS= read -r f; do
        [[ "$f" == *.php ]] || continue
        if ! "$php" -l "${THEME}/${f}" >/dev/null 2>&1; then
            "$php" -l "${THEME}/${f}" >&2 || true
            LOCAL_PROBLEMS+=("PHP_LINT=${f}")
        fi
    done < <(perl "$MANIFEST_PL" paths "$W/final.json")
    if ! ( cd "$PROJECT_DIR" && "$php" bin/velk schema:validate ) >&2; then
        LOCAL_PROBLEMS+=("SCHEMA=failed")
    fi
    prod=$("${ssh_args[@]}" "$(shell_quote "$(resolve_php_bin)") -d display_errors=stderr -d display_startup_errors=0 -r 'echo PHP_VERSION;'" \
           | cut -d. -f1,2)
    mine=$("$php" -r 'echo PHP_VERSION;' | cut -d. -f1,2)
    if [[ "$prod" != "$mine" ]]; then warnings+=("LOCAL_PHP_DIFFERS local=${mine} production=${prod}"); fi
    (( ${#LOCAL_PROBLEMS[@]} == 0 ))
}

print_lines() {   # print_lines <prefix> <jq-array-json>
    jq -r --arg p "$1" '.[] | $p + .' <<< "$2"
}

# print_merge_report — what prepare took in from the server into this copy,
# and what it left to settle.
print_merge_report() {
    print_lines "TOOK_THEIRS=" "$(jq -c '.took_theirs' <<< "$report")"
    printf '%s' "$gone_from_server" | sed 's/^/GONE_FROM_SERVER=/'
    print_lines "MERGED=" "$(jq -c '.merged' <<< "$report")"
    jq -r '.[] | "CONFLICT=\(.kind) \(.path)"' <<< "$conflicts"
}

# ── prepare ──────────────────────────────────────────────────────────────

merge_live_into_local() {
    local base_dir="$BASE_DIR" base_manifest="$BASE_JSON" code p open
    step "Bringing in what changed on the server"
    mkdir -p "$W/theirs"
    theme_rsync --delete -e "$(rsync_remote_shell)" \
        "$(rsync_target_for "$(remote_path)/theme")/" "$W/theirs/" >&2 \
        || die "Could not download the live theme."
    # Merge against exactly what was downloaded; commit checks it is still live.
    local_theme_manifest "$W/theirs" > "$W/live.json"
    # The state before the FIRST prepare — what abort restores. Built aside and
    # renamed when complete, so a copy cut short is never trusted; theme files
    # only, so abort can't touch what a publish never touches.
    if [[ ! -d "$W/pre-merge" ]]; then
        rm -rf "$W/pre-merge.tmp"
        mkdir -p "$W/pre-merge.tmp"
        theme_rsync "$THEME/" "$W/pre-merge.tmp/theme/"
        if (( has_base )); then
            theme_rsync "$BASE_DIR/" "$W/pre-merge.tmp/theme-base/"
            cp "$BASE_JSON" "$W/pre-merge.tmp/theme-base.json"
        fi
        mv "$W/pre-merge.tmp" "$W/pre-merge"
    fi
    if [[ "$decision" == two-way ]]; then
        base_dir="$W/empty"; base_manifest="$W/empty.json"
        mkdir -p "$base_dir"; echo '{"files":{}}' > "$base_manifest"
    fi
    local_theme_manifest "$THEME" > "$W/mine.json"
    mkdir -p "$W/merge"
    set +e
    report=$(perl "${SCRIPT_DIR}/merge.pl" \
        --base-dir "$base_dir" --base-manifest "$base_manifest" \
        --mine-dir "$THEME" --mine-manifest "$W/mine.json" \
        --theirs-dir "$W/theirs" --theirs-manifest "$W/live.json" --out "$W/merge")
    code=$?
    set -e
    (( code == 0 || code == 3 )) || die "The merge failed."
    # This copy's side of each conflict written with markers, for a
    # "resolve <path> local": the markers are about to replace it.
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        mkdir -p "$(dirname "$W/mine/$p")"
        cp -p "${THEME}/${p}" "$W/mine/$p"
    done < <(jq -r '.conflicts[] | select(.kind == "text" or .kind == "added-both") | .path' <<< "$report")
    # Only what the merge dropped (the server had deleted it) is removed — first,
    # so a folder the server turned into a file can be replaced — and then the
    # result goes over the local copy. Links and empty folders, which manifests
    # never list, stay where they are.
    local_theme_manifest "$W/merge" > "$W/merged.json"
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        rm -f "${THEME}/${p}"
        gone_from_server="${gone_from_server}${p}"$'\n'
    done < <(perl "$MANIFEST_PL" diff "$W/mine.json" "$W/merged.json" | jq -r '.removed[]')
    theme_rsync "$W/merge/" "$THEME/"
    # Every conflict waits in open-conflicts.json for a decision.
    open=$(jq -c '[.conflicts[]]' <<< "$report")
    if [[ "$open" != "[]" ]]; then printf '%s\n' "$open" > "$OPEN"; fi
    # The local copy now contains the server's version, so that is its new
    # starting point: a retry won't merge the same changes twice.
    record_theme_base "$PROJECT_DIR" "$server_version" "$W/theirs"
    if [[ "$decision" == two-way ]]; then perl "$MANIFEST_PL" digest "$BASE_JSON" > "$W/two-way-base"; fi
}

cmd_prepare() {
    rm -f "$W/plan.json"          # a plan never outlives the prepare that replaced it
    [[ -d "$THEME" ]] || die "No theme/ in ${PROJECT_DIR}."
    # A server without Velk gets its first deploy from init, not a publish.
    set +e; remote_in_root 'test -f core/Bootstrap.php' </dev/null 2>/dev/null; rc=$?; set -e
    (( rc != 255 )) || die "Could not read the server."
    (( rc == 0 )) || { echo "STATUS=NO_VELK"; exit 11; }
    refuse_source_leftovers
    refuse_unresolved_markers
    refuse_open_conflicts
    recover_first
    warn_server_leftovers
    state=$(remote_state) || die "Could not read the server."
    has_base=0 base_version=0
    if [[ -f "$BASE_JSON" ]]; then has_base=1; base_version=$(jq -r '.version' "$BASE_JSON"); fi
    case "$state" in
        UNREADABLE) server_state=unreadable; server_version="$base_version"; warnings+=(SERVER_RECORD_UNREADABLE) ;;
        NONE)       server_state=none;       server_version=0 ;;
        *)          server_version=$(jq -r '.version' <<< "$state"); server_state="$server_version" ;;
    esac
    if [[ "$server_state" != unreadable ]] && (( has_base && base_version > server_version )); then
        echo "STATUS=BASE_AHEAD"
        echo "BASE_VERSION=${base_version}"
        echo "SERVER_VERSION=${server_state}"
        exit 6
    fi
    next_version=$(( server_version + 1 ))

    rm -rf "$W/theirs" "$W/merge" "$W/empty" "$W/mine"
    mkdir -p "$W"
    remote_theme_manifest > "$W/live.json" || die "Could not read the live theme."
    if [[ "$server_state" != none && "$server_state" != unreadable ]] \
       && ! perl "$MANIFEST_PL" same <(printf '%s' "$state") "$W/live.json"; then
        warnings+=(CHANGED_OUTSIDE_THE_SKILL)
    fi
    if (( ! has_base )); then decision=two-way
    elif [[ "$server_state" == unreadable ]]; then
        # An unreadable record makes every difference a question — except on
        # the retry right after such a merge, whose starting point is still
        # what's live: those questions were already asked.
        if [[ -f "$W/two-way-base" && "$(cat "$W/two-way-base")" == "$(perl "$MANIFEST_PL" digest "$BASE_JSON")" ]] \
           && perl "$MANIFEST_PL" same "$BASE_JSON" "$W/live.json"; then decision=fast
        else decision=two-way
        fi
    elif perl "$MANIFEST_PL" same "$BASE_JSON" "$W/live.json"; then decision=fast
    else decision=merge
    fi

    report='{"took_theirs":[],"merged":[],"conflicts":[]}'
    if [[ "$decision" != fast ]]; then merge_live_into_local; fi

    local_theme_manifest "$THEME" > "$W/final.json"
    changes=$(perl "$MANIFEST_PL" diff "$W/live.json" "$W/final.json")
    deletions=$(jq -c '.removed' <<< "$changes")
    conflicts=$(jq -c '.conflicts' <<< "$report")

    if [[ "$conflicts" == "[]" ]] && perl "$MANIFEST_PL" same "$W/live.json" "$W/final.json"; then
        echo "STATUS=UP_TO_DATE"
        print_lines "TOOK_THEIRS=" "$(jq -c '.took_theirs' <<< "$report")"
        printf '%s' "$gone_from_server" | sed 's/^/GONE_FROM_SERVER=/'
        for w in ${warnings[@]+"${warnings[@]}"}; do echo "WARN=${w}"; done
        if [[ -n "$RECOVERY_NOTES" ]]; then echo "$RECOVERY_NOTES"; fi
        rm -rf "$W"
        exit 0
    fi

    # A site that already fails its live checks would fail them after the
    # swap too, and the new theme would be swapped back for it: say so first.
    baseline=$(live_baseline)
    home_before=$(sed -n 's/^HOME=//p' <<< "$baseline")
    accepted=$(sed -n 's/^FAILURE=//p' <<< "$baseline" | sed 's/^home page answered .*/home/' | tr '\n' ' ' | sed 's/ *$//')
    if [[ -n "$accepted" && -z "$accept_live" ]]; then
        echo "STATUS=LIVE_ALREADY_FAILING"
        grep -E '^(FAILURE|DETAIL)=' <<< "$baseline"
        print_merge_report          # the merge above already changed this copy
        for w in ${warnings[@]+"${warnings[@]}"}; do echo "WARN=${w}"; done
        if [[ -n "$RECOVERY_NOTES" ]]; then echo "$RECOVERY_NOTES"; fi
        exit 10
    fi

    if jq -e '[.added[], .changed[]] | any(test("\\.(css|js)$"))' <<< "$changes" >/dev/null; then
        unversioned=$(while IFS= read -r f; do
                          if [[ "$f" == *.php ]]; then grep -hE "asset\([^)]*\.(css|js)['\"]" "${THEME}/${f}"; fi
                      done < <(perl "$MANIFEST_PL" paths "$W/final.json") | grep -vE 'filemtime|\?v=' || true)
        if [[ -n "$unversioned" ]]; then warnings+=(CACHE_BUSTING); fi
    fi

    local_ok=1
    LOCAL_PROBLEMS=()
    if [[ "$conflicts" == "[]" ]] && ! local_checks; then local_ok=0; fi

    jq -n --arg decision "$decision" --arg server_state "$server_state" \
        --argjson server_version "$server_version" --argjson next "$next_version" \
        --arg digest "$(perl "$MANIFEST_PL" digest "$W/live.json")" \
        --argjson report "$report" --argjson deletions "$deletions" \
        --arg accepted "$accepted" --arg home_before "$home_before" \
        '{decision: $decision, server_state: $server_state, server_version: $server_version,
          next_version: $next, live_digest: $digest, took_theirs: $report.took_theirs,
          merged: $report.merged, conflicts: $report.conflicts, deletions: $deletions,
          accepted_failure: $accepted, home_before: $home_before}' \
        > "$W/plan.json"

    if   [[ "$conflicts" != "[]" ]]; then status=CONFLICTS;           code=3
    elif (( ! local_ok ));           then status=LOCAL_INVALID;       code=7
    elif [[ "$deletions" != "[]" ]]; then status=NEEDS_CONFIRMATION;  code=4
    else                                  status=READY;               code=0
    fi
    echo "STATUS=${status}"
    echo "DECISION=${decision}"
    echo "SERVER_VERSION=${server_state}"
    echo "NEXT_VERSION=${next_version}"
    print_merge_report
    print_lines "DELETE=" "$deletions"
    for w in ${warnings[@]+"${warnings[@]}"}; do echo "WARN=${w}"; done
    for p in ${LOCAL_PROBLEMS[@]+"${LOCAL_PROBLEMS[@]}"}; do echo "$p"; done
    if [[ -n "$RECOVERY_NOTES" ]]; then echo "$RECOVERY_NOTES"; fi
    exit "$code"
}

# ── commit ───────────────────────────────────────────────────────────────

cmd_commit() {
    local plan="$W/plan.json" deletions state now_state next rp php problems code report_lines
    [[ -f "$plan" ]] || { echo "STATUS=NO_PLAN"; exit 2; }
    refuse_source_leftovers          # before the snapshot: its filters would hide them
    # One copy of the theme, taken now, is what gets checked (but for the
    # local schema:validate, which the engine runs on theme/ itself), sent and
    # recorded: a file saved or deleted while this runs waits for the next
    # publish instead of slipping past the checks.
    theme_rsync --delete "$THEME/" "$W/snapshot/"
    THEME="$W/snapshot"
    refuse_unresolved_markers
    refuse_open_conflicts
    local_theme_manifest "$THEME" > "$W/final.json"
    deletions=$(perl "$MANIFEST_PL" diff "$W/live.json" "$W/final.json" | jq -c '.removed')
    if [[ "$deletions" != "$(jq -c '.deletions' "$plan")" ]]; then
        echo "STATUS=DELETIONS_CHANGED"; print_lines "DELETE=" "$deletions"; exit 4
    fi
    if [[ "$deletions" != "[]" && -z "$confirm_deletions" ]]; then
        echo "STATUS=NEEDS_CONFIRMATION"; print_lines "DELETE=" "$deletions"; exit 4
    fi
    if ! local_checks; then
        echo "STATUS=LOCAL_INVALID"; printf '%s\n' "${LOCAL_PROBLEMS[@]}"; exit 7
    fi
    recover_first
    lock_acquire "$take_stale" || { lock_report BUSY; exit 5; }
    trap 'lock_release' EXIT

    # Nothing may have changed on the server since prepare looked at it.
    state=$(remote_state) || die "Could not read the server."
    case "$state" in
        NONE) now_state=none ;; UNREADABLE) now_state=unreadable ;;
        *) now_state=$(jq -r '.version' <<< "$state") ;;
    esac
    remote_theme_manifest > "$W/live-now.json" || die "Could not read the live theme."
    if [[ "$now_state" != "$(jq -r '.server_state' "$plan")" \
          || "$(perl "$MANIFEST_PL" digest "$W/live-now.json")" != "$(jq -r '.live_digest' "$plan")" ]]; then
        echo "STATUS=STALE_PLAN"
        exit 8
    fi
    next=$(jq -r '.next_version' "$plan")
    rp=$(remote_path); php=$(resolve_php_bin)

    step "Staging the new theme on the server"
    # A theme/ that is a link would be copied as a link: the upload would land
    # in the live theme, and a swap-back would restore nothing.
    remote_in_root 'test ! -L theme' \
        || die "theme/ on the server is a link — a publish needs it to be a real folder. Nothing was sent."
    remote_in_root 'rm -rf .velk-theme-staging && cp -a theme .velk-theme-staging' \
        || die "Could not create the staging copy."
    if ! theme_rsync --delete -e "$(rsync_remote_shell)" \
            "$THEME/" "$(rsync_target_for "${rp}/.velk-theme-staging")/" >&2; then
        remote_in_root 'rm -rf .velk-theme-staging' || true
        die "Uploading to the staging copy failed — nothing went live."
    fi
    crash_point after-staging
    set +e
    problems=$(remote_script "${SCRIPT_DIR}/remote/check-staging.sh" "${rp}/.velk-theme-staging" "$php" "${FILTERS[@]}")
    code=$?
    set -e
    if (( code != 0 )); then
        remote_in_root 'rm -rf .velk-theme-staging' || true
        (( code == 1 )) || die "Could not check the staging copy — nothing went live."
        echo "STATUS=STAGING_INVALID"
        printf '%s\n' "$problems" | sed 's/^/DETAIL=/'
        exit 9
    fi

    # A recovery after a crash judges what went live by the same rules: the
    # failures accepted (first line) and the home's answer before (second).
    accepted=$(jq -r '.accepted_failure // ""' "$plan")
    home_before=$(jq -r '.home_before // ""' "$plan")
    printf '%s\n%s\n' "$accepted" "$home_before" | remote_in_root 'cat > .velk-theme-check' \
        || die "Could not record the live check's rules on the server — nothing went live."

    step "Swapping it in"
    if ! remote_in_root 'mv theme .velk-theme-previous && mv .velk-theme-staging theme'; then
        # Halfway: the live one back. Nothing went live, so no rules to keep.
        remote_in_root 'test -d theme || mv .velk-theme-previous theme; rm -f .velk-theme-check' || true
        die "The swap failed — the live theme stays."
    fi
    crash_point after-swap
    if ! validate_live "$accepted" "$home_before"; then
        swap_back || die "Swapping back FAILED — run scripts/theme/recover.sh now."
        remote_in_root 'rm -f .velk-theme-check' || true
        echo "STATUS=LIVE_INVALID"
        echo "FAILURE=${LIVE_FAILURE}"
        exit 9
    fi
    write_server_state "$next" "$(cfg_get '.identity' "$(id -un)")" \
        || die "Published, but recording v${next} failed — the next action will finish it."
    crash_point after-record
    # It is live and recorded: what's left can fail without undoing that.
    remote_in_root 'rm -rf .velk-theme-previous .velk-theme-check' \
        || warn "Published, but removing the previous copy failed — the next action removes it."
    record_theme_base "$PROJECT_DIR" "$next" "$THEME" \
        || warn "Published, but recording the local starting point failed — the next prepare rebuilds it."
    report_lines=$(jq -r '(.took_theirs[] | "TOOK_THEIRS=" + .), (.merged[] | "MERGED=" + .)' "$plan")
    rm -rf "$W"
    ok "Published as v${next}"
    echo "STATUS=PUBLISHED"
    echo "VERSION=${next}"
    if [[ -n "$report_lines" ]]; then echo "$report_lines"; fi
    printf '%s' "$LIVE_WARNINGS" | sed 's/^/WARN=/'
    if [[ -n "$RECOVERY_NOTES" ]]; then echo "$RECOVERY_NOTES"; fi
}

# ── abort / run / resolve ────────────────────────────────────────────────

cmd_abort() {
    if [[ -d "$W/pre-merge" ]]; then
        theme_rsync --delete "$W/pre-merge/theme/" "$THEME/"
        if [[ -d "$W/pre-merge/theme-base" ]]; then
            theme_rsync --delete "$W/pre-merge/theme-base/" "$BASE_DIR/"
            cp "$W/pre-merge/theme-base.json" "$BASE_JSON"
        else
            rm -rf "$BASE_DIR" "$BASE_JSON"
        fi
    fi
    rm -rf "$W"
    echo "STATUS=ABORTED"
}

cmd_run() {
    local self="${SCRIPT_DIR}/publish.sh" out code
    set +e
    out=$(bash "$self" prepare --project "$PROJECT_DIR" --config "$CONFIG_PATH" ${REST[@]+"${REST[@]}"})
    code=$?
    set -e
    if (( code != 0 )) || [[ ! -f "$W/plan.json" ]]; then    # stopped for a person, or up to date
        if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
        exit "$code"
    fi
    # commit's STATUS is the outcome; what prepare noticed on the way still counts.
    set +e
    bash "$self" commit --project "$PROJECT_DIR" --config "$CONFIG_PATH" ${REST[@]+"${REST[@]}"}
    code=$?
    set -e
    grep -E '^(GONE_FROM_SERVER|WARN|RECOVERED)=' <<< "$out" || true
    exit "$code"
}

# cmd_resolve <path> local|server — the decision on a conflict: "local" keeps
# this copy's side, "server" the live one; either side may be a deletion. The
# live side is still in theirs/, this copy's side of a conflict written with
# markers in mine/: prepare refuses to run — and so to merge again — while any
# conflict is open.
cmd_resolve() {
    local path="${POS[0]:-}" side="${POS[1]:-}" kind=""
    [[ ${#POS[@]} -eq 2 && -n "$path" && ( "$side" == local || "$side" == server ) ]] \
        || { err "Usage: publish.sh resolve --project <dir> <path> local|server"; exit 2; }
    if [[ -f "$OPEN" ]]; then
        kind=$(jq -r --arg p "$path" 'first(.[] | select(.path == $p) | .kind) // empty' "$OPEN")
    fi
    if [[ -z "$kind" ]]; then echo "STATUS=NOT_OPEN"; echo "PATH=${path}"; exit 2; fi
    case "${kind}:${side}" in
        binary:local|changed-here-deleted-there:local|deleted-here-changed-there:server) ;;  # already in place
        binary:server|text:server|added-both:server) cp -p "${W}/theirs/${path}" "${THEME}/${path}" ;;
        text:local|added-both:local)       cp -p "${W}/mine/${path}" "${THEME}/${path}" ;;
        changed-here-deleted-there:server) rm -f "${THEME}/${path}" ;;
        deleted-here-changed-there:local)  rm -f "${THEME}/${path}" ;;
        invalid-json:*) err "site.json settles by itself once it is valid JSON — fix the file."; exit 2 ;;
    esac
    jq --arg p "$path" '[.[] | select(.path != $p)]' "$OPEN" > "${OPEN}.tmp" && mv "${OPEN}.tmp" "$OPEN"
    if [[ "$(jq 'length' "$OPEN")" == 0 ]]; then rm -f "$OPEN"; fi
    echo "STATUS=RESOLVED"
    echo "PATH=${path}"
    echo "KEPT=${side}"
}

case "$action" in
    prepare) cmd_prepare ;;
    commit)  cmd_commit ;;
    abort)   cmd_abort ;;
    run)     cmd_run ;;
    resolve) cmd_resolve ;;
    *) err "Usage: publish.sh prepare|commit|abort|run --project <dir> [--confirm-deletions] [--take-over-stale] | resolve --project <dir> <path> local|server"; exit 2 ;;
esac
