#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
version=""
commit=""

usage() {
  print -u2 "Usage: $0 [--version MAJOR.MINOR.PATCH] [--commit COMMIT]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --version)
      (( $# >= 2 )) || usage
      version="$2"
      shift 2
      ;;
    --commit)
      (( $# >= 2 )) || usage
      commit="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$version" ]]; then
  settings="$(xcodebuild \
    -project "$project_dir/PGCloner.xcodeproj" \
    -scheme PGClonerApp \
    -configuration Release \
    -showBuildSettings)"
  versions=("${(@f)$(print -r -- "$settings" | sed -n -E 's/^[[:space:]]*MARKETING_VERSION = //p' | sort -u)}")
  (( ${#versions[@]} == 1 )) || {
    print -u2 "Expected one Release MARKETING_VERSION, found ${#versions[@]}"
    exit 1
  }
  version="${versions[1]}"
fi

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "MARKETING_VERSION must use MAJOR.MINOR.PATCH, got: $version"
  exit 1
fi

if [[ -z "$commit" ]]; then
  commit="$(git rev-parse HEAD)"
else
  commit="$(git rev-parse "$commit^{commit}")"
fi

tag="v$version"
should_release=true
release_reason=new_version

if git show-ref --verify --quiet "refs/tags/$tag"; then
  tag_commit="$(git rev-list -n 1 "$tag")"
  if [[ "$tag_commit" == "$commit" ]]; then
    release_reason=resume_existing_tag
  elif git merge-base --is-ancestor "$tag_commit" "$commit"; then
    should_release=false
    release_reason=already_released
  else
    print -u2 "Release tag $tag does not point to an ancestor of $commit"
    exit 1
  fi
fi

print "version=$version"
print "tag=$tag"
print "should_release=$should_release"
print "release_reason=$release_reason"
