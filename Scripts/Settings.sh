#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +
#修改默认主题
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
#修改immortalwrt.lan关联IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +
#添加编译日期标识
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} +

#修改默认WIFI账号密码
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
ROUTER_TOOL="./package/emortal/luci-app-router-tool/root/etc/config/router-tool"
for file in "$ROUTER_TOOL" "$WIFI_UC"; do
	[ -f "$file" ] && sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$file"
done

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE


#添加自定义 APK 软件源
APK_CUSTOM_FEEDS="./package/system/apk/files/customfeeds.list"
if [ -f "$APK_CUSTOM_FEEDS" ]; then
	cat > "$APK_CUSTOM_FEEDS" <<'EOF'
# add your custom package feeds here
#
# http://www.example.com/path/to/files/packages.adb
https://nikkinikki.pages.dev/SNAPSHOT/aarch64_cortex-a53/nikki/packages.adb
https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_cortex-a53/packages.adb
EOF
fi

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi


#无 WIFI 固件隐藏 LuCI「网络 -> 无线」菜单
if [[ "$WRT_WIFI" == "WIFI-NO" ]]; then
	LUCI_NETWORK_MENU="./feeds/luci/modules/luci-mod-network/root/usr/share/luci/menu.d/luci-mod-network.json"
	if [ -f "$LUCI_NETWORK_MENU" ]; then
		python3 - "$LUCI_NETWORK_MENU" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

data.pop("admin/network/wireless", None)

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
		echo "LuCI wireless menu hidden for WIFI-NO build."
	fi
fi

#高通平台调整
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	# WIFI-NO 只通过 .config 禁用无线驱动/固件。
	# 不再批量改写 DTS/DTSI：RE-SS-01 的 QCA8075 以太网拓扑依赖设备树，
	# 全局替换 SoC dtsi 风险过大，可能导致 LAN/WAN 不工作。
	if [[ "$WRT_WIFI" == "WIFI-NO" ]]; then
		echo "qualcommax WIFI-NO: keep original DTS/DTSI; disable WiFi by package config only."
	fi

	# JDCloud RE-SS-01 是 eMMC 设备。上游当前设备定义只产 sysupgrade，
	# 这里按设备块定向补齐 EmmcImage + factory.bin，避免影响其他机型。
	if [[ "${WRT_CONFIG^^}" == "IPQ60XX-WIFI-NO" ]]; then
		IMAGE_MK="./target/linux/qualcommax/image/ipq60xx.mk"
		python3 - "$IMAGE_MK" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = f.read()

pattern = r"(define Device/jdcloud_re-ss-01\n)(.*?)(\nendef)"
m = re.search(pattern, data, flags=re.S)
if not m:
    raise SystemExit("ERROR: Device/jdcloud_re-ss-01 block not found")

body = m.group(2)

if "$(call Device/EmmcImage)" not in body:
    anchor = "\t$(call Device/FitImage)"
    if anchor not in body:
        raise SystemExit("ERROR: RE-SS-01 FitImage anchor not found")
    body = body.replace(anchor, anchor + "\n\t$(call Device/EmmcImage)", 1)

factory = "\tIMAGE/factory.bin := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | append-metadata"
if "IMAGE/factory.bin :=" not in body:
    body = body.rstrip() + "\n" + factory

new_block = m.group(1) + body + m.group(3)
data = data[:m.start()] + new_block + data[m.end():]

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

		RE_SS_BLOCK="$(sed -n '/^define Device\/jdcloud_re-ss-01$/,/^endef$/p' "$IMAGE_MK")"
		grep -q '\$(call Device/EmmcImage)' <<< "$RE_SS_BLOCK" || {
			echo "ERROR: RE-SS-01 EmmcImage patch missing" >&2
			exit 1
		}
		grep -q 'IMAGE/factory.bin := append-kernel | pad-to \$$(KERNEL_SIZE) | append-rootfs | append-metadata' <<< "$RE_SS_BLOCK" || {
			echo "ERROR: RE-SS-01 factory.bin patch missing" >&2
			exit 1
		}
		echo "RE-SS-01 image definition: sysupgrade + factory enabled."
	fi
fi
