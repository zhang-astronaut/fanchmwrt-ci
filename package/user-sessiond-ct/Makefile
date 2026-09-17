# Copyright (C) 2026 FanchmWrt CI
# Conntrack + af_active_app user_sessiond (UA3F TPROXY compatible)

include $(TOPDIR)/rules.mk

PKG_NAME:=user-sessiond-ct
PKG_VERSION:=1.3.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
include $(INCLUDE_DIR)/package.mk

define Package/user-sessiond-ct
  SECTION:=net
  CATEGORY:=Network
  TITLE:=User session stats via conntrack+app (TPROXY-safe)
  URL:=https://github.com/zhang-astronaut/fanchmwrt-ci
  DEPENDS:=+libubox +libubus +lua
endef

define Package/user-sessiond-ct/description
  Replacement for FanchmWrt UserSession user_sessiond.
  Per-MAC sessions from nf_conntrack+ARP; background Lua sampler keeps
  history warm without LuCI open; user list labels use dhcp.leases names.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -Wall \
		-I$(STAGING_DIR)/usr/include \
		-o $(PKG_BUILD_DIR)/user_sessiond \
		$(PKG_BUILD_DIR)/user_sessiond.c \
		-L$(STAGING_DIR)/usr/lib \
		$(TARGET_LDFLAGS) -lubox -lubus
endef

define Package/user-sessiond-ct/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/user_sessiond $(1)/usr/bin/user-sessiond-ct
	$(INSTALL_DATA) ./files/user-session-sampler.lua $(1)/usr/bin/user-session-sampler.lua
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/user-sessiond-ct.init $(1)/etc/init.d/user-sessiond-ct
	$(INSTALL_BIN) ./files/user-session-sampler.init $(1)/etc/init.d/user-session-sampler
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/fwx_user_session.lua $(1)/usr/lib/lua/luci/controller/fwx_user_session.lua
endef

$(eval $(call BuildPackage,user-sessiond-ct))
