# tests/theme_manifest_test.sh — what "the theme" is, and its manifest, on
# both sides of the wire.

theme_lib() {
    CONFIG_PATH="$1"
    . "${SKILL_DIR}/scripts/theme/_lib.sh"
    set +e
    build_ssh_args
    load_theme_filters
}

odd_theme() {   # a theme with every file the filters must drop, and odd names
    local d="$1"
    sandbox_theme "$d"
    mkdir -p "${d}/install" "${d}/storage" "${d}/assets/sub dir"
    echo seed > "${d}/install/seed.php"
    echo legacy > "${d}/page-legacy.php"
    echo '<?php' > "${d}/functions.php"
    echo junk > "${d}/.DS_Store"
    echo old > "${d}/style.css.bak"
    echo up > "${d}/storage/upload.jpg"
    echo 'a { }' > "${d}/assets/ação.css"
    echo 'b' > "${d}/assets/sub dir/x y.js"
}

test_the_theme_is_what_update_theme_always_shipped() {
    cfg=$(sandbox_config)
    odd_theme "${PROJECT}/theme"
    theme_lib "$cfg"
    got=$(local_theme_manifest "${PROJECT}/theme" | perl "${SKILL_DIR}/scripts/theme/manifest.pl" paths - | tr '\n' '|')
    assert_eq "assets/ação.css|assets/sub dir/x y.js|functions.php|partials/header.php|site.json|style.css|templates/home.php|" "$got"
}

test_extra_excludes_from_the_config_count_too() {
    cfg=$(sandbox_config)
    jq '.rsync.theme_extra_excludes = ["assets/"]' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    odd_theme "${PROJECT}/theme"
    theme_lib "$cfg"
    got=$(local_theme_manifest "${PROJECT}/theme" | perl "${SKILL_DIR}/scripts/theme/manifest.pl" paths -)
    assert_contains "$got" "site.json"
    assert_not_contains "$got" "assets/"
}

test_the_server_and_the_mac_compute_the_same_manifest() {
    sandbox_velk_server
    cfg=$(sandbox_config)
    odd_theme "${PROJECT}/theme"
    rm -rf "${SERVER}/theme"; cp -R "${PROJECT}/theme" "${SERVER}/theme"
    theme_lib "$cfg"
    local_theme_manifest "${PROJECT}/theme" > "${SANDBOX}/local.json"
    remote_theme_manifest > "${SANDBOX}/remote.json"
    assert_status 0 $?
    perl "${SKILL_DIR}/scripts/theme/manifest.pl" same "${SANDBOX}/local.json" "${SANDBOX}/remote.json" \
        || fail "manifests differ:"$'\n'"$(cat "${SANDBOX}/local.json")"$'\n'"$(cat "${SANDBOX}/remote.json")"
}

test_each_entry_is_the_sha256_of_the_file() {
    cfg=$(sandbox_config)
    sandbox_theme "${PROJECT}/theme"
    theme_lib "$cfg"
    want="sha256:$(shasum -a 256 "${PROJECT}/theme/style.css" | awk '{print $1}')"
    got=$(local_theme_manifest "${PROJECT}/theme" | jq -r '.files["style.css"]')
    assert_eq "$want" "$got"
}

test_diff_names_what_was_added_removed_and_changed() {
    printf '{"files":{"a":"sha256:1","b":"sha256:2","c":"sha256:3"}}' > "${SANDBOX}/x.json"
    printf '{"files":{"a":"sha256:1","b":"sha256:9","d":"sha256:4"}}' > "${SANDBOX}/y.json"
    out=$(perl "${SKILL_DIR}/scripts/theme/manifest.pl" diff "${SANDBOX}/x.json" "${SANDBOX}/y.json")
    assert_eq '{"added":["d"],"changed":["b"],"removed":["c"]}' "$out"
}

test_same_compares_only_the_file_map() {
    printf '{"format":1,"version":7,"published_by":"Maria","files":{"a":"sha256:1"}}' > "${SANDBOX}/state.json"
    printf '{"files":{"a":"sha256:1"}}' > "${SANDBOX}/m.json"
    perl "${SKILL_DIR}/scripts/theme/manifest.pl" same "${SANDBOX}/state.json" "${SANDBOX}/m.json" || fail "should be the same"
    printf '{"files":{"a":"sha256:2"}}' > "${SANDBOX}/m.json"
    perl "${SKILL_DIR}/scripts/theme/manifest.pl" same "${SANDBOX}/state.json" "${SANDBOX}/m.json" && fail "should differ"
    true
}

test_digest_does_not_depend_on_key_order() {
    printf '{"files":{"a":"sha256:1","b":"sha256:2"}}' > "${SANDBOX}/x.json"
    printf '{"version":3,"files":{"b":"sha256:2","a":"sha256:1"}}' > "${SANDBOX}/y.json"
    d=$(perl "${SKILL_DIR}/scripts/theme/manifest.pl" digest "${SANDBOX}/x.json")
    [[ "$d" =~ ^[0-9a-f]{64}$ ]] || fail "not a sha256: [$d]"
    assert_eq "$(perl "${SKILL_DIR}/scripts/theme/manifest.pl" digest "${SANDBOX}/x.json")" \
              "$(perl "${SKILL_DIR}/scripts/theme/manifest.pl" digest "${SANDBOX}/y.json")"
}

test_shell_quote_survives_quotes_spaces_and_globs() {
    cfg=$(sandbox_config)
    theme_lib "$cfg"
    out=$("${ssh_args[@]}" "printf '[%s]' $(shell_quote "it's" '*.bak' 'a b' 'ação')")
    assert_eq "[it's][*.bak][a b][ação]" "$out"
}
