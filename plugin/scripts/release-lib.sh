#!/usr/bin/env bash
# scripts/release-lib.sh — published Velk releases: which one a folder is on,
# where it came from, and how to fetch one with its integrity verified.
#
# Sourced after ssh-lib.sh (needs its die). Used by update-cms, check-engine
# and the local content setup — every place that needs the engine exactly as
# it was released, never a copy from a server or a working folder.

VELK_DEFAULT_RELEASE_BASE="https://releases.velkcms.com"

# release_base_for <dir> — the release server this install came from.
release_base_for() {
    local f="${1%/}/.velk-version"
    if [[ -f "$f" ]]; then
        jq -r --arg d "$VELK_DEFAULT_RELEASE_BASE" '.release_base_url // $d' "$f"
    else
        echo "$VELK_DEFAULT_RELEASE_BASE"
    fi
}

# version_for <dir> — .velk-version's version, else core/VERSION, else empty.
version_for() {
    local d="${1%/}" v=""
    if [[ -f "${d}/.velk-version" ]]; then
        v=$(jq -r '.version // empty' "${d}/.velk-version")
    fi
    if [[ -z "$v" && -f "${d}/core/VERSION" ]]; then
        v=$(tr -d '[:space:]' < "${d}/core/VERSION")
    fi
    printf '%s\n' "$v"
}

# fetch_release <version> <base-url> <work-dir> — downloads the release
# tarball, checks its sha256 against versions.json BEFORE extracting (a
# mismatch must never reach the filesystem), extracts it into <work-dir> and
# prints the extracted velk-<version> folder. Dies on any failure.
fetch_release() {
    local version="$1" base="$2" work="$3" index entry tarball want got src
    index=$(curl -fsSL "${base}/versions.json") || die "Could not reach ${base}/versions.json"
    entry=$(jq -c --arg v "$version" 'first(.versions[] | select(.version == $v)) // empty' <<< "$index")
    [[ -n "$entry" ]] || die "Version ${version} not published at ${base}."
    tarball="${work}/velk.tar.gz"
    curl -fsSL "$(jq -r '.url' <<< "$entry")" -o "$tarball" || die "Download of ${version} failed."
    want=$(jq -r '.sha256' <<< "$entry")
    got=$(shasum -a 256 "$tarball" | awk '{print $1}')
    [[ "$got" == "$want" ]] || die "Integrity check failed: expected ${want}, got ${got}"
    tar -xzf "$tarball" -C "$work"
    src=$(find "$work" -maxdepth 1 -type d -name 'velk-*' | head -1)
    [[ -n "$src" && -f "${src}/engine-manifest.json" ]] \
        || die "Tarball has no engine-manifest.json — version too old?"
    printf '%s\n' "$src"
}
