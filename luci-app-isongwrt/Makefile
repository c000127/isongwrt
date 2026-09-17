include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-isongwrt
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=c000127

LUCI_TITLE:=LuCI app for isongwrt — sing-box core manager & config panel
LUCI_DESCRIPTION:=Install and switch sing-box cores (stable/rc/beta/alpha), upload and validate \
	configurations, control the service, view logs, and serve the official sing-box dashboard.
LUCI_DEPENDS:=+luci-base +curl +ca-bundle
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
