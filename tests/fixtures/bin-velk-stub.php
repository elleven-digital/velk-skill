#!/usr/bin/env php
<?php
// Stand-in for the engine's bin/velk on the fake server (and in fake
// releases). Records each call — space-joined in .stub-calls, as a JSON
// array in .stub-argv (where "a b" and two arguments differ) — and, with
// --json-stdin, the JSON that arrived; and lets a test force a command to
// fail by writing an exit code to .stub-exit-<command> (":" becomes "-") in
// the install root.
$root = dirname(__DIR__);
$cmd  = $argv[1] ?? '';
file_put_contents($root . '/.stub-calls', implode(' ', array_slice($argv, 1)) . "\n", FILE_APPEND);
file_put_contents($root . '/.stub-argv', json_encode(array_slice($argv, 1)) . "\n", FILE_APPEND);
if (in_array('--json-stdin', $argv, true)) {
    file_put_contents($root . '/.stub-stdin', stream_get_contents(STDIN), FILE_APPEND);
}

$forced = $root . '/.stub-exit-' . str_replace(':', '-', $cmd);
if (is_file($forced)) {
    echo "forced failure of {$cmd}\n";
    exit((int) trim(file_get_contents($forced)));
}

if ($cmd === 'schema:validate') {
    $json = @file_get_contents($root . '/theme/site.json');
    if ($json === false || json_decode($json) === null) {
        echo "Invalid site.json\n";
        exit(1);
    }
    echo "site.json is valid.\n";
    exit(0);
}
exit(0);
