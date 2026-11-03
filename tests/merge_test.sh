# tests/merge_test.sh — merge.pl, one test per row of the rules table
# (spec 4.2). No SSH: three folders and the script.

MANIFEST="${SKILL_DIR}/scripts/theme/manifest.pl"
MERGE="${SKILL_DIR}/scripts/theme/merge.pl"

trees() { B="${SANDBOX}/base"; M="${SANDBOX}/mine"; T="${SANDBOX}/theirs"; O="${SANDBOX}/out"; mkdir -p "$B" "$M" "$T" "$O"; }
put() {   # put <dir> <path> <content — printf %b escapes>
    mkdir -p "$(dirname "$1/$2")"
    printf '%b' "$3" > "$1/$2"
}
manifest_of() { (cd "$1" && find . -type f | sed 's|^\./||') | perl "$MANIFEST" hash "$1" > "$1.json"; }
merge() {
    manifest_of "$B"; manifest_of "$M"; manifest_of "$T"
    report=$(perl "$MERGE" --base-dir "$B" --base-manifest "$B.json" --mine-dir "$M" --mine-manifest "$M.json" \
        --theirs-dir "$T" --theirs-manifest "$T.json" --out "$O")
    code=$?
}
field() { jq -c ".$1" <<< "$report"; }

test_unchanged_on_both_sides_is_kept() {
    trees
    for d in "$B" "$M" "$T"; do put "$d" a.css 'a\n'; done
    merge
    assert_status 0 "$code"
    assert_eq "a" "$(cat "$O/a.css")"
    assert_eq '"clean"' "$(field status)"
}

test_my_change_alone_is_kept() {
    trees
    put "$B" a.css 'a\n'; put "$T" a.css 'a\n'; put "$M" a.css 'mine\n'
    merge
    assert_eq "mine" "$(cat "$O/a.css")"
    assert_eq '[]' "$(field took_theirs)"
}

test_their_change_alone_comes_in() {
    trees
    put "$B" a.css 'a\n'; put "$M" a.css 'a\n'; put "$T" a.css 'theirs\n'
    merge
    assert_eq "theirs" "$(cat "$O/a.css")"
    assert_eq '["a.css"]' "$(field took_theirs)"
}

test_the_same_change_on_both_sides_is_kept_once() {
    trees
    put "$B" a.css 'a\n'; put "$M" a.css 'same\n'; put "$T" a.css 'same\n'
    merge
    assert_status 0 "$code"
    assert_eq "same" "$(cat "$O/a.css")"
    assert_eq '[]' "$(field merged)"
}

test_changes_to_different_lines_are_joined() {
    trees
    put "$B" a.css '1\n2\n3\n4\n5\n6\n7\n'
    put "$M" a.css '1\nMINE\n3\n4\n5\n6\n7\n'
    put "$T" a.css '1\n2\n3\n4\n5\nTHEIRS\n7\n'
    merge
    assert_status 0 "$code"
    assert_eq "$(printf '1\nMINE\n3\n4\n5\nTHEIRS\n7')" "$(cat "$O/a.css")"
    assert_eq '["a.css"]' "$(field merged)"
}

test_changes_to_the_same_lines_are_a_conflict_with_labelled_markers() {
    trees
    put "$B" a.css '1\n2\n3\n'; put "$M" a.css '1\nMINE\n3\n'; put "$T" a.css '1\nTHEIRS\n3\n'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"text","path":"a.css"}]' "$(field conflicts)"
    out=$(cat "$O/a.css")
    assert_contains "$out" "<<<<<<< local"
    assert_contains "$out" "||||||| base"
    assert_contains "$out" ">>>>>>> server"
}

test_a_binary_changed_on_both_sides_is_a_conflict_keeping_mine() {
    trees
    put "$B" logo.png 'P\0base'; put "$M" logo.png 'P\0mine'; put "$T" logo.png 'P\0theirs'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"binary","path":"logo.png"}]' "$(field conflicts)"
    cmp -s "$M/logo.png" "$O/logo.png" || fail "the result must keep my binary"
}

test_a_file_i_created_stays() {
    trees
    put "$M" new.css 'mine\n'
    merge
    assert_eq "mine" "$(cat "$O/new.css")"
}

test_a_file_they_created_comes_in() {
    trees
    put "$T" new.css 'theirs\n'
    merge
    assert_eq "theirs" "$(cat "$O/new.css")"
    assert_eq '["new.css"]' "$(field took_theirs)"
}

test_the_same_file_created_on_both_sides_differently_is_a_conflict() {
    trees
    put "$M" new.css 'mine\n'; put "$T" new.css 'theirs\n'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"added-both","path":"new.css"}]' "$(field conflicts)"
    assert_contains "$(cat "$O/new.css")" "<<<<<<< local"
}

test_a_file_created_on_both_sides_one_of_them_empty_still_gets_markers() {
    trees
    put "$M" new.css ''; put "$T" new.css 'theirs\n'        # diff3 alone would join these silently
    put "$M" old.css 'mine'; put "$T" old.css ''             # no final newline: the marker still starts a line
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"added-both","path":"new.css"},{"kind":"added-both","path":"old.css"}]' "$(field conflicts)"
    assert_eq $'<<<<<<< local\n||||||| base\n=======\ntheirs\n>>>>>>> server' "$(cat "$O/new.css")"
    assert_eq $'<<<<<<< local\nmine\n||||||| base\n=======\n>>>>>>> server' "$(cat "$O/old.css")"
}

test_empty_files_come_through_empty() {
    trees
    for d in "$B" "$M" "$T"; do put "$d" .gitkeep ''; done
    put "$T" assets/.gitkeep ''                                # created there
    merge
    assert_status 0 "$code"
    for f in .gitkeep assets/.gitkeep; do
        [ -f "$O/$f" ] && [ -r "$O/$f" ] && [ ! -s "$O/$f" ] || fail "$f must come through empty and readable"
    done
    assert_eq '["assets/.gitkeep"]' "$(field took_theirs)"
}

test_emptying_a_file_they_changed_is_a_conflict_with_the_empty_side_shown() {
    trees
    put "$B" a.css 'a\n'; put "$M" a.css ''; put "$T" a.css 'theirs\n'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"text","path":"a.css"}]' "$(field conflicts)"
    assert_eq $'<<<<<<< local\n||||||| base\na\n=======\ntheirs\n>>>>>>> server' "$(cat "$O/a.css")"
}

test_a_file_they_deleted_that_i_left_alone_goes() {
    trees
    put "$B" old.css 'x\n'; put "$M" old.css 'x\n'
    merge
    assert_status 0 "$code"
    assert_no_file "$O/old.css"
    assert_eq '[]' "$(field deleted)" "not a deletion to confirm: it is already gone from the server"
}

test_a_file_i_deleted_that_they_left_alone_is_a_deletion() {
    trees
    put "$B" old.css 'x\n'; put "$T" old.css 'x\n'
    merge
    assert_status 0 "$code"
    assert_no_file "$O/old.css"
    assert_eq '["old.css"]' "$(field deleted)"
}

test_my_change_to_a_file_they_deleted_is_a_conflict_keeping_mine() {
    trees
    put "$B" f.css 'x\n'; put "$M" f.css 'mine\n'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"changed-here-deleted-there","path":"f.css"}]' "$(field conflicts)"
    assert_eq "mine" "$(cat "$O/f.css")"
}

test_their_change_to_a_file_i_deleted_is_a_conflict_keeping_theirs() {
    trees
    put "$B" f.css 'x\n'; put "$T" f.css 'theirs\n'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"deleted-here-changed-there","path":"f.css"}]' "$(field conflicts)"
    assert_eq "theirs" "$(cat "$O/f.css")"
    assert_eq '[]' "$(field deleted)"
}

test_a_clean_text_merge_that_breaks_site_json_is_a_conflict() {
    trees
    put "$B" site.json '{\n  "a": 1,\n  "s": 0,\n  "b": 2\n}\n'
    put "$M" site.json '{\n  "a": 1\n  "s": 0,\n  "b": 2\n}\n'
    put "$T" site.json '{\n  "a": 1,\n  "s": 0,\n  "b": 3\n}\n'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"invalid-json","path":"site.json"}]' "$(field conflicts)"
}

test_a_clean_merge_of_site_json_into_valid_json_is_fine() {
    trees
    put "$B" site.json '{\n  "a": 1,\n  "s": 0,\n  "b": 2\n}\n'
    put "$M" site.json '{\n  "a": 9,\n  "s": 0,\n  "b": 2\n}\n'
    put "$T" site.json '{\n  "a": 1,\n  "s": 0,\n  "b": 3\n}\n'
    merge
    assert_status 0 "$code"
    assert_eq "9 3" "$(jq -r '"\(.a) \(.b)"' "$O/site.json")"
}

test_without_a_base_nothing_different_is_joined_silently() {
    trees
    put "$M" a.css 'mine\n'; put "$T" a.css 'theirs\n'
    put "$T" only-theirs.css 't\n'; put "$M" only-mine.css 'm\n'
    put "$M" same.css 's\n'; put "$T" same.css 's\n'
    merge
    assert_status 3 "$code"
    assert_eq '[{"kind":"added-both","path":"a.css"}]' "$(field conflicts)"
    assert_file "$O/only-theirs.css"; assert_file "$O/only-mine.css"; assert_file "$O/same.css"
}

test_files_without_a_final_newline_merge_cleanly() {
    trees
    put "$B" a.js '1\n2\n3\n4\n5'
    put "$M" a.js 'M\n2\n3\n4\n5'
    put "$T" a.js '1\n2\n3\n4\nT'
    merge
    assert_status 0 "$code"
    assert_eq "$(printf 'M\n2\n3\n4\nT')" "$(cat "$O/a.js")"
    assert_eq "T" "$(tail -c 1 "$O/a.js")" "no newline may be added at the end"
}

test_odd_file_names_survive() {
    trees
    put "$B" "assets/sub dir/ação.css" 'a\n'; put "$M" "assets/sub dir/ação.css" 'a\n'
    put "$T" "assets/sub dir/ação.css" 'theirs\n'
    merge
    assert_eq "theirs" "$(cat "$O/assets/sub dir/ação.css")"
    assert_eq '["assets/sub dir/ação.css"]' "$(field took_theirs)"
}
