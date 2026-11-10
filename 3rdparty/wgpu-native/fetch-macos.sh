#!/bin/sh
# 获取 wgpu-native 的 macOS arm64 版（预编译二进制，不入库）。
#
# 为什么要有这个脚本：与 fetch-windows.sh 同理——libwgpu_native.dylib 不入库，
# 由构建步骤获取。macOS 上 wgpu 走 Metal 后端（wgpu 上游在 macOS/iOS 的一等
# 支持），C ABI 与 Linux/Windows 一致，trha 的 Haskell FFI 零改动。
#
# 用法：sh 3rdparty/wgpu-native/fetch-macos.sh
set -e
VER=v29.0.1.1
URL="https://github.com/gfx-rs/wgpu-native/releases/download/$VER/wgpu-macos-aarch64-release.zip"
DST="$(dirname "$0")/lib"

mkdir -p "$DST"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading $URL"
curl -sSL -o "$tmp/wgpu.zip" "$URL"
unzip -o -q "$tmp/wgpu.zip" -d "$tmp/x"
cp "$tmp/x/lib/libwgpu_native.dylib" "$DST/"
echo "wgpu-native $VER -> $DST/libwgpu_native.dylib"
