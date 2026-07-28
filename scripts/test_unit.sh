#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
sdk_path=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}

cd "$project_dir"
zsh "$project_dir/scripts/test_release_metadata.sh"

env \
  SDKROOT="$sdk_path" \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/pg-cloner-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/pg-cloner-clang-cache \
  swift test \
    --disable-sandbox \
    --sdk "$sdk_path" \
    --enable-swift-testing \
    --disable-xctest
