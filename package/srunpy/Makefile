# Copyright (C) 2026 FanchmWrt CI
# https://github.com/HofNature/SRunPy-OpenWRT

include $(TOPDIR)/rules.mk

PKG_NAME:=srunpy
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
include $(INCLUDE_DIR)/package.mk

define Package/srunpy
  SECTION:=net
  CATEGORY:=Network
  TITLE:=SRun campus gateway auto-login (CLI)
  URL:=https://github.com/HofNature/SRunPy-OpenWRT
  DEPENDS:=+python3-requests
  PKGARCH:=all
endef

define Package/srunpy/description
  Automatic login script for SRun (深澜) campus gateways.
  CLI entry: srunpy --host ... --username ...
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	true
endef

define Package/srunpy/install
	$(INSTALL_DIR) $(1)/lib/srunpy
	$(INSTALL_DATA) ./files/AutoLogin.py $(1)/lib/srunpy/
	$(INSTALL_DATA) ./files/SRunLite.py $(1)/lib/srunpy/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/srunpy.sh $(1)/usr/bin/srunpy
endef

$(eval $(call BuildPackage,srunpy))
