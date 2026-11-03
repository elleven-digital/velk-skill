# tests/lib/sandbox.sh — a fresh world per test: a local project, a fake
# server that is just a folder, a fake HOME, and the fakes in tests/bin
# wired through environment variables.

sandbox_create() {
    SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/velk-skill-test.XXXXXX")
    SANDBOX=$(cd "$SANDBOX" && pwd -P)
    export SANDBOX
    trap 'rm -rf "$SANDBOX"' EXIT

    # Every mktemp from here on — the scripts' backups and downloads, the
    # tests' own work folders — lands in the sandbox and goes away with it.
    # Left on the real TMPDIR, each run piled up empty velk-content-backup-*
    # files and extracted release tarballs on the Mac running the suite.
    export TMPDIR="${SANDBOX}/tmp/"
    mkdir -p "$TMPDIR"

    export HOME="${SANDBOX}/home"
    mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"

    export PROJECT="${SANDBOX}/project"
    mkdir -p "${PROJECT}/.deploy"

    export SERVER="${SANDBOX}/server/public_html"
    mkdir -p "$SERVER"

    # Commands the fake ssh runs "on the server" get PHP on their PATH, as
    # on every real Velk server — and only PHP, nothing else from Homebrew.
    export FAKE_REMOTE_PATH="${SANDBOX}/remote-bin"
    mkdir -p "$FAKE_REMOTE_PATH"
    if [ -n "$DEV_PHP" ]; then ln -s "$DEV_PHP" "${FAKE_REMOTE_PATH}/php"; fi

    # Fake ssh: any key passes unless a test calls sandbox_require_auth.
    export FAKE_SSH_ALLOW_ALL=1
    export FAKE_SSH_AUTHORIZED="${SANDBOX}/authorized_keys"; : > "$FAKE_SSH_AUTHORIZED"
    export FAKE_SSH_G_OUTPUT="${SANDBOX}/ssh-G"
    unset FAKE_SSH_UNREACHABLE FAKE_SSH_ERROR

    # Fake curl: https://site.test/... answers with this status.
    export FAKE_HTTP_STATUS_FILE="${SANDBOX}/http_status"; echo 200 > "$FAKE_HTTP_STATUS_FILE"

    # Every fake appends one line per call here.
    export FAKE_CALLS="${SANDBOX}/calls.log"; : > "$FAKE_CALLS"
}

sandbox_skip() { echo "$*"; exit 99; }

sandbox_require_php() {
    [ -n "$DEV_PHP" ] || sandbox_skip "needs php on the dev machine for the fake server"
}

sandbox_require_auth() { unset FAKE_SSH_ALLOW_ALL; }

# sandbox_authorize <file.pub> — the fake server accepts this key from now on.
sandbox_authorize() { awk '{print $2}' "$1" >> "$FAKE_SSH_AUTHORIZED"; }

# sandbox_config [project] [identity] — the .deploy/ssh.json every SSH test
# uses; prints its path.
sandbox_config() {
    local project="${1:-$PROJECT}" identity="${2:-Tester}"
    mkdir -p "${project}/.deploy"
    cat > "${project}/.deploy/ssh.json" <<JSON
{
  "ssh": { "host": "site.test", "port": 65002, "user": "u1",
           "key_path": "${HOME}/.ssh/id_ed25519", "remote_path": "${SERVER}" },
  "site": { "url": "https://site.test", "subpath": "" },
  "identity": "${identity}"
}
JSON
    echo "${project}/.deploy/ssh.json"
}

# sandbox_velk_server — a minimal installed Velk on the fake server: the
# marker preflight.sh looks for, and a bin/velk stand-in tests can break.
sandbox_velk_server() {
    sandbox_require_php
    mkdir -p "${SERVER}/core" "${SERVER}/bin" "${SERVER}/theme"
    echo '<?php' > "${SERVER}/core/Bootstrap.php"
    cp "${TESTS_DIR}/fixtures/bin-velk-stub.php" "${SERVER}/bin/velk"
    chmod +x "${SERVER}/bin/velk"
}

# noisy_server_php — the fake server's php prints a startup warning on
# stdout, as a broken php.ini makes it do, unless told display_errors=stderr.
noisy_server_php() {
    rm -f "${FAKE_REMOTE_PATH}/php"
    printf '#!/bin/bash\ncase " $* " in *" display_errors=stderr "*) ;; *) echo "PHP Warning:  Module already loaded in Unknown on line 0" ;; esac\nexec "%s" "$@"\n' \
        "$DEV_PHP" > "${FAKE_REMOTE_PATH}/php"
    chmod +x "${FAKE_REMOTE_PATH}/php"
}

# lock_as <owner> <seconds-ago> — someone's publish lock on the fake server,
# taken that long ago by the server's clock.
lock_as() {
    mkdir -p "${SERVER}/.velk-theme.lock"
    echo "$1" > "${SERVER}/.velk-theme.lock/owner"
    echo $(( $(date -u +%s) - $2 )) > "${SERVER}/.velk-theme.lock/since"
}

# unrecorded_swap_with_warning — this machine's Tester died right after
# swapping a theme in, on a publish that had accepted a failing
# schema:validate (still failing): the next recovery finishes it, warning.
unrecorded_swap_with_warning() {
    cp -R "${SERVER}/theme" "${SERVER}/.velk-theme-previous"
    echo 'body { color: blue; }' > "${SERVER}/theme/style.css"
    printf 'schema:validate\n200\n' > "${SERVER}/.velk-theme-check"
    echo 1 > "${SERVER}/.stub-exit-schema-validate"
    lock_as "Tester@$(hostname -s)" 30
}

# sandbox_theme <dir> — a small valid theme.
sandbox_theme() {
    local d="$1"
    mkdir -p "${d}/templates" "${d}/partials"
    printf '{\n  "site": { "name": "Teste" }\n}\n' > "${d}/site.json"
    printf '<?php echo "home";\n' > "${d}/templates/home.php"
    printf '<?php // header\n' > "${d}/partials/header.php"
    printf 'body { color: #111; }\n' > "${d}/style.css"
}

# sandbox_release <version> [forced-sha] [jq-filter] — a published release
# served from file://, with the same shape as releases.velkcms.com (the filter
# edits its engine-manifest.json). Prints the base URL.
sandbox_release() {
    local v="$1" dir="${SANDBOX}/releases" build="${SANDBOX}/build"
    local src="${build}/velk-${v}" sha
    mkdir -p "$dir" "${src}/core" "${src}/bin" "${src}/config" "${src}/migrations" "${src}/docs"
    echo '<?php // engine' > "${src}/core/Bootstrap.php"
    echo '<?php // app' > "${src}/core/App.php"
    echo "$v" > "${src}/core/VERSION"
    cp "${TESTS_DIR}/fixtures/bin-velk-stub.php" "${src}/bin/velk"
    chmod +x "${src}/bin/velk"
    echo '<?php return [];' > "${src}/config/env.php"
    echo '<?php // 001' > "${src}/migrations/001_init.php"
    echo '<?php require __DIR__ . "/core/Bootstrap.php";' > "${src}/index.php"
    echo 'APP_NAME="Velk"' > "${src}/.env.example"
    echo "# messages ${v}" > "${src}/docs/messages.md"    # an engine FILE inside a folder, like the real one
    printf '/theme/\n.htaccess\n' > "${src}/.gitignore"          # the engine repo's own, like the real one
    cat > "${src}/engine-manifest.json" <<'JSON'
{ "format_version": 1,
  "engine_paths": ["core/", "config/", "bin/", "migrations/", "index.php",
                   ".env.example", "docs/messages.md", ".gitignore", "engine-manifest.json"],
  "post_install_cleanup": ["migrations/", ".gitignore", "engine-manifest.json"] }
JSON
    if [ -n "${3:-}" ]; then
        jq "$3" "${src}/engine-manifest.json" > "${src}/m.tmp" && mv "${src}/m.tmp" "${src}/engine-manifest.json"
    fi
    tar -czf "${dir}/velk-${v}.tar.gz" -C "$build" "velk-${v}"
    sha=$(shasum -a 256 "${dir}/velk-${v}.tar.gz" | awk '{print $1}')
    [ -n "${2:-}" ] && sha="$2"
    printf '{"versions":[{"version":"%s","url":"file://%s/velk-%s.tar.gz","sha256":"%s"}]}\n' \
        "$v" "$dir" "$v" "$sha" > "${dir}/versions.json"
    echo "file://${dir}"
}

# sandbox_engine_project <version> <base-url> [dir] — an installed project on
# that release: its engine paths minus what an install cleans up, plus the
# .velk-version an install writes.
sandbox_engine_project() {
    local v="$1" base="$2" dir="${3:-$PROJECT}"
    rsync -a --exclude='/migrations/' --exclude='/engine-manifest.json' --exclude='/.gitignore' \
        "${SANDBOX}/build/velk-${v}/" "${dir}/"
    printf '{"version":"%s","release_base_url":"%s"}\n' "$v" "$base" > "${dir}/.velk-version"
}
