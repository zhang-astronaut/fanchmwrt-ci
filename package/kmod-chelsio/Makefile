# SPDX-License-Identifier: GPL-2.0-only
#
# Chelsio T4/T5/T6 (T520-CR etc.) kernel driver for FanchmWrt x86_64.
# Only the T4/T5/T6 driver (cxgb4) is packaged. T1/T3 and optional DCB/FCoE/
# inline-crypto are pinned off so non-interactive kernel syncconfig cannot
# prompt on NEW symbols.

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/cxgb4
  SUBMENU:=Network Devices
  TITLE:=Chelsio T4/T5/T6 10/25/40/100GbE support
  DEPENDS:=@PCI_SUPPORT
  KCONFIG:= \
    CONFIG_NET_VENDOR_CHELSIO=y \
    CONFIG_CHELSIO_LIB \
    CONFIG_CHELSIO_T1=n \
    CONFIG_CHELSIO_T1_1G=n \
    CONFIG_CHELSIO_T3=n \
    CONFIG_CHELSIO_T4 \
    CONFIG_CHELSIO_T4_DCB=n \
    CONFIG_CHELSIO_T4_FCOE=n \
    CONFIG_CHELSIO_T4VF=n \
    CONFIG_CHELSIO_INLINE_CRYPTO=n \
    CONFIG_CHELSIO_IPSEC_INLINE=n \
    CONFIG_CHELSIO_TLS_DEVICE=n
  FILES:= \
    $(LINUX_DIR)/drivers/net/ethernet/chelsio/libcxgb/libcxgb.ko \
    $(LINUX_DIR)/drivers/net/ethernet/chelsio/cxgb4/cxgb4.ko
  AUTOLOAD:=$(call AutoLoad,33,cxgb4)
endef

define KernelPackage/cxgb4/description
  Driver for Chelsio T4/T5/T6 (e.g. T520-CR) 10/25/40/100Gb Ethernet.
  Includes libcxgb when the kernel builds it as a separate module.
endef

$(eval $(call KernelPackage,cxgb4))
