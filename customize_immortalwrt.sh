#!/bin/bash
#=================================================
# 原始：Copyright (c) 2019-2023 sky2016cn / MIT
# 本版：修正版（覆盖仓库根目录的 customize_immortalwrt.sh）
#
# 相对原版的改动：
#   1) 【关键】把 base feed 的 xray-core 从 26.3.27 提到 26.10.10，并加断言。
#      原因：immortalwrt/packages@openwrt-25.12 的 xray-core 是 26.3.27，
#            而 immortalwrt/luci@openwrt-25.12 的 luci-app-passwall 是 26.10.16，
#            后者生成的 global.json 带 "version":{"min":"26.7.11"}，
#            旧核心会以
#              Failed to start: ... this config must be run on version 26.7.11 or higher
#            拒绝启动 → 基本设置里 TCP/UDP/DNS 全部「未运行」。
#      注意：这里必须改 feeds/packages 里那份，因为 feeds install -a 按 feeds.conf
#            顺序安装，base 的 xray-core 先占位，xiaorouji 的同名包会被静默跳过。
#   2) .config 强制段里的符号名修正（dnsmasq_full / INCLUDE_SingBox）。
#   3) 统一的错误退出（set -e），避免某步失败后继续跑到 make defconfig 才炸。
#=================================================

set -e

OPENWRT_DIR=/builder/openwrt

#1. 修改默认 IP
sed -i 's/192.168.1.1/192.168.16.1/g' $OPENWRT_DIR/package/base-files/files/bin/config_generate

#2. 修改默认主机名
sed -i 's/ImmortalWrt/RedmiWrt/g' $OPENWRT_DIR/package/base-files/files/bin/config_generate

#3. 首次开机自动配置 WiFi（uci-defaults，编译时打进固件）
mkdir -p $OPENWRT_DIR/files/etc/uci-defaults

cat > $OPENWRT_DIR/files/etc/uci-defaults/99-set-default-wifi-ip <<'EOF'
#!/bin/sh

# 2.4G radio0
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country='CN'
uci set wireless.default_radio0.ssid='Redmi-2.4G'
uci set wireless.default_radio0.encryption='psk2+ccmp'
uci set wireless.default_radio0.key='qwer1234'

# 5G radio1
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country='CN'
uci set wireless.default_radio1.ssid='Redmi-5G'
uci set wireless.default_radio1.encryption='psk2+ccmp'
uci set wireless.default_radio1.key='qwer1234'

uci commit wireless
exit 0
EOF

chmod +x $OPENWRT_DIR/files/etc/uci-defaults/99-set-default-wifi-ip

#4. 追加 PassWall / MosDNS 的 feed（补 base 里缺的依赖包）
grep -q 'passwall_packages' $OPENWRT_DIR/feeds.conf.default || \
    echo "src-git passwall_packages https://github.com/xiaorouji/openwrt-passwall-packages.git;main" >> $OPENWRT_DIR/feeds.conf.default
grep -q 'passwall_luci' $OPENWRT_DIR/feeds.conf.default || \
    echo "src-git passwall_luci https://github.com/xiaorouji/openwrt-passwall.git;main" >> $OPENWRT_DIR/feeds.conf.default
grep -q 'mosdns' $OPENWRT_DIR/feeds.conf.default || \
    echo "src-git mosdns https://github.com/sbwml/luci-app-mosdns.git;v5" >> $OPENWRT_DIR/feeds.conf.default

cd $OPENWRT_DIR
./scripts/feeds update -a
./scripts/feeds install -a

#5. 【关键修复】xray-core 版本对齐（只对 25.12 分支做）
#   背景：
#     openwrt-25.12：passwall 26.10.16 + xray 26.3.27  → 插件要求 >=26.7.11，必崩
#     openwrt-24.10：passwall 25.12.16 + xray 25.2.21  → 这一对是自洽的，不要动它
#   而且在 24.10 上把 xray 提到 26.x 还可能因为 Go 版本不够而编不过，所以只对 25.12 生效。
BRANCH="$(git -C "$OPENWRT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo ">>> 上游分支: $BRANCH"

case "$BRANCH" in
    openwrt-25.12*|master|main)
        XRAY_MIN="${XRAY_MIN:-26.7.11}"
        XRAY_VER="${XRAY_VER:-26.10.10}"
        XRAY_HASH="${XRAY_HASH:-bc4b3fbe9f2612a7e8b7fffd4b7195f00ad4aa28478f3621fce925cb6190c036}"
        PATCH_XRAY=1
        ;;
    *)
        echo ">>> 非 25.12 分支，保持上游 xray-core 版本不动（这一对的版本是自洽的）"
        PATCH_XRAY=0
        ;;
esac

XRAY_MK=$OPENWRT_DIR/feeds/packages/net/xray-core/Makefile
if [ ! -f "$XRAY_MK" ]; then
    echo "FATAL: 找不到 $XRAY_MK"
    exit 1
fi

ver_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

if [ "$PATCH_XRAY" = "1" ]; then
    xray_old=$(sed -n 's/^PKG_VERSION:=//p' "$XRAY_MK" | head -n1)
    if [ "$xray_old" != "$XRAY_VER" ]; then
        echo ">>> xray-core: $xray_old -> $XRAY_VER"
        sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$XRAY_VER/" "$XRAY_MK"
        sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$XRAY_HASH/"       "$XRAY_MK"
    fi

    xray_now=$(sed -n 's/^PKG_VERSION:=//p' "$XRAY_MK" | head -n1)
    if ! ver_ge "${xray_now:-0}" "$XRAY_MIN"; then
        echo "FATAL: xray-core $xray_now < $XRAY_MIN，PassWall 会拒绝启动。"
        echo "       请更新 XRAY_VER / XRAY_HASH 后重试。"
        exit 1
    fi
fi

echo ">>> 关键包版本："
printf '    %-22s %s\n' "luci-app-passwall" "$(sed -n 's/^PKG_VERSION:=//p' $OPENWRT_DIR/feeds/luci/applications/luci-app-passwall/Makefile | head -n1)"
printf '    %-22s %s\n' "xray-core"         "$(sed -n 's/^PKG_VERSION:=//p' "$XRAY_MK" | head -n1)"

#6. 强制勾选（符号名已与 25.12/24.10 的 Kconfig 对齐；只保留 Xray 一条线）
cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y
CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y
CONFIG_PACKAGE_luci-app-mosdns=y
CONFIG_PACKAGE_v2ray-geodata=y
CONFIG_PACKAGE_xray-core=y
CONFIG_PACKAGE_dnsmasq_full=y
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server is not set
# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geoview is not set
# CONFIG_PACKAGE_sing-box is not set
EOF

#7. 最后应用配置
make defconfig

#8. 构建后再自检一次（defconfig 不会把 xray 版本改回去，这里只是留痕）
grep -E 'CONFIG_PACKAGE_(xray-core|luci-app-passwall|dnsmasq_full)=y' .config || {
    echo "WARNING: 上面的配置项没有全部落到 .config，请检查包名是否存在于 feeds"
}
