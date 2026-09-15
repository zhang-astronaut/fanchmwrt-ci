# Copyright (C) 2026 FanchmWrt CI
# Conntrack-based user_sessiond (UA3F TPROXY compatible)

include $(TOPDIR)/rules.mk

PKG_NAME:=user-sessiond-ct
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
include $(INCLUDE_DIR)/package.mk

define Package/user-sessiond-ct
  SECTION:=net
  CATEGORY:=Network
  TITLE:=User session stats via conntrack (TPROXY-safe)
  DEPENDS:=+libubox +libubus +libblobmsg-json
endef

define Package/user-sessiond-ct/description
  Replacement for FanchmWrt UserSession user_sessiond.
  Aggregates per-MAC session counts from /proc/net/nf_conntrack + ARP
  so LuCI user session stats work when UA3F TPROXY bypasses fwx_user.ko.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -Wall \
		-o $(PKG_BUILD_DIR)/user_sessiond \
		$(PKG_BUILD_DIR)/user_sessiond.c \
		$(TARGET_LDFLAGS) -lubox -lubus -lblobmsg-json
endef

define Package/user-sessiond-ct/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/user_sessiond $(1)/usr/bin/user-sessiond-ct
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/user-sessiond-ct.init $(1)/etc/init.d/user-sessiond-ct
endef

$(eval $(call BuildPackage,user-sessiond-ct))
