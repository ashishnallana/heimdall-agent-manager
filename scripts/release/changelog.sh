#!/usr/bin/env bash
# scripts/release/changelog.sh
# Prints a Markdown changelog for a release: the non-merge commits since the
# previous release tag, grouped by Conventional Commit type. Used by the
# "Release local binaries" workflow for the GitHub Release notes.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: changelog.sh <version> [release_commit] [repo_url]

Arguments:
  <version>         Release tag (e.g. "v0.4.0"); never chosen as the previous tag
  [release_commit]  Commit the release is cut from (default: HEAD)
  [repo_url]        e.g. https://github.com/owner/repo; adds commit and compare links

The previous release is the nearest v* tag reachable from the release commit's
parent, so needs full history and tags (actions/checkout fetch-depth: 0).

Examples:
  ./scripts/release/changelog.sh v0.4.0
  ./scripts/release/changelog.sh v0.4.0 6196c42 https://github.com/tanmayv/heimdall-agent-manager
USAGE
}

if [[ $# -lt 1 || $# -gt 3 || "$1" == -h || "$1" == --help ]]; then
  usage
  exit 2
fi

version="$1"
commit="$(git rev-parse --verify "${2:-HEAD}^{commit}")"
repo_url="${3:-}"

prev=""
if git rev-parse --verify --quiet "$commit^" >/dev/null; then
  prev="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude "$version" "$commit^" 2>/dev/null || true)"
fi
range="${prev:+$prev..}$commit"

breaking=() feat=() fix=() perf=() other=()
while IFS= read -r -d $'\x1e' record; do
  record="${record#$'\n'}"
  sha="${record%%$'\x1f'*}"
  rest="${record#*$'\x1f'}"
  subject="${rest%%$'\x1f'*}"
  body="${rest#*$'\x1f'}"

  # The workflow's own version-bump commit is not a change.
  [[ "$subject" =~ ^chore:\ release\ v[0-9] ]] && continue

  short="${sha:0:7}"
  ref="$short"
  [[ -n "$repo_url" ]] && ref="[$short]($repo_url/commit/$sha)"

  type="" bang="" text="$subject"
  if [[ "$subject" =~ ^([a-zA-Z]+)(\(([^\)]*)\))?(!)?:\ (.*)$ ]]; then
    type="${BASH_REMATCH[1],,}"
    bang="${BASH_REMATCH[4]}"
    text="${BASH_REMATCH[5]}"
    [[ -n "${BASH_REMATCH[3]}" ]] && text="**${BASH_REMATCH[3]}:** $text"
  fi
  line="- $text ($ref)"

  if [[ -n "$bang" ]] || grep -qE '^BREAKING[ -]CHANGE:' <<<"$body"; then
    breaking+=("$line")
    continue
  fi
  case "$type" in
    feat) feat+=("$line") ;;
    fix) fix+=("$line") ;;
    perf) perf+=("$line") ;;
    *) other+=("$line") ;;
  esac
done < <(git log --no-merges --format='%H%x1f%s%x1f%b%x1e' "$range")

section() {
  local title="$1"
  shift
  [[ $# -eq 0 ]] && return 0
  printf '### %s\n\n' "$title"
  printf '%s\n' "$@"
  printf '\n'
}

printf '## Changes since %s\n\n' "${prev:-the first commit}"
if [[ ${#breaking[@]} -eq 0 && ${#feat[@]} -eq 0 && ${#fix[@]} -eq 0 && ${#perf[@]} -eq 0 && ${#other[@]} -eq 0 ]]; then
  printf 'No code changes.\n\n'
fi
section "⚠️ Breaking changes" "${breaking[@]}"
section "Features" "${feat[@]}"
section "Fixes" "${fix[@]}"
section "Performance" "${perf[@]}"
section "Other" "${other[@]}"
if [[ -n "$prev" && -n "$repo_url" ]]; then
  printf '**Full diff:** %s/compare/%s...%s\n' "$repo_url" "$prev" "$version"
fi
