# SPDX-License-Identifier: GPL-2.0-only
#
# Chelsio T5/T6 (T520-CR etc.) kernel drivers for FanchmWrt x86_64.
# OpenWrt upstream does not ship these as kmod packages on current trees.
# Only T4/T5/T6 (cxgb4) is enabled — T1/T3 pull extra Kconfig prompts and
# are not needed for T520.

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/libcxgb
  SUBMENU:=Network Devices
  TITLE:=Chelsio common library (cxgb)
  DEPENDS:=@PCI_SUPPORT
  KCONFIG:=CONFIG_CHELSIO_LIB
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/chelsio/libcxgb/libcxgb.ko
  AUTOLOAD:=$(call AutoLoad,31,libcxgb)
endef

define KernelPackage/libcxgb/description
  Shared library for Chelsio T4/T5/T6 adapters (T520, T6225, ...).
endef

define KernelPackage/cxgb4
  SUBMENU:=Network Devices
  TITLE:=Chelsio T4/T5/T6 10/25/40/100GbE support
  DEPENDS:=@PCI_SUPPORT +kmod-libcxgb
  KCONFIG:= \
    CONFIG_CHELSIO_LIB \
    CONFIG_CHELSIO_T1=n \
    CONFIG_CHELSIO_T1_1G=n \
    CONFIG_CHELSIO_T3=n \
    CONFIG_CHELSIO_T4 \
    CONFIG_CHELSIO_T4VF=n
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/chelsio/cxgb4/cxgb4.ko
  AUTOLOAD:=$(call AutoLoad,33,cxgb4)
endef

define KernelPackage/cxgb4/description
  Driver for Chelsio T4/T5/T6 (e.g. T520-CR) 10/25/40/100Gb Ethernet.
endef

$(eval $(call KernelPackage,libcxgb))
$(eval $(call KernelPackage,cxgb4))
