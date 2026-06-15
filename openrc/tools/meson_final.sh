#!/bin/sh

set -e

rc_libexecdir="$1"
os="$2"

if [ "${os}" != linux ]; then
	install -d "${DESTDIR}/${rc_libexecdir}"/init.d
fi
# MESON_BUILDDIR (meson >=1.5) replaces MESON_BUILD_ROOT (meson <1.5)
BUILDDIR="${MESON_BUILDDIR:-${MESON_BUILD_ROOT:-}}"
install -m 644 "${BUILDDIR}/src/shared/version" "${DESTDIR}/${rc_libexecdir}"
