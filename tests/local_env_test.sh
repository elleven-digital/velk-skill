# tests/local_env_test.sh — PHP + MySQL for "local" mode, PHP matching production.

env_setup() {   # production runs PHP 8.2.29; Homebrew is the fake one
    sandbox_config >/dev/null
    printf '#!/bin/bash\necho 8.2.29\n' > "${SANDBOX}/prod-php"; chmod +x "${SANDBOX}/prod-php"
    cfg="${PROJECT}/.deploy/ssh.json"
    jq --arg p "${SANDBOX}/prod-php" '.remote.php_bin = $p' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    export FAKE_BREW_PREFIX="${SANDBOX}/brew"
    export VELK_BREW_CANDIDATES="${TESTS_DIR}/bin/brew"
}

local_env() { bash "${SKILL_DIR}/scripts/local/env.sh" "$@" --project "$PROJECT" 2>/dev/null; }

test_check_reads_the_php_version_production_runs() {
    env_setup
    out=$(local_env check)
    assert_contains "$out" "PRODUCTION_PHP=8.2.29"
    assert_contains "$out" "FORMULA=php@8.2"
}

test_check_asks_for_homebrew_when_something_is_missing_and_there_is_none() {
    env_setup
    export VELK_BREW_CANDIDATES="${SANDBOX}/no-brew"
    out=$(local_env check)
    assert_contains "$out" "STATUS=NEEDS_BREW"
    assert_contains "$out" "LOCAL_PHP="$'\n'
    assert_eq "STATUS=NEEDS_BREW" "$(printf '%s\n' "$out" | head -1)" "STATUS= comes first"
    assert_contains "$out" "INSTALL_COMMAND=/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
}

test_check_is_ready_with_matching_php_and_mysql() {
    env_setup
    mkdir -p "${SANDBOX}/bin"
    printf '#!/bin/bash\necho 8.2\n' > "${SANDBOX}/bin/php"; printf '#!/bin/bash\n' > "${SANDBOX}/bin/mysql"
    chmod +x "${SANDBOX}/bin/"*
    cfg="${PROJECT}/.deploy/ssh.json"
    jq --arg p "${SANDBOX}/bin/php" --arg m "${SANDBOX}/bin/mysql" '.local.php_bin = $p | .local.mysql_bin = $m' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(local_env check)
    assert_contains "$out" "PHP_MATCH=yes"
    assert_contains "$out" "STATUS=READY"
    assert_eq "STATUS=READY" "$(printf '%s\n' "$out" | head -1)" "STATUS= comes first"
}

test_check_does_not_call_a_php_of_another_version_ready() {
    env_setup
    mkdir -p "${SANDBOX}/bin"
    printf '#!/bin/bash\necho 8.5\n' > "${SANDBOX}/bin/php"; printf '#!/bin/bash\n' > "${SANDBOX}/bin/mysql"
    chmod +x "${SANDBOX}/bin/"*
    cfg="${PROJECT}/.deploy/ssh.json"
    jq --arg p "${SANDBOX}/bin/php" --arg m "${SANDBOX}/bin/mysql" '.local.php_bin = $p | .local.mysql_bin = $m' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(local_env check)
    assert_contains "$out" "LOCAL_PHP_VERSION=8.5"
    assert_contains "$out" "PHP_MATCH=no"
    assert_contains "$out" "STATUS=NEEDS_INSTALL"
}

test_install_gets_the_production_php_and_mysql_and_records_them() {
    env_setup
    out=$(local_env install); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=INSTALLED"
    assert_not_contains "$out" "WARN="
    cfg="${PROJECT}/.deploy/ssh.json"
    assert_eq "${FAKE_BREW_PREFIX}/php@8.2/bin/php" "$(jq -r .local.php_bin "$cfg")"
    assert_eq "${FAKE_BREW_PREFIX}/mysql/bin/mysql" "$(jq -r .local.mysql_bin "$cfg")"
    calls=$(cat "$FAKE_CALLS")
    assert_contains "$calls" "brew install php@8.2"
    assert_contains "$calls" "brew install mysql"
    assert_contains "$calls" "brew services start mysql"
}

test_install_falls_back_to_the_current_php_and_says_so() {
    env_setup
    export FAKE_BREW_MISSING="php@8.2"
    out=$(local_env install)
    assert_contains "$out" "STATUS=INSTALLED"
    assert_contains "$out" "WARN=PHP_VERSION_MISMATCH"
    assert_eq "${FAKE_BREW_PREFIX}/php/bin/php" "$(jq -r .local.php_bin "${PROJECT}/.deploy/ssh.json")"
}

test_install_refuses_to_record_a_php_that_is_not_there() {
    env_setup
    export FAKE_BREW_BROKEN="php@8.2"
    out=$(local_env install); code=$?
    assert_status 1 "$code"
    assert_not_contains "$out" "STATUS=INSTALLED"
    assert_eq "null" "$(jq -r .local.php_bin "${PROJECT}/.deploy/ssh.json")"
}

test_install_without_homebrew_hands_over_the_official_command() {
    env_setup
    export VELK_BREW_CANDIDATES="${SANDBOX}/no-brew"
    out=$(local_env install); code=$?
    assert_status 3 "$code"
    assert_contains "$out" "STATUS=NEEDS_BREW"
    assert_contains "$out" "INSTALL_COMMAND=/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
}

test_a_noisy_production_php_still_says_its_version() {
    env_setup
    printf '#!/bin/bash\ncase " $* " in *" display_errors=stderr "*) ;; *) echo "PHP Warning:  x" ;; esac\necho 8.2.29\n' \
        > "${SANDBOX}/prod-php"
    out=$(local_env check)
    assert_contains "$out" "PRODUCTION_PHP=8.2.29"$'\n'
}
