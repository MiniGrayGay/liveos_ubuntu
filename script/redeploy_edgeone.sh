#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDGEONE_DIR="${EDGEONE_DIR:-$ROOT_DIR/edgeone}"
EDGEONE_CLI="${EDGEONE_CLI:-edgeone}"
TOKEN_ENV="${EDGEONE_TOKEN_ENV:-EDGEGLOBAL}"
EDGEONE_AREA="${EDGEONE_AREA:-global}"
MAX_FILE_BYTES="${EDGEONE_MAX_FILE_BYTES:-26214400}"
MIN_EDGEONE_VERSION="1.2.30"
REWRITE_SOURCE="${EDGEONE_REWRITE_SOURCE:-$ROOT_DIR/context.rewrite}"
GENERATE_REWRITE_CONFIG="${EDGEONE_GENERATE_REWRITE_CONFIG:-1}"
GENERATE_CASE_MIDDLEWARE="${EDGEONE_GENERATE_CASE_MIDDLEWARE:-1}"
GENERATE_INDEX="${EDGEONE_GENERATE_INDEX:-1}"

usage() {
  cat <<'EOF'
Usage: redeploy_edgeone.sh [--generate-rewrite-only]

Redeploy the local edgeone/ directory to EdgeOne Pages.

Environment:
  EDGEGLOBAL              API token used by default
  EDGEONE_TOKEN           Fallback API token if EDGEGLOBAL is unset
  EDGEONE_TOKEN_ENV=name  Read token from a different environment variable
  EDGEONE_AREA=global     EdgeOne Pages deploy area, default: global
  EDGEONE_DIR=path        Directory to deploy, default: <repo>/edgeone
  EDGEONE_CLI=path        EdgeOne CLI binary, default: edgeone
  EDGEONE_MAX_FILE_BYTES  Single-file size limit, default: 26214400
  EDGEONE_REWRITE_SOURCE  Rewrite alias source, default: <repo>/context.rewrite
  EDGEONE_GENERATE_REWRITE_CONFIG
                         Generate EdgeOne rewrite files before deploy, default: 1
  EDGEONE_GENERATE_CASE_MIDDLEWARE
                         Generate case-insensitive path fallback middleware,
                         default: 1
  EDGEONE_GENERATE_INDEX Generate edgeone/index.html file list, default: 1

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

clean_edgeone_build_artifacts() {
  local build_dir="$EDGEONE_DIR/.edgeone"
  local project_file="$build_dir/project.json"
  local tmp_project=""

  [[ -d "$build_dir" ]] || return 0

  if [[ -f "$project_file" ]]; then
    tmp_project="$build_dir/project.json.tmp.$$"
    cp "$project_file" "$tmp_project"
  fi

  find "$build_dir" -mindepth 1 -maxdepth 1 \
    ! -name "project.json.tmp.$$" \
    -exec rm -rf {} +

  if [[ -n "$tmp_project" ]]; then
    mkdir -p "$build_dir"
    mv "$tmp_project" "$project_file"
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

json_string() {
  local value=$1

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\r'/\\r}
  value=${value//$'\n'/\\n}
  value=${value//$'\t'/\\t}

  printf '"%s"' "$value"
}

generate_rewrite_config() {
  local source=$REWRITE_SOURCE
  local context_target="$EDGEONE_DIR/context.rewrite"
  local edgeone_target="$EDGEONE_DIR/edgeone.json"
  local context_tmp="$context_target.tmp.$$"
  local edgeone_tmp="$edgeone_target.tmp.$$"
  local raw_line line real_path real_norm alias alias_norm real_out
  local line_no=0
  local entry_count=0
  local alias_count=0
  local first_rewrite=1
  local hidden=0
  local -a fields aliases_norm
  local -A alias_seen=()

  [[ -f "$source" ]] || die "rewrite source not found: $source"

  exec 3>"$context_tmp"
  exec 4>"$edgeone_tmp"

  printf '# Generated from %s by script/redeploy_edgeone.sh\n' "$source" >&3
  printf '# Format: <real path> <alias path> [alias path ...]\n' >&3
  printf '{\n  "rewrites": [\n' >&4

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line_no=$((line_no + 1))
    line=${raw_line%%#*}
    read -r -a fields <<<"$line"

    if [[ "${#fields[@]}" -eq 0 ]]; then
      continue
    fi

    real_path=${fields[0]}
    hidden=0
    if [[ "$real_path" == \!* ]]; then
      hidden=1
      real_path=${real_path#!}
    fi

    if [[ "${#fields[@]}" -lt 2 && "$hidden" -ne 1 ]]; then
      die "$source:$line_no: expected real path followed by at least one alias"
    fi

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

    real_out="$real_norm"
    if (( hidden )); then
      real_out="!$real_norm"
    fi

    printf '%s' "$real_out" >&3
    for alias_norm in "${aliases_norm[@]}"; do
      printf ' %s' "$alias_norm" >&3

      if (( first_rewrite )); then
        first_rewrite=0
      else
        printf ',\n' >&4
      fi

      printf '    { "source": ' >&4
      json_string "/$alias_norm" >&4
      printf ', "destination": ' >&4
      json_string "/$real_norm" >&4
      printf ' }' >&4
    done
    printf '\n' >&3
    entry_count=$((entry_count + 1))
  done <"$source"

  printf '\n  ]\n}\n' >&4
  exec 3>&-
  exec 4>&-

  mv "$context_tmp" "$context_target"
  mv "$edgeone_tmp" "$edgeone_target"
  printf 'Generated %s and %s from %s (%d entries, %d aliases).\n' \
    "$context_target" "$edgeone_target" "$source" "$entry_count" "$alias_count"
}

generate_case_middleware() {
  local source="$EDGEONE_DIR/context.rewrite"
  local target="$EDGEONE_DIR/middleware.js"
  local tmp="$target.tmp.$$"
  local raw_line line real_path real_norm alias alias_norm file_name key
  local line_no=0
  local first_entry=1
  local hidden=0
  local -a fields
  local -A path_map=()

  while IFS= read -r file_name; do
    case "$file_name" in
      .env)
        continue
        ;;
    esac

    key="/${file_name,,}"
    if [[ -n "${path_map[$key]:-}" && "${path_map[$key]}" != "/$file_name" ]]; then
      die "case-insensitive path collision: ${path_map[$key]} and /$file_name"
    fi
    path_map[$key]="/$file_name"
  done < <(find "$EDGEONE_DIR" -maxdepth 1 -type f -printf '%f\n')

  if [[ -f "$source" ]]; then
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      line_no=$((line_no + 1))
      line=${raw_line%%#*}
      read -r -a fields <<<"$line"

      if [[ "${#fields[@]}" -eq 0 ]]; then
        continue
      fi

      real_path=${fields[0]}
      hidden=0
      if [[ "$real_path" == \!* ]]; then
        hidden=1
        real_path=${real_path#!}
      fi

      if [[ "${#fields[@]}" -lt 2 && "$hidden" -ne 1 ]]; then
        die "$source:$line_no: expected real path followed by at least one alias"
      fi

      real_norm=$(normalize_rewrite_path "$real_path") || {
        die "$source:$line_no: invalid real path: $real_path"
      }

      [[ -f "$EDGEONE_DIR/$real_norm" ]] || {
        die "$source:$line_no: real path does not exist in deploy dir: $real_norm"
      }

      for alias in "${fields[@]:1}"; do
        alias_norm=$(normalize_rewrite_path "$alias") || {
          die "$source:$line_no: invalid alias path: $alias"
        }

        key="/${alias_norm,,}"
        path_map[$key]="/$real_norm"
      done
    done <"$source"
  fi

  {
    printf 'export const config = { matcher: ["/:path*"] };\n\n'
    printf 'const CASE_INSENSITIVE_PATHS = {\n'
    while IFS=$'\t' read -r key file_name; do
      if (( first_entry )); then
        first_entry=0
      else
        printf ',\n'
      fi
      printf '  '
      json_string "$key"
      printf ': '
      json_string "$file_name"
    done < <(
      for key in "${!path_map[@]}"; do
        printf '%s\t%s\n' "$key" "${path_map[$key]}"
      done | sort
    )
    printf '\n};\n\n'
    cat <<'EOF'
export function middleware(context) {
  const url = new URL(context.request.url);

  if (url.pathname === '/') {
    return context.next();
  }

  const target = CASE_INSENSITIVE_PATHS[url.pathname.toLowerCase()];

  if (target && target !== url.pathname) {
    return context.rewrite(`${target}${url.search}`);
  }

  return context.next();
}
EOF
  } >"$tmp"

  mv "$tmp" "$target"
  printf 'Generated %s with %d case-insensitive paths.\n' "$target" "${#path_map[@]}"
}

generate_index_html() {
  local generator="$ROOT_DIR/script/generate_edgeone_index.py"

  [[ -f "$generator" ]] || die "index generator not found: $generator"
  have_tool python3 || die "required command not found: python3"

  python3 "$generator" \
    --edgeone-dir "$EDGEONE_DIR" \
    --rewrite-source "$REWRITE_SOURCE" \
    --output "$EDGEONE_DIR/index.html"
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

  if [[ "$GENERATE_CASE_MIDDLEWARE" != "0" ]]; then
    generate_case_middleware
  fi

  if [[ "$GENERATE_INDEX" != "0" ]]; then
    generate_index_html
  fi

  if (( generate_rewrite_only )); then
    return
  fi

  check_edgeone_cli
  check_file_sizes
  token="$(resolve_token)"
  clean_edgeone_build_artifacts

  case "$EDGEONE_AREA" in
    global|overseas)
      ;;
    *)
      die "invalid EDGEONE_AREA: $EDGEONE_AREA (expected global or overseas)"
      ;;
  esac

  printf 'Deploying %s to EdgeOne Pages (%s area, API token from %s)...\n' \
    "$EDGEONE_DIR" "$EDGEONE_AREA" "$TOKEN_ENV"
  (
    cd "$EDGEONE_DIR"
    PAGES_SOURCE="${PAGES_SOURCE:-skills}" "$EDGEONE_CLI" pages deploy -t "$token" -a "$EDGEONE_AREA"
  )
}

main "$@"
