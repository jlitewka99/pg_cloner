#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
developer_dir=$(xcode-select -p 2>/dev/null || true)
release_version=${RELEASE_VERSION:-}

if [[ -n "$release_version" && -z ${RELEASE_BUILD:-} ]]; then
  export RELEASE_BUILD="$release_version"
fi

if [[ "$developer_dir" == *CommandLineTools* ]]; then
  print "Full Xcode is not selected; using the SwiftPM compatibility builder."
  "$project_dir/scripts/build_release_swiftpm.sh"
elif ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  print -u2 "Xcode setup is incomplete or its required components cannot be loaded."
  print -u2 "To repair Xcode later, run: sudo xcodebuild -runFirstLaunch"
  print "Using the SwiftPM compatibility builder for this release."
  "$project_dir/scripts/build_release_swiftpm.sh"
else
  "$project_dir/scripts/build_release.sh"
fi
"$project_dir/scripts/create_dmg.sh"
if [[ -n "$release_version" ]]; then
  "$project_dir/scripts/create_update_zip.sh"
else
  print "Set RELEASE_VERSION=MAJOR.MINOR.PATCH to also create a Sparkle update ZIP."
fi
