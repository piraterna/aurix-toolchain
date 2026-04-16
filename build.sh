#!/usr/bin/env bash

set -eo pipefail
shopt -s inherit_errexit

cd "$(dirname "$(readlink -f "$0")")"

report_error() {
	printf "\n[!] Error $? on line $(caller), exitting.\n" >&2
	exit 1
}

trap report_error ERR

if [ -v $ARCH ]; then
	printf "[*] ARCH is not set, defaulting to 'x86_64'.\n"
	ARCH=x86_64
fi

rootdir="$(pwd)"
patch_dir="${rootdir}/patches"
sysroot_dir="${rootdir}/sysroot"
toolchain_dir="${rootdir}/toolchain"

gnu_mirror="https://ftp.gnu.org/gnu"
target_triplet="${ARCH}-aurix"

###
# GNU Binutils
##

binutils_ver="2.46.0"
binutils_patch="${patch_dir}/binutils-${binutils_ver}.patch"
binutils_archive="binutils-${binutils_ver}.tar.xz"
binutils_url="${gnu_mirror}/binutils/${binutils_archive}"
binutils_dir="binutils-${binutils_ver}"

###
# GNU GCC
##

gcc_ver="15.2.0"
gcc_patch="${patch_dir}/gcc-${gcc_ver}.patch"
gcc_archive="gcc-${gcc_ver}.tar.xz"
gcc_url="${gnu_mirror}/gcc/gcc-${gcc_ver}/${gcc_archive}"
gcc_dir="gcc-${gcc_ver}"

###
# mlibc
##

mlibc_repo="https://github.com/piraterna/aurix-mlibc.git"

mlibc_cflags=""
mlibc_cxxflags=""
mlibc_ldflags=""

###
# Helper functions
##

download_if_missing() {
	local name="$1"
	local url="$2"
	local archive="$3"

	printf "[ ] Downloading \"$name\"..."

	if [ -f "${archive}" ]; then
		printf " skipped (already downloaded)\n"
	else
		chronic wget -O "$archive" "$url"
		printf " done.\n"
	fi
}

extract_if_missing() {
	local name="$1"
	local archive="$2"
	local dir="$3"

	printf "[ ] Extracting \"$name\"..."

	if [ -d "${dir}" ]; then
		printf " skipped (already extracted)\n"
	else
		chronic tar -xf "$archive"
		printf " done.\n"
	fi
}

patch_if_needed() {
	local name="$1"
	local root="$2"
    local patch_file="$3"
    local stamp_file="$4"

	printf "[ ] Patching \"$name\"..."

    if [ ! -f "$patch_file" ]; then
        printf "failed. (file \"${patch_file}\" not found)" >&2
        exit 1
    fi

    if [ -f "$root/$stamp_file" ]; then
        echo "skipped. (patch already applied)\n"
        return
    fi

    chronic patch -d "$root" -p1 < "$patch_file"
    touch "$root/$stamp_file"
	printf " done.\n"
}

###
# Setup
##

download_if_missing "Binutils" "${binutils_url}" "${binutils_archive}"
download_if_missing "GCC" "${gcc_url}" "${gcc_archive}"

printf "[ ] Downloading mlibc..."
if [ ! -d mlibc ]; then
	chronic git clone "${mlibc_repo}" mlibc --depth=1
	printf "done.\n"
else
	printf " skipped. (already exists)\n"
fi

extract_if_missing "Binutils" "${binutils_archive}" "${binutils_dir}"
extract_if_missing "GCC" "${gcc_archive}" "${gcc_dir}"

patch_if_needed "Binutils" "${binutils_dir}" "$binutils_patch" ".patch-binutils"
patch_if_needed "GCC" "${gcc_dir}" "$gcc_patch" ".patch-gcc"

# Download prerequisites for GCC
printf "[ ] Downloading GCC pre-requisites..."
pushd "${gcc_dir}" >/dev/null
chronic ./contrib/download_prerequisites
popd >/dev/null
printf " done.\n"

chronic mkdir -p "${sysroot_dir}" "${toolchain_dir}"

###
# mlibc headers
##

printf "[ ] Building mlibc headers..."

pushd mlibc >/dev/null

if [ ! -d headers-build ]; then
	chronic meson setup \
				--cross-file=${rootdir}/aurix-cross_${ARCH}.txt \
				--prefix=/usr \
				-Dheaders_only=true \
				headers-build
	printf " done.\n"
else
	printf " skipped (already built)\n"
fi

printf "[ ] Installing mlibc headers..."

if [ -f "${sysroot_dir}/usr/include/stdlib.h" ] || [ -d "${sysroot_dir}/usr/include/mlibc" ]; then
	printf " skipped (already installed)\n"
else
	DESTDIR="${sysroot_dir}" chronic ninja -C headers-build install
	printf " done.\n"
fi

popd >/dev/null

###
# Binutils
##

pushd "$binutils_dir" >/dev/null

mkdir -p build
pushd build >/dev/null

printf "[ ] Configuring binutils..."
if [ ! -f Makefile ]; then
	chronic ../configure \
				--target="$target_triplet" \
				--prefix=/usr \
				--with-sysroot="$sysroot_dir" \
				--disable-werror \
				--enable-default-execstack=no
	printf " done.\n"
else
	printf " skipped. (already configured)\n"
fi

printf "[ ] Building binutils..."
chronic make -j"$(nproc --ignore=2)"
printf " done.\n"

printf "[ ] Installing binutils..."
if [ ! -x "${toolchain_dir}/usr/bin/${target_triplet}-ld" ] || [ ! -x "${toolchain_dir}/usr/bin/${target_triplet}-as" ]; then
	DESTDIR="$toolchain_dir" chronic make install
	printf " done.\n"
else
	printf " skipped. (already installed)\n"
fi

popd >/dev/null
popd >/dev/null

###
# GCC
##

pushd "$gcc_dir" >/dev/null

mkdir -p build
pushd build >/dev/null

OLD_PATH=$PATH
export PATH=$OLD_PATH:${toolchain_dir}/usr/bin

printf "[ ] Configuring GCC..."
if [ ! -f Makefile ]; then
	chronic ../configure \
				--target="$target_triplet" \
				--prefix=/usr \
				--with-sysroot="$sysroot_dir" \
				--enable-languages=c,c++ \
				--enable-threads=posix \
				--disable-multilib \
				--enable-shared \
				--enable-host-shared \
				--with-pic
	printf " done.\n"
else
	printf " skipped. (already configured)\n"
fi

printf "[ ] Building GCC..."
chronic make -j"$(nproc --ignore=2)" all-gcc all-target-libgcc
printf " done.\n"

printf "[ ] Installing GCC..."
if [ ! -x "${toolchain_dir}/usr/bin/${target_triplet}-gcc" ] || [ ! -x "${toolchain_dir}/usr/lib/gcc/${gcc_ver}/libgcc.a" ]; then
	DESTDIR="$toolchain_dir" chronic make install-gcc install-target-libgcc
	printf " done.\n"
else
	printf " skipped. (already installed)\n"
fi

popd >/dev/null
popd >/dev/null

export PATH=$OLD_PATH

###
# Cleanup
##

printf "[ ] Cleaning up..."
rm -rf ${binutils_dir}/build ${gcc_dir}/build

printf "\nDone. You should put '${sysroot_dir}/usr/bin' into your PATH.\n"