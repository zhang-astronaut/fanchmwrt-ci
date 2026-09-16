# Copyright (C) 2026 FanchmWrt CI
# https://github.com/HofNature/SRunPy-OpenWRT

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-srunpy
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
include $(INCLUDE_DIR)/package.mk

define Package/luci-app-srunpy
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for SRunPy
  URL:=https://github.com/HofNature/SRunPy-OpenWRT
  DEPENDS:=+srunpy +luci-compat
  PKGARCH:=all
endef

define Package/luci-app-srunpy/description
  LuCI UI for SRunPy campus auto-login (boot start + reconnect).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	true
endef

define Package/luci-app-srunpy/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/srunpy.config $(1)/etc/config/srunpy
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/srunpy.init $(1)/etc/init.d/srunpy
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/controller-srunpy.lua $(1)/usr/lib/lua/luci/controller/srunpy.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./files/cbi-srunpy.lua $(1)/usr/lib/lua/luci/model/cbi/srunpy.lua
endef

$(eval $(call BuildPackage,luci-app-srunpy))
