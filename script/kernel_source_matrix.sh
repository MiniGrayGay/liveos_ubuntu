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

declare -Ar KERNEL_VERSION_BY_SERIES=(
  ["5.10"]="5.10.252"
  ["5.15"]="5.15.202"
  ["6.1"]="6.1.168"
  ["6.6"]="6.6.134"
  ["6.12"]="6.12.81"
  ["6.18"]="6.18.22"
)

declare -Ar KERNEL_SOURCE_BY_SERIES=(
  ["5.10"]="linux-5.10.252"
  ["5.15"]="linux-5.15.202"
  ["6.1"]="linux-6.1.168"
  ["6.6"]="linux-6.6.134"
  ["6.12"]="linux-6.12.81"
  ["6.18"]="linux-6.18.22"
)

kernel_series_list() {
  printf '%s\n' "${KERNEL_SERIES[@]}"
}

kernel_source_name_for_series() {
  local series=$1

  [[ -n ${KERNEL_SOURCE_BY_SERIES[$series]:-} ]] || return 1
  printf '%s\n' "${KERNEL_SOURCE_BY_SERIES[$series]}"
}

kernel_full_version_for_series() {
  local series=$1

  [[ -n ${KERNEL_VERSION_BY_SERIES[$series]:-} ]] || return 1
  printf '%s\n' "${KERNEL_VERSION_BY_SERIES[$series]}"
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
