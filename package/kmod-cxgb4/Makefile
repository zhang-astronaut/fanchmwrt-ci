include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/cxgb4
  SUBMENU:=Network Devices
  TITLE:=Chelsio T4/T5/T6 10/25/40/100GbE (T520)
  DEPENDS:=@PCI_SUPPORT
  KCONFIG:=CONFIG_CHELSIO_T4
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/chelsio/cxgb4/cxgb4.ko
  AUTOLOAD:=$(call AutoLoad,33,cxgb4)
endef

define KernelPackage/cxgb4/description
  Driver for Chelsio T4/T5/T6 adapters such as T520-CR.
endef

$(eval $(call KernelPackage,cxgb4))
