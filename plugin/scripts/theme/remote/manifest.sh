#!/bin/bash
# Runs ON THE SERVER, fed by remote_script:
#   manifest.sh <theme-dir> <php> <rsync filter args...>
#
# Lists the theme exactly as the Mac does — rsync decides, with the same
# filters — and hashes with PHP, which every Velk server has (jq and
# sha256sum are not guaranteed). Prints {"files": {…}}.
set -euo pipefail
theme="$1"; php="$2"; shift 2
cd "$theme"
empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
# Warnings go to stderr, never in front of the JSON (a host with a broken
# php.ini prints startup warnings otherwise).
rsync -an -8 --out-format='%n' "$@" ./ "${empty}/" | "$php" -d display_errors=stderr -d display_startup_errors=0 -r '
    $files = [];
    while (($line = fgets(STDIN)) !== false) {
        $rel = preg_replace_callback("/\\\\#([0-7]{3})/", fn($m) => chr(octdec($m[1])), rtrim($line, "\n"));
        if ($rel === "" || substr($rel, -1) === "/" || !is_file($rel) || is_link($rel)) {
            continue;
        }
        // An unreadable file must fail the manifest, not become an empty hash
        // (and PHP printing its warning on stdout, in front of the JSON).
        $hash = @hash_file("sha256", $rel);
        if ($hash === false) {
            fwrite(STDERR, "cannot read theme file: $rel\n");
            exit(4);
        }
        $files[$rel] = "sha256:" . $hash;
    }
    ksort($files, SORT_STRING);
    $json = json_encode(["files" => (object) $files], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if ($json === false) {
        fwrite(STDERR, "a theme file name is not valid UTF-8\n");
        exit(3);
    }
    echo $json, "\n";
'
