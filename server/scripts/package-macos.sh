#!/usr/bin/env bash
# 打包 macOS 桌面应用：同时支持 Apple Silicon 与 Intel 的 PocketDesk.app，并压缩为 zip。
#   用法：scripts/package-macos.sh [版本号] [输出目录]
#   默认版本号 1.0.0，输出到 server/dist/
# 双击 PocketDesk.app 打开管理窗口，服务未运行时自动在后台启动；命令行仍可用
#   PocketDesk.app/Contents/MacOS/pocketdesk <命令>
set -Eeuo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
OUT="${2:-dist}"
APP="$OUT/PocketDesk.app"
export CGO_ENABLED=1 CGO_CXXFLAGS="-Wno-deprecated-literal-operator"
LDFLAGS="-s -w -X main.version=$VERSION"

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 两种架构分别编译，再合成通用二进制
GOARCH=arm64 CC="clang -arch arm64" go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/pocketdesk-arm64" ./cmd/pocketdesk
GOARCH=amd64 CC="clang -arch x86_64" go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/pocketdesk-amd64" ./cmd/pocketdesk
lipo -create -output "$APP/Contents/MacOS/pocketdesk" "$OUT/pocketdesk-arm64" "$OUT/pocketdesk-amd64"
rm -f "$OUT/pocketdesk-arm64" "$OUT/pocketdesk-amd64"
sed "s/__VERSION__/$VERSION/g" packaging/macos/Info.plist > "$APP/Contents/Info.plist"
cp packaging/macos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 本机临时签名，未经公证；首次打开需在「系统设置 → 隐私与安全性」中点「仍要打开」
codesign --force --deep -s - "$APP"
(cd "$OUT" && rm -f "PocketDesk-$VERSION-macos.zip" && ditto -c -k --keepParent PocketDesk.app "PocketDesk-$VERSION-macos.zip")
printf '已生成 %s（%s）\n' "$OUT/PocketDesk-$VERSION-macos.zip" "$(du -h "$OUT/PocketDesk-$VERSION-macos.zip" | cut -f1)"
