# SPDX-License-Identifier: GPL-2.0-only
#
# Chelsio T1/T3/T4/T5/T6 (T520 etc.) kernel drivers for FanchmWrt x86_64.
# OpenWrt upstream does not ship these as kmod packages on current trees.

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

NETWORK_DEVICES_MENU:=$(call qstrip,$(CONFIG_KERNEL_MENU))

define KernelPackage/libcxgb
  SUBMENU:=Network Devices
  TITLE:=Chelsio common library (cxgb)
  DEPENDS:=@PCI_SUPPORT
  KCONFIG:=CONFIG_CHELSIO_LIB
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/chelsio/libcxgb/libcxgb.ko
  AUTOLOAD:=$(call AutoLoad,31,libcxgb)
endef

define KernelPackage/libcxgb/description
  Shared library for Chelsio T3/T4/T5/T6 adapters (T520/T6225 etc.).
endef

define KernelPackage/cxgb
  SUBMENU:=Network Devices
  TITLE:=Chelsio T1 10GbE support
  DEPENDS:=@PCI_SUPPORT +kmod-libcxgb
  KCONFIG:=CONFIG_CHELSIO_T1
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/chelsio/cxgb/cxgb.ko
  AUTOLOAD:=$(call AutoLoad,32,cxgb)
endef

define KernelPackage/cxgb/description
  Driver for Chelsio T1 10Gb Ethernet adapters.
endef

define KernelPackage/cxgb3
  SUBMENU:=Network Devices
  TITLE:=Chelsio T3 10GbE support
  DEPENDS:=@PCI_SUPPORT +kmod-libcxgb
  KCONFIG:=CONFIG_CHELSIO_T3
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/chelsio/cxgb3/cxgb3.ko
  AUTOLOAD:=$(call AutoLoad,32,cxgb3)
endef

define KernelPackage/cxgb3/description
  Driver for Chelsio T3 10Gb Ethernet adapters.
endef

define KernelPackage/cxgb4
  SUBMENU:=Network Devices
  TITLE:=Chelsio T4/T5/T6 10/25/40/100GbE support
  DEPENDS:=@PCI_SUPPORT +kmod-libcxgb
  KCONFIG:= \
    CONFIG_CHELSIO_T4 \
    CONFIG_CHELSIO_T4VF=n
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/chelsio/cxgb4/cxgb4.ko
  AUTOLOAD:=$(call AutoLoad,33,cxgb4)
endef

define KernelPackage/cxgb4/description
  Driver for Chelsio T4/T5/T6 (e.g. T520-CR, T6225) 10/25/40/100Gb Ethernet.
endef

$(eval $(call KernelPackage,libcxgb))
$(eval $(call KernelPackage,cxgb))
$(eval $(call KernelPackage,cxgb3))
$(eval $(call KernelPackage,cxgb4))
