#!/usr/bin/env bash
#
# 打包安卓安装包（按 CPU 架构拆分），产物放到 app/build/app/outputs/flutter-apk/
#
# 项目路径含中文时 Gradle 会失败，所以先把 app 同步到纯英文的临时目录打包，完成后拷回项目内的标准输出位置。
#
# 用法：scripts/build-apk.sh
# 环境变量：
#   PD_BUILD_DIR      临时打包目录，默认 ${TMPDIR}/pocketdesk-apk
#   GRADLE_USER_HOME  Gradle 缓存目录，默认 ~/.cache/pocketdesk-gradle（与原有缓存共用，避免重复下载）
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/app"
work="${PD_BUILD_DIR:-${TMPDIR:-/tmp}/pocketdesk-apk}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.cache/pocketdesk-gradle}"

# 1、同步源码到英文路径（保留上次的构建缓存）
mkdir -p "$work"
rsync -a --delete --exclude build --exclude .dart_tool --exclude android/.kotlin --exclude android/.gradle "$src/" "$work/app/"

# 2、打包；下载依赖偶尔被网络中断，失败时重试一次
cd "$work/app"
flutter build apk --release --split-per-abi || flutter build apk --release --split-per-abi

# 3、拷回项目内的标准输出位置
out="$src/build/app/outputs/flutter-apk"
mkdir -p "$out"
cp build/app/outputs/flutter-apk/*.apk "$out/"
echo
echo "安装包："
ls -lh "$out"/*.apk
