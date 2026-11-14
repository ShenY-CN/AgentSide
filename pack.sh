#!/usr/bin/env bash
# 打包 agent-sidebar 插件，产出可被 `tern plugin install` 直接使用的目录。
#
#   bash pack.sh [OUT_DIR]
#
# 产物:
#   OUT_DIR/agent-sidebar/            干净的可安装包(plugin.toml + window.luau
#                                     + styles.css + README.md)
#   OUT_DIR/agent-sidebar.tar.gz      同内容的压缩包(便于分发/上传)
#
# `tern plugin install` 接受本地目录或 git URL;本脚本产出前者。
# 若要以 git URL 分发,把 OUT_DIR/agent-sidebar 推到一个 git remote 即可。
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:-"$HERE/dist"}
PKG="$OUT/agent-sidebar"
TGZ="$OUT/agent-sidebar.tar.gz"

# 运行必需的插件文件(verify/、.git、开发产物不进包)。
FILES=(plugin.toml window.luau styles.css README.md)

rm -rf "$PKG"
mkdir -p "$PKG"

for f in "${FILES[@]}"; do
	if [ ! -f "$HERE/$f" ]; then
		printf 'pack: missing required file %s\n' "$HERE/$f" >&2
		exit 1
	fi
	cp "$HERE/$f" "$PKG/$f"
done

# 压缩包:以 agent-sidebar/ 为根,解开即是包目录;COPYFILE_DISABLE 去掉 macOS
# 的 ._ AppleDouble 垃圾文件。
rm -f "$TGZ"
COPYFILE_DISABLE=1 tar -C "$OUT" -czf "$TGZ" agent-sidebar

printf 'packed %s\n' "$PKG"
printf '       %s\n' "$TGZ"
printf '\ninstall with:\n'
printf '  tern plugin install %s\n' "$PKG"
printf '  (add --force to replace an installed copy)\n'
