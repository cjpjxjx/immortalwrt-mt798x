#!/bin/bash
# One-click build script for CMCC RAX3000M NAND firmware.
set -e
cd "$(dirname "$0")"

DEFCONFIG="defconfig/mt7981-ax3000.config"
JOBS="$(nproc)"

echo "==> Updating feeds"
./scripts/feeds update -a
./scripts/feeds install -a

echo "==> Trimming luci-theme-argon login-page assets (not reachable via uci-defaults on manual builds, only truly dropped here)"
ARGON_DIR="feeds/luci/themes/luci-theme-argon"
rm -f \
	"$ARGON_DIR/luasrc/view/themes/argon/sysauth.htm" \
	"$ARGON_DIR/htdocs/luci-static/argon/img/bg1.jpg" \
	"$ARGON_DIR/root/usr/libexec/argon/online_wallpaper" \
	"$ARGON_DIR/htdocs/luci-static/argon/background/README.md"

echo "==> Clearing build state that can go stale after a feeds/defconfig change"
rm -rf tmp
rm -f .config.old

echo "==> Applying defconfig: $DEFCONFIG"
cp -f "$DEFCONFIG" .config
make defconfig

echo "==> Building firmware with -j${JOBS}"
make -j"${JOBS}" V=s || make -j1 V=s
