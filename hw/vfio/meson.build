# SPDX-License-Identifier: GPL-2.0-or-later

vfio_ss = ss.source_set()
vfio_ss.add(files(
  'listener.c',
  'container.c',
  'helpers.c',
))
vfio_ss.add(when: 'CONFIG_LINUX', if_true: files('container-legacy.c'))
vfio_ss.add(when: 'CONFIG_KVM', if_true: files(
  'kvm-helpers.c',
  'container-legacy.c'
))
stub_ss.add(files('kvm-stubs.c'))
vfio_ss.add(when: 'CONFIG_PSERIES', if_true: files('spapr.c'))
vfio_ss.add(when: ['CONFIG_KVM', 'CONFIG_PSERIES'], if_true: files('kvm-spapr.c'))
vfio_ss.add(when: 'CONFIG_VFIO_PCI', if_true: files(
  'pci-quirks.c',
  'pci.c',
))
vfio_ss.add(when: 'CONFIG_VFIO_CCW', if_true: files('ccw.c'))
vfio_ss.add(when: 'CONFIG_VFIO_AP', if_true: files('ap.c'))
vfio_ss.add(when: 'CONFIG_VFIO_IGD', if_true: files('igd.c'))
stub_ss.add(files('igd-stubs.c'))

system_ss.add_all(when: 'CONFIG_VFIO', if_true: vfio_ss)

system_ss.add(when: 'CONFIG_VFIO', if_true: files(
  'cpr.c',
  'cpr-legacy.c',
  'device.c',
  'migration.c',
  'migration-multifd.c',
  'region.c',
))
system_ss.add(when: ['CONFIG_VFIO', 'CONFIG_IOMMUFD'], if_true: files(
  'iommufd.c',
  'cpr-iommufd.c',
))
stub_ss.add(files('iommufd-stubs.c'))
system_ss.add(when: 'CONFIG_VFIO_PCI', if_true: files(
  'display.c',
))

# Apple VFIO backend
if host_os == 'darwin'
  system_ss.add(when: 'CONFIG_VFIO',
                if_true: [files('apple-device.c', 'apple-dma.c',
                                'container-apple.c', 'apple-dext-client.c'),
                          coref, iokit])
  # FDT helper lives in specific_ss because libfdt is only linked into
  # targets that set CONFIG_DEVICE_TREE; system_ss is compiled once and
  # shared across all softmmu targets. The only caller is hw/arm/virt.c,
  # so gate on CONFIG_ARM_VIRT to avoid compiling it into other targets.
  specific_ss.add(when: ['CONFIG_VFIO', 'CONFIG_ARM_VIRT'],
                  if_true: files('apple-fdt.c'))
endif
