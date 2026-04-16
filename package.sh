#!/usr/bin/env bash

set -eo pipefail
shopt -s inherit_errexit

cd "$(dirname "$(readlink -f "$0")")"

rootdir="$(pwd)"
toolchain_dir="${rootdir}/toolchain"

tar cf aurix-toolchain.tar.xz ${toolchain_dir}
