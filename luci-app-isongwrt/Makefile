include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-isongwrt
PKG_VERSION:=0.2.0
PKG_RELEASE:=3
# 注意：每次改动代码/脚本后必须递增 PKG_RELEASE（或 PKG_VERSION），
# 否则 apk/opkg 认为版本未变、不会替换已安装文件（用户升级不到新代码）。

PKG_LICENSE:=MIT
PKG_MAINTAINER:=c000127
# luci.mk writes the package control metadata from the LUCI_* variables; without
# them the ipk/apk keeps the upstream defaults (OpenWrt LuCI community /
# github.com/openwrt/luci), so they must be set explicitly.
LUCI_MAINTAINER:=c000127
LUCI_URL:=https://github.com/c000127/isongwrt

LUCI_TITLE:=LuCI app for isongwrt — sing-box core manager & config panel
LUCI_DESCRIPTION:=Install and switch sing-box cores (stable/rc/beta/alpha), upload and validate \
	configurations, control the service, view logs, and serve the official sing-box dashboard.
LUCI_DEPENDS:=+luci-base +ca-bundle
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
