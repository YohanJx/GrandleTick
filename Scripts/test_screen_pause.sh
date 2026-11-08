#!/bin/zsh
set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly TEST_DIRECTORY="$(mktemp -d /private/tmp/GrandleTickScreenPauseTests.XXXXXX)"
trap 'rm -rf "${TEST_DIRECTORY}"' EXIT

# 1. 使用生产源码与内存数据库测试入口，避免另写一份简化计时器掩盖实际回归。
sources=()
for source_file in "${PROJECT_ROOT}"/GrandleTick/*.swift; do
    if [[ "${source_file:t}" != "GrandleTickApp.swift" ]]; then
        sources+=("${source_file}")
    fi
done
xcrun swiftc -module-cache-path "${TEST_DIRECTORY}/ModuleCache" \
    -o "${TEST_DIRECTORY}/screen-pause-tests" \
    "${sources[@]}" "${PROJECT_ROOT}/Scripts/test_screen_pause.swift"

# 2. 通知仅投递到本测试进程，不会真的关闭显示器或修改用户历史数据库。
"${TEST_DIRECTORY}/screen-pause-tests"
