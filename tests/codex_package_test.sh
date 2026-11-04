# tests/codex_package_test.sh — the plugin for ChatGPT and Codex.
#
# The skill is the same as the Claude plugin's (plugin/); tools/codex-package
# wraps it the way the OpenAI plugin directory takes it: .codex-plugin/plugin.json
# (codex/plugin.json + the version), skills/velk/, assets/. These keep the
# listing inside the portal's rules and the package in step with plugin/.

TEMPLATE="${REPO_DIR}/codex/plugin.json"

# Builds into the sandbox; prints the tool's KEY=value lines.
build_package() {
    (cd "$REPO_DIR" && bash tools/codex-package --worktree --out="${SANDBOX}/out" 2>&1)
}

# A throwaway copy of what the tool reads, to break on purpose.
copy_repo() {
    mkdir -p "${SANDBOX}/repo"
    cp -R "${REPO_DIR}/tools" "${REPO_DIR}/plugin" "${REPO_DIR}/codex" "${REPO_DIR}/VERSION" "${SANDBOX}/repo/"
}

test_the_template_leaves_the_version_to_VERSION() {
    jq -e . "$TEMPLATE" >/dev/null || fail "codex/plugin.json is not valid JSON"
    assert_eq "false" "$(jq 'has("version")' "$TEMPLATE")" "a version here would be a third place to bump"
    assert_eq "velk" "$(jq -r .name "$TEMPLATE")"
    assert_eq "./skills/" "$(jq -r .skills "$TEMPLATE")"
}

test_the_listing_fits_the_portal_rules() {
    assert_eq "true" "$(jq -r .requires_local_executor "$TEMPLATE")" "the scripts run on the user's computer: Desktop only"
    for key in hooks apps mcpServers; do
        assert_eq "false" "$(jq --arg k "$key" 'has($k)' "$TEMPLATE")" "\"$key\" keeps a plugin out of the public directory"
    done
    for field in displayName shortDescription longDescription developerName category composerIcon logo; do
        [ -n "$(jq -r ".interface.$field // empty" "$TEMPLATE")" ] || fail "interface.$field is required"
    done
    assert_eq "true" "$(jq '.interface.capabilities | type == "array"' "$TEMPLATE")"
    [ "$(jq -r '.interface.displayName | length' "$TEMPLATE")" -le 30 ] || fail "displayName over 30 characters"
    [ "$(jq -r '.interface.shortDescription | length' "$TEMPLATE")" -le 30 ] || fail "shortDescription over 30 characters"
    [ "$(jq '.interface.defaultPrompt | length' "$TEMPLATE")" -le 3 ] || fail "more than 3 default prompts"
    assert_eq "0" "$(jq '[.interface.defaultPrompt[] | select(length > 128)] | length' "$TEMPLATE")" "a default prompt over 128 characters"
}

test_both_stores_point_at_the_same_privacy_policy() {
    assert_eq "$(jq -r .privacyPolicyUrl "${SKILL_DIR}/.claude-plugin/plugin.json")" \
        "$(jq -r .interface.privacyPolicyURL "$TEMPLATE")"
}

test_the_privacy_policy_covers_both_assistants() {
    policy=$(cat "${SKILL_DIR}/PRIVACY.md")
    assert_contains "$policy" "https://www.anthropic.com/legal/privacy"
    assert_contains "$policy" "https://openai.com/policies/privacy-policy/"
    assert_not_contains "$policy" "plugin for Claude" "the title would leave ChatGPT and Codex out"
}

test_the_package_builds_from_the_working_tree() {
    out=$(build_package); code=$?
    assert_status 0 "$code" "codex-package failed: $out"
    pkg="${SANDBOX}/out/codex/marketplace/plugins/velk"
    assert_file "${pkg}/.codex-plugin/plugin.json"
    want=$(tr -d '[:space:]' < "${REPO_DIR}/VERSION")
    assert_eq "${want#v}" "$(jq -r .version "${pkg}/.codex-plugin/plugin.json")"
    assert_eq "name version" "$(jq -r 'keys_unsorted[0:2] | join(" ")' "${pkg}/.codex-plugin/plugin.json")" "name first, then version"
    for f in skills/velk/SKILL.md skills/velk/agents/openai.yaml skills/velk/assets/icon.png \
             assets/icon.png assets/logo.png README.md LICENSE PRIVACY.md; do
        assert_file "${pkg}/${f}"
    done
    [ -x "${pkg}/skills/velk/scripts/preflight.sh" ] || fail "scripts must stay executable"
    assert_no_dir "${pkg}/.claude-plugin" "the Claude manifest has no place in the Codex package"
    assert_file "${SANDBOX}/out/codex/marketplace/.agents/plugins/marketplace.json"
    assert_eq "./plugins/velk" "$(jq -r '.plugins[0].source.path' "${SANDBOX}/out/codex/marketplace/.agents/plugins/marketplace.json")"
}

test_the_zip_holds_the_plugin_root_without_a_folder_around_it() {
    build_package >/dev/null
    zip="${SANDBOX}/out/velk-codex-$(tr -d '[:space:]' < "${REPO_DIR}/VERSION").zip"
    assert_file "$zip"
    list=$(unzip -l "$zip")
    assert_contains "$list" " .codex-plugin/plugin.json"
    assert_contains "$list" " skills/velk/SKILL.md"
    assert_not_contains "$list" ".DS_Store"
}

test_the_skill_inside_is_the_claude_plugins_skill() {
    build_package >/dev/null
    skill="${SANDBOX}/out/codex/marketplace/plugins/velk/skills/velk"
    diff -r "${SKILL_DIR}/scripts" "${skill}/scripts" >/dev/null || fail "scripts/ differ from plugin/"
    for f in "${SKILL_DIR}"/references/*.md; do
        name=$(basename "$f")
        [ "$name" = "access.md" ] && continue
        cmp -s "$f" "${skill}/references/${name}" || fail "references/${name} differs from plugin/"
    done
}

test_the_two_claude_phrases_are_adapted() {
    build_package >/dev/null
    skill="${SANDBOX}/out/codex/marketplace/plugins/velk/skills/velk"
    access=$(cat "${skill}/references/access.md")
    assert_contains "$access" "Abra o Codex, numa pasta nova"
    assert_not_contains "$access" "Abra o Claude"
    assert_not_contains "$(cat "${skill}/SKILL.md")" "CLAUDE_SKILL_DIR"
}

test_a_changed_phrase_stops_the_package_instead_of_shipping_it_unadapted() {
    copy_repo
    sed -i '' 's/Abra o Claude, na aba \*\*Code\*\*/Abra o Claude Code/' "${SANDBOX}/repo/plugin/references/access.md"
    out=$(cd "${SANDBOX}/repo" && bash tools/codex-package --worktree --out="${SANDBOX}/out" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "references/access.md"
    assert_no_file "${SANDBOX}/out/velk-codex-$(tr -d '[:space:]' < "${REPO_DIR}/VERSION").zip"
}

test_hooks_in_the_manifest_stop_the_package() {
    copy_repo
    jq '. + {hooks: {}}' "${SANDBOX}/repo/codex/plugin.json" > "${SANDBOX}/p.json" && mv "${SANDBOX}/p.json" "${SANDBOX}/repo/codex/plugin.json"
    out=$(cd "${SANDBOX}/repo" && bash tools/codex-package --worktree --out="${SANDBOX}/out" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "hooks"
}

test_a_version_out_of_step_with_the_claude_plugin_stops_the_package() {
    copy_repo
    echo "v9.9.9" > "${SANDBOX}/repo/VERSION"
    out=$(cd "${SANDBOX}/repo" && bash tools/codex-package --worktree --out="${SANDBOX}/out" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "v9.9.9"
}
