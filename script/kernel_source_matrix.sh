#!/usr/bin/env bash

# shellcheck shell=bash

declare -ar KERNEL_SERIES=(
  "5.10"
  "5.15"
  "6.1"
  "6.6"
  "6.12"
  "6.18"
)

# Static versions are a fallback for offline builds. Online builds resolve the
# latest active release for each series from kernel.org at runtime.
declare -Ar KERNEL_VERSION_BY_SERIES=(
  ["5.10"]="5.10.257"
  ["5.15"]="5.15.208"
  ["6.1"]="6.1.174"
  ["6.6"]="6.6.141"
  ["6.12"]="6.12.91"
  ["6.18"]="6.18.33"
)

KERNEL_RELEASES_JSON_URL="${KERNEL_RELEASES_JSON_URL:-https://www.kernel.org/releases.json}"
KERNEL_USE_ONLINE_LATEST="${KERNEL_USE_ONLINE_LATEST:-1}"
KERNEL_RELEASES_JSON_CACHE=""
declare -A KERNEL_RESOLVED_VERSION_BY_SERIES=()

kernel_series_list() {
  printf '%s\n' "${KERNEL_SERIES[@]}"
}

kernel_query_latest_version_for_series() {
  local series=$1
  local latest
  local releases_json

  [[ "$KERNEL_USE_ONLINE_LATEST" != 0 ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  if [[ -z "$KERNEL_RELEASES_JSON_CACHE" ]]; then
    KERNEL_RELEASES_JSON_CACHE="$(curl -fsSL --retry 3 --retry-delay 2 "$KERNEL_RELEASES_JSON_URL" 2>/dev/null)" || return 1
  fi

  releases_json=$KERNEL_RELEASES_JSON_CACHE
  [[ -n "$releases_json" ]] || return 1

  latest="$(
    printf '%s\n' "$releases_json" \
      | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
      | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
      | awk -v series="$series" 'index($0, series ".") == 1 { print }' \
      | sort -V \
      | tail -n 1
  )"

  [[ -n "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

kernel_full_version_for_series() {
  local series=$1
  local version

  if [[ -n ${KERNEL_RESOLVED_VERSION_BY_SERIES[$series]:-} ]]; then
    printf '%s\n' "${KERNEL_RESOLVED_VERSION_BY_SERIES[$series]}"
    return 0
  fi

  if version="$(kernel_query_latest_version_for_series "$series")"; then
    KERNEL_RESOLVED_VERSION_BY_SERIES[$series]=$version
    printf '%s\n' "$version"
    return 0
  fi

  [[ -n ${KERNEL_VERSION_BY_SERIES[$series]:-} ]] || return 1
  KERNEL_RESOLVED_VERSION_BY_SERIES[$series]=${KERNEL_VERSION_BY_SERIES[$series]}
  printf '%s\n' "${KERNEL_VERSION_BY_SERIES[$series]}"
}

kernel_source_name_for_series() {
  local series=$1
  local version

  version="$(kernel_full_version_for_series "$series")" || return 1
  printf 'linux-%s\n' "$version"
}

kernel_version_sort_key() {
  local version=$1
  local major minor patch

  IFS='.' read -r major minor patch <<<"$version"
  patch=${patch:-0}
  printf '%05d%05d%05d\n' "$major" "$minor" "$patch"
}

kernel_detect_version_from_name() {
  local name=$1
  local base=${name##*/}

  base=${base%.tar.gz}
  base=${base%.tar.xz}
  base=${base%.tar.zst}
  base=${base%.tar.bz2}
  base=${base%.tgz}
  base=${base%.txz}
  base=${base%.tbz2}

  if [[ "$base" =~ ([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
    printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-0}"
    return 0
  fi

  return 1
}

kernel_find_best_series_for_version() {
  local detected_version=$1
  local short_series=${detected_version%.*}
  local detected_key best_series="" best_key=""
  local candidate_series
  local candidate_key

  detected_key=$(kernel_version_sort_key "$detected_version")

  for candidate_series in "${KERNEL_SERIES[@]}"; do
    if [[ "$candidate_series" == "$short_series" ]]; then
      printf '%s\n' "$candidate_series"
      return 0
    fi
  done

  for candidate_series in "${KERNEL_SERIES[@]}"; do
    candidate_key=$(kernel_version_sort_key "$candidate_series")
    if [[ "$candidate_key" > "$detected_key" ]]; then
      continue
    fi
    if [[ -z "$best_key" || "$candidate_key" > "$best_key" ]]; then
      best_key=$candidate_key
      best_series=$candidate_series
    fi
  done

  [[ -n "$best_series" ]] || return 1
  printf '%s\n' "$best_series"
}

kernel_tarball_name_for_version() {
  local version=$1

  printf 'linux-%s.tar.xz\n' "$version"
}

kernel_tarball_url_for_version() {
  local version=$1
  local major=${version%%.*}

  printf 'https://cdn.kernel.org/pub/linux/kernel/v%s.x/linux-%s.tar.xz\n' "$major" "$version"
}
