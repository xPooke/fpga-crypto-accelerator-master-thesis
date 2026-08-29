SUMMARY = "SHA3 Scatter-Gather DMA kernel module"
DESCRIPTION = "Custom kernel module for SHA-3 accelerator using AXI-DMA SG mode"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=12f884d2ae1ff87c09e5b7ccc2c4ca7e"

inherit module

SRC_URI = "file://dma-proxy-sha3.c \
	   file://dma-proxy-sha3.h \
           file://Makefile \
           file://COPYING \
"

S = "${WORKDIR}"

do_install() {
    # use base_libdir instead of /lib (on a usrmerge system that is /usr/lib)
    install -d ${D}${base_libdir}/modules/${KERNEL_VERSION}/extra
    install -m 0644 dma-proxy-sha3.ko ${D}${base_libdir}/modules/${KERNEL_VERSION}/extra/
}

FILES:${PN} = "${base_libdir}/modules/${KERNEL_VERSION}/extra/dma-proxy-sha3.ko"

