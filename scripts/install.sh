#!/usr/bin/env bash
# Heimdall Bridge bootstrap for Linux, macOS and Termux:
#
#   curl -fsSL install.ninjy.ai | bash -s -- --hub https://hub.example.com
#
# It only resolves a release, downloads this machine's bundle, verifies it
# against the release's SHA256SUMS and runs `ham-bridge setup --headless` from
# it with every other argument passed through. Installing, enrolling, the user
# service, extensions and rollback all live in ham-bridge (`ham-bridge setup
# --help`); updates use `ham-bridge update --version`. Self-contained: it makes
# no assumption about where it was fetched from (install.ninjy.ai, a release
# asset or main). Execution stays behind main for `curl | bash`.
REPO=tanmayv/heimdall-agent-manager
usage() {
  cat <<'HELP'
Usage: install.sh [--version TAG|latest] [--bundle FILE --checksum-file FILE]
                  [ham-bridge setup flags: --hub URL --profile NAME --new-bridge
                   --reuse-bridge ID --json-progress ...]
       install.sh --uninstall [ham-bridge uninstall flags]
Without --version, installs the newest promoted (non-prerelease) release.
--bundle/--checksum-file install an already-downloaded bundle (verified first).
--name NAME is accepted as --profile NAME. Everything else goes to ham-bridge.
Requires curl, tar and sha256sum (or shasum). Run as your login user, not root.
HELP
}
fail() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
log() { printf '[%s] %s\n' "$1" "$2" >&2; }
fetch() {
  curl --fail --location --silent --show-error --connect-timeout 15 \
    --max-time 600 --speed-limit 1024 --speed-time 60 "$1" --output "$2"
}
json_tokens() {
  LC_ALL=C grep -oE '"([^"\\]|\\.)*"|[][{}:,]|true|false|null|-?[0-9][0-9.eE+-]*' "$1"
}
# Newest promoted (non-draft, non-prerelease) release in GitHub's release list
# $1 carrying SHA256SUMS and the bundle of the first target in $2.. that any
# listed release carries. Exit 2: not a release list; 1: no such release.
select_release() {
  local file="$1"; shift
  { json_tokens "$file" || true; } | LC_ALL=C awk -v targets="$*" '
    # The text of a JSON string token; \uXXXX escapes are kept as they are.
    function unq(s,  out, c) {
      s = substr(s, 2, length(s) - 2); out = ""
      while (match(s, /\\./)) {
        c = substr(s, RSTART + 1, 1)
        out = out substr(s, 1, RSTART - 1) (c == "n" ? "\n" : c == "t" ? "\t" : c == "r" ? "\r" : c == "u" ? "\\u" : c)
        s = substr(s, RSTART + 2)
      }
      return out s
    }
    function truthy(t) { return !(t == "false" || t == "null" || t == "0" || t == "\"\"") }
    function value(t,  i) {
      if (d < 2 || typ[1] != "a" || typ[2] != "o") return
      i = idx[1]
      if (d == 2) {
        if (key[2] == "tag_name" && t ~ /^"/) tag[i] = unq(t)
        else if (key[2] == "draft") draft[i] = truthy(t)
        else if (key[2] == "prerelease") pre[i] = truthy(t)
      } else if (d == 4 && key[2] == "assets" && typ[3] == "a" && typ[4] == "o" && key[4] == "name" && t ~ /^"/) {
        has[i, unq(t)] = 1
      }
    }
    NR == 1 && $0 != "[" { exit 2 }
    { t = $0; seen = 1 }
    t == "{" || t == "[" {
      if (d == 1 && typ[1] == "a") n = idx[1] + 1
      d++; typ[d] = (t == "{") ? "o" : "a"; idx[d] = 0; ek[d] = (t == "{"); key[d] = ""; next
    }
    t == "}" || t == "]" { d--; next }
    t == ":" { ek[d] = 0; next }
    t == "," { if (typ[d] == "a") idx[d]++; else ek[d] = 1; next }
    typ[d] == "o" && ek[d] { key[d] = unq(t); next }
    { value(t) }
    END {
      if (!seen) exit 2
      split(targets, list, " ")
      for (j = 1; (j in list); j++)
        for (i = 0; i < n; i++)
          if (!draft[i] && !pre[i] && ((i, "SHA256SUMS") in has) && ((i, "heimdall-local-" list[j] "-" tag[i] ".tar.gz") in has)) {
            print tag[i]; exit 0
          }
      exit 1
    }'
}
sha256_of() {
  local out
  if command -v sha256sum >/dev/null; then out="$(sha256sum < "$1")" || return 1
  else out="$(shasum -a 256 < "$1")" || return 1; fi
  printf '%s\n' "${out%% *}"
}
# Whether file $2 matches the single SHA256SUMS ($1) entry named $3.
sha256_matches() {
  local expected actual
  expected="$(awk -v n="$3" '{ sub(/\r$/, "") } NF == 2 { f = $2; sub(/^\*+/, "", f); if (f == n) { c++; h = tolower($1) } }
    END { if (c == 1) print h; else exit 1 }' "$1")" || return 1
  actual="$(sha256_of "$2")" || return 1
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}
# Release target: <os>-<arch>, termux-<arch> on Android (its seccomp kills the
# glibc linux-* binaries; releases before v0.3.29 have no termux bundle).
detect_target() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) fail 'Supported platforms: Linux and macOS (Windows: install.ps1).' ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) fail 'Supported architectures: amd64 and arm64.' ;; esac
  if [ -n "${TERMUX_VERSION:-}" ]; then os=termux
  else case "${PREFIX:-}" in /data/data/com.termux|/data/data/com.termux/*) os=termux ;; esac; fi
  printf '%s-%s\n' "$os" "$arch"
}
main() {
  set -euo pipefail
  local version='' bundle='' sums='' verb=setup
  local -a pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version|--bundle|--checksum-file)
        [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
        case "$1" in --version) version="$2" ;; --bundle) bundle="$2" ;; *) sums="$2" ;; esac
        shift 2 ;;
      --name) [ "$#" -ge 2 ] || fail '--name requires a value'; pass+=(--profile "$2"); shift 2 ;;
      --hub-url) [ "$#" -ge 2 ] || fail '--hub-url requires a value'; pass+=(--hub "$2"); shift 2 ;;
      --uninstall) verb=uninstall; shift ;;
      --help|-h) usage; return ;;
      *) pass+=("$1"); shift ;;
    esac
  done
  [ "$(id -u)" != 0 ] || fail 'Run as your login user without sudo; the bridge is a user service.'
  [ -z "${HEIMDALL_BRIDGE_NAME:-}" ] || pass=(--profile "$HEIMDALL_BRIDGE_NAME" ${pass[@]+"${pass[@]}"})
  command -v curl >/dev/null || fail 'curl is required.'
  command -v tar >/dev/null || fail 'tar is required.'
  command -v sha256sum >/dev/null || command -v shasum >/dev/null || fail 'sha256sum (coreutils) or shasum is required.'
  local target work
  target="$(detect_target)"
  work="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-install.XXXXXX")"
  trap "$(printf 'rm -rf %q' "$work")" EXIT
  local archive
  if [ -n "$bundle" ] || [ -n "$sums" ]; then
    [ -f "$bundle" ] && [ -f "$sums" ] || fail '--bundle and --checksum-file must both name regular files.'
    archive="$(basename "$bundle")"
    case "$archive" in heimdall-local-"$target"-*.tar.gz) ;; *) fail "Bundle $archive is not for this machine ($target)." ;; esac
    cp "$sums" "$work/SHA256SUMS"; cp "$bundle" "$work/$archive"
  else
    if [ -z "$version" ] || [ "$version" = latest ]; then
      # Releases start as prereleases (canary candidates); only promoted ones are picked.
      fetch "https://api.github.com/repos/$REPO/releases?per_page=30" "$work/releases.json" ||
        fail 'Cannot list releases from GitHub; pass --version TAG.'
      local rc=0
      version="$(select_release "$work/releases.json" "$target")" || rc=$?
      [ "$rc" != 2 ] || fail 'GitHub did not return a release list; pass --version TAG.'
      [ "$rc" = 0 ] || fail "No promoted release has a $target bundle. Pass --version TAG."
    fi
    [[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Invalid release tag: $version"
    archive="heimdall-local-$target-$version.tar.gz"
    local base="https://github.com/$REPO/releases/download/$version"
    log INFO "Release $version ($target)"
    fetch "$base/SHA256SUMS" "$work/SHA256SUMS" || fail "Release $version has no SHA256SUMS (unknown tag?)."
    log INFO "Downloading $archive"
    fetch "$base/$archive" "$work/$archive" || fail "Release $version has no $archive."
  fi
  sha256_matches "$work/SHA256SUMS" "$work/$archive" "$archive" || fail 'SHA-256 verification failed; nothing installed.'
  log OK "SHA-256 verified: $archive"
  mkdir "$work/bundle"
  tar -xzf "$work/$archive" -C "$work/bundle" || fail 'Cannot unpack the bundle; nothing installed.'
  local bridge="$work/bundle/bin/ham-bridge"
  [ -f "$bridge" ] && [ ! -L "$bridge" ] || fail 'The bundle has no bin/ham-bridge.'
  chmod 755 "$bridge"
  # ham-bridge copies what it needs out of the bundle, so the temporary copy is
  # removed afterwards. stdin is not the script's: `curl | bash` already read it.
  local status=0
  if [ "$verb" = uninstall ]; then
    "$bridge" uninstall ${pass[@]+"${pass[@]}"} < /dev/null || status=$?
  else
    "$bridge" setup --headless ${pass[@]+"${pass[@]}"} < /dev/null || status=$?
  fi
  exit "$status"
}
main "$@"
