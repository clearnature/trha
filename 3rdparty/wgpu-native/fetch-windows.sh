#!/bin/sh
# 获取 wgpu-native 的 Windows GNU/MinGW 版（预编译二进制，不入库）。
#
# 为什么要有这个脚本：libwgpu_native.a 有 36 MB，把它提交进 git 会让仓库
# 变成「源码 + 二进制」混合体，clone 变慢、diff 失效。二进制应当由构建步骤
# 获取，而不是版本控制分发。
#
# 用法：sh 3rdparty/wgpu-native/fetch-windows.sh
set -e
VER=v29.0.1.1
URL="https://github.com/gfx-rs/wgpu-native/releases/download/$VER/wgpu-windows-x86_64-gnu-release.zip"
DST="$(dirname "$0")/lib/windows"

mkdir -p "$DST"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading $URL"
curl -sSL -o "$tmp/wgpu.zip" "$URL"
unzip -o -q "$tmp/wgpu.zip" -d "$tmp/x"
cp "$tmp/x/lib/libwgpu_native.a"     "$DST/"
# 不复制 libwgpu_native.dll.a：它会让链接器优先选动态库，导致 exe 运行时
# 找不到 wgpu_native.dll 而静默崩溃（无任何输出）。只留静态库，exe 自包含。
cp "$tmp/x/lib/wgpu_native.dll"      "$DST/"
echo "wgpu-native $VER -> $DST"
