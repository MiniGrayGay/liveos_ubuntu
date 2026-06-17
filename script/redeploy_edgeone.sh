#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDGEONE_DIR="${EDGEONE_DIR:-$ROOT_DIR/edgeone}"
EDGEONE_CLI="${EDGEONE_CLI:-edgeone}"
TOKEN_ENV="${EDGEONE_TOKEN_ENV:-EDGEGLOBAL}"
MAX_FILE_BYTES="${EDGEONE_MAX_FILE_BYTES:-26214400}"
MIN_EDGEONE_VERSION="1.2.30"
REWRITE_SOURCE="${EDGEONE_REWRITE_SOURCE:-$ROOT_DIR/context.rewrite}"
GENERATE_REWRITE_CONFIG="${EDGEONE_GENERATE_REWRITE_CONFIG:-1}"

usage() {
  cat <<'EOF'
Usage: redeploy_edgeone.sh [--generate-rewrite-only]

Redeploy the local edgeone/ directory to EdgeOne Pages.

Environment:
  EDGEGLOBAL              API token used by default
  EDGEONE_TOKEN           Fallback API token if EDGEGLOBAL is unset
  EDGEONE_TOKEN_ENV=name  Read token from a different environment variable
  EDGEONE_DIR=path        Directory to deploy, default: <repo>/edgeone
  EDGEONE_CLI=path        EdgeOne CLI binary, default: edgeone
  EDGEONE_MAX_FILE_BYTES  Single-file size limit, default: 26214400
  EDGEONE_REWRITE_SOURCE  Rewrite alias source, default: <repo>/context.rewrite
  EDGEONE_GENERATE_REWRITE_CONFIG
                         Generate edgeone/context.rewrite before deploy, default: 1

Examples:
  EDGEGLOBAL=... ./script/redeploy_edgeone.sh
  ./script/redeploy_edgeone.sh --generate-rewrite-only
  EDGEONE_TOKEN_ENV=MY_EDGEONE_TOKEN ./script/redeploy_edgeone.sh
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have_tool() {
  command -v "$1" >/dev/null 2>&1
}

edgeone_version() {
  PAGES_SOURCE="${PAGES_SOURCE:-skills}" "$EDGEONE_CLI" -v 2>/dev/null \
    | sed -nE 's/.*version[[:space:]]+([0-9]+([.][0-9]+){2}).*/\1/p' \
    | head -n1
}

version_ge() {
  local current=$1
  local minimum=$2

  [[ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1)" == "$minimum" ]]
}

resolve_token() {
  local token=""

  if [[ -n "$TOKEN_ENV" ]]; then
    token="${!TOKEN_ENV-}"
  fi

  if [[ -z "$token" ]]; then
    token="${EDGEONE_TOKEN-}"
  fi

  [[ -n "$token" ]] || die "missing EdgeOne token: set $TOKEN_ENV or EDGEONE_TOKEN"
  printf '%s\n' "$token"
}

check_edgeone_cli() {
  local version

  have_tool "$EDGEONE_CLI" || die "missing EdgeOne CLI: $EDGEONE_CLI"

  version="$(edgeone_version)"
  [[ -n "$version" ]] || die "could not detect EdgeOne CLI version"

  version_ge "$version" "$MIN_EDGEONE_VERSION" || {
    die "EdgeOne CLI $version is older than required $MIN_EDGEONE_VERSION"
  }

  printf 'EdgeOne CLI: %s\n' "$version"
}

check_file_sizes() {
  local oversized

  oversized="$(
    find "$EDGEONE_DIR" \
      -path "$EDGEONE_DIR/.edgeone" -prune -o \
      -type f -size +"${MAX_FILE_BYTES}"c -printf '%s %p\n' \
      | sort -nr
  )"

  if [[ -n "$oversized" ]]; then
    printf 'Files exceeding %s bytes:\n%s\n' "$MAX_FILE_BYTES" "$oversized" >&2
    exit 1
  fi
}

normalize_rewrite_path() {
  local path=$1

  path=${path#/}

  case "$path" in
    ""|..|../*|*/..|*/../*)
      return 1
      ;;
  esac

  printf '%s\n' "$path"
}

generate_rewrite_config() {
  local source=$REWRITE_SOURCE
  local target="$EDGEONE_DIR/context.rewrite"
  local tmp="$target.tmp.$$"
  local raw_line line real_path real_norm alias alias_norm
  local line_no=0
  local entry_count=0
  local alias_count=0
  local -a fields aliases_norm
  local -A alias_seen=()

  [[ -f "$source" ]] || die "rewrite source not found: $source"

  {
    printf '# Generated from %s by script/redeploy_edgeone.sh\n' "$source"
    printf '# Format: <real path> <alias path> [alias path ...]\n'

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      line_no=$((line_no + 1))
      line=${raw_line%%#*}
      read -r -a fields <<<"$line"

      if [[ "${#fields[@]}" -eq 0 ]]; then
        continue
      fi

      if [[ "${#fields[@]}" -lt 2 ]]; then
        die "$source:$line_no: expected real path followed by at least one alias"
      fi

      real_path=${fields[0]}
      real_norm=$(normalize_rewrite_path "$real_path") || {
        die "$source:$line_no: invalid real path: $real_path"
      }

      [[ -f "$EDGEONE_DIR/$real_norm" ]] || {
        die "$source:$line_no: real path does not exist in deploy dir: $real_norm"
      }

      aliases_norm=()
      for alias in "${fields[@]:1}"; do
        alias_norm=$(normalize_rewrite_path "$alias") || {
          die "$source:$line_no: invalid alias path: $alias"
        }

        if [[ "$alias_norm" == "$real_norm" ]]; then
          die "$source:$line_no: alias must differ from real path: $alias_norm"
        fi

        if [[ -n "${alias_seen[$alias_norm]:-}" ]]; then
          die "$source:$line_no: duplicate alias $alias_norm, already maps to ${alias_seen[$alias_norm]}"
        fi

        alias_seen[$alias_norm]=$real_norm
        aliases_norm+=("$alias_norm")
        alias_count=$((alias_count + 1))
      done

      printf '%s' "$real_norm"
      for alias_norm in "${aliases_norm[@]}"; do
        printf ' %s' "$alias_norm"
      done
      printf '\n'
      entry_count=$((entry_count + 1))
    done <"$source"
  } >"$tmp"

  mv "$tmp" "$target"
  printf 'Generated %s from %s (%d entries, %d aliases).\n' \
    "$target" "$source" "$entry_count" "$alias_count"
}

main() {
  local token
  local generate_rewrite_only=0

  case "${1:-}" in
    -h|--help)
      usage
      return
      ;;
    --generate-rewrite-only)
      generate_rewrite_only=1
      ;;
    "")
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac

  [[ -d "$EDGEONE_DIR" ]] || die "edgeone directory not found: $EDGEONE_DIR"
  if [[ ! -f "$EDGEONE_DIR/index.html" && ! -f "$EDGEONE_DIR/middleware.js" ]]; then
    die "missing $EDGEONE_DIR/index.html or $EDGEONE_DIR/middleware.js"
  fi

  if [[ "$GENERATE_REWRITE_CONFIG" != "0" ]]; then
    generate_rewrite_config
  fi

  if (( generate_rewrite_only )); then
    return
  fi

  check_edgeone_cli
  check_file_sizes
  token="$(resolve_token)"

  printf 'Deploying %s to EdgeOne Pages...\n' "$EDGEONE_DIR"
  (
    cd "$EDGEONE_DIR"
    PAGES_SOURCE="${PAGES_SOURCE:-skills}" "$EDGEONE_CLI" pages deploy -t "$token"
  )
}

main "$@"
