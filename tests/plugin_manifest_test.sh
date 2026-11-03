# tests/plugin_manifest_test.sh — the repository is a marketplace whose one
# plugin is plugin/; these keep the manifests, the version and the folder
# that reaches users in step.

PLUGIN="${SKILL_DIR}/.claude-plugin/plugin.json"
MARKET="${REPO_DIR}/.claude-plugin/marketplace.json"

test_both_manifests_are_valid_json() {
    jq -e . "$PLUGIN" >/dev/null || fail "plugin.json is not valid JSON"
    jq -e . "$MARKET" >/dev/null || fail "marketplace.json is not valid JSON"
}

test_the_marketplace_lists_the_plugin_folder_under_the_plugin_name() {
    assert_eq "velk" "$(jq -r .name "$PLUGIN")"
    assert_eq "velk" "$(jq -r '.plugins[0].name' "$MARKET")" "the entry name must match plugin.json"
    assert_eq "./plugin" "$(jq -r '.plugins[0].source' "$MARKET")"
    assert_eq "1" "$(jq '.plugins | length' "$MARKET")"
}

test_the_plugin_version_matches_VERSION() {
    # Installed copies only update when plugin.json's version changes.
    want=$(tr -d '[:space:]' < "${REPO_DIR}/VERSION")
    assert_eq "$want" "v$(jq -r .version "$PLUGIN")"
}

test_the_marketplace_entry_leaves_the_version_to_plugin_json() {
    assert_eq "null" "$(jq '.plugins[0].version' "$MARKET")"
}

test_no_top_level_bin_directory() {
    # A plugin's bin/ joins the user's PATH, and the Claude app refuses it.
    assert_no_dir "${SKILL_DIR}/bin"
    assert_no_dir "${REPO_DIR}/bin"
}

test_tests_and_tooling_stay_out_of_the_plugin_folder() {
    # Everything in plugin/ is copied to each user and read by the directory scan.
    assert_no_dir "${SKILL_DIR}/tests"
    assert_no_dir "${SKILL_DIR}/tools"
    assert_no_file "${SKILL_DIR}/PUBLICAR.md"
}

test_the_plugin_folder_holds_no_secret_shaped_values() {
    out=$(grep -r -n -E 'sk_(live|test)_[A-Za-z0-9]|whsec_[A-Za-z0-9]|S3cret|BEGIN [A-Z ]*PRIVATE KEY' "$SKILL_DIR" || true)
    assert_eq "" "$out" "fixtures that look like credentials belong in tests/"
}

test_the_manifests_carry_no_email_address() {
    out=$(grep -h -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$PLUGIN" "$MARKET" || true)
    assert_eq "" "$out" "the manifests are public"
}

test_the_plugin_folder_has_a_readme_and_a_license() {
    assert_file "${SKILL_DIR}/README.md"
    assert_file "${SKILL_DIR}/LICENSE"
    words=$(wc -w < "${SKILL_DIR}/README.md" | tr -d ' ')
    [ "$words" -ge 40 ] || fail "the directory needs a README of 40 words or more"
}

test_the_skill_description_fits_the_agent_skills_limit() {
    len=$(awk 'NR==1 && /^---/ {fm=1; next}
               fm && /^---/ {exit}
               fm && /^description:/ {d=1; next}
               fm && d && /^  / {sub(/^  /, ""); s = s (s ? " " : "") $0; next}
               fm && d {d=0}
               END {print length(s)}' "${SKILL_DIR}/SKILL.md")
    [ "$len" -gt 0 ] || fail "no description found"
    [ "$len" -le 1024 ] || fail "description is ${len} characters, the limit is 1024"
}

test_the_package_is_the_plugin_folder() {
    grep -q '"\$VERSION:plugin"' "${REPO_DIR}/tools/release" \
        || fail "tools/release must package the plugin/ folder of the tag"
}
