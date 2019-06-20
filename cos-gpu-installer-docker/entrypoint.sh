#!/bin/bash
#
# Copyright 2017 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


set -o errexit
set -o pipefail
set -u

set -x
COS_DOWNLOAD_GCS="https://storage.googleapis.com/cos-tools"
COS_KERNEL_SRC_GIT="https://chromium.googlesource.com/chromiumos/third_party/kernel"
COS_KERNEL_SRC_ARCHIVE="kernel-src.tar.gz"
TOOLCHAIN_URL_FILENAME="toolchain_url"
TOOLCHAIN_ARCHIVE="toolchain.tar.xz"
TOOLCHAIN_ENV_FILENAME="toolchain_env"
TOOLCHAIN_PKG_DIR="${TOOLCHAIN_PKG_DIR:-/build/cos-tools}"
CHROMIUMOS_SDK_GCS="https://storage.googleapis.com/chromiumos-sdk"
ROOT_OS_RELEASE="${ROOT_OS_RELEASE:-/root/etc/os-release}"
KERNEL_SRC_DIR="${KERNEL_SRC_DIR:-/build/usr/src/linux}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-418.67}"
NVIDIA_DRIVER_MD5SUM="${NVIDIA_DRIVER_MD5SUM:-}"
NVIDIA_INSTALL_DIR_HOST="${NVIDIA_INSTALL_DIR_HOST:-/var/lib/nvidia}"
NVIDIA_INSTALL_DIR_CONTAINER="${NVIDIA_INSTALL_DIR_CONTAINER:-/usr/local/nvidia}"
ROOT_MOUNT_DIR="${ROOT_MOUNT_DIR:-/root}"
CACHE_FILE="${NVIDIA_INSTALL_DIR_CONTAINER}/.cache"
LOCK_FILE="${ROOT_MOUNT_DIR}/tmp/cos_gpu_installer_lock"
LOCK_FILE_FD=20
set +x

# TOOLCHAIN_DOWNLOAD_URL, CC and CXX are set by
# set_compilation_env
TOOLCHAIN_DOWNLOAD_URL=""

# Compilation environment variables
CC=""
CXX=""

RETCODE_SUCCESS=0
RETCODE_ERROR=1
RETRY_COUNT=${RETRY_COUNT:-5}

# GPU installer filename. Expect to be set by download_nvidia_installer().
INSTALLER_FILE=""

# Preload driver independent components. Set in parse_opt()
PRELOAD="${PRELOAD:-false}"

source gpu_installer_url_lib.sh

_log() {
  local -r prefix="$1"
  shift
  echo "[${prefix}$(date -u "+%Y-%m-%d %H:%M:%S %Z")] ""$*" >&2
}

info() {
  _log "INFO    " "$*"
}

warn() {
  _log "WARNING " "$*"
}

error() {
  _log "ERROR   " "$*"
}

lock() {
  info "Checking if this is the only cos-gpu-installer that is running."
  eval "exec ${LOCK_FILE_FD}>${LOCK_FILE}"
  if ! flock -ne ${LOCK_FILE_FD}; then
    error "File ${LOCK_FILE} is locked. Other cos-gpu-installer container might be running."
    exit ${RETCODE_ERROR}
  fi
}

load_etc_os_release() {
  if [[ ! -f "${ROOT_OS_RELEASE}" ]]; then
    error "File ${ROOT_OS_RELEASE} not found, /etc/os-release from COS host must be mounted."
    exit ${RETCODE_ERROR}
  fi
  . "${ROOT_OS_RELEASE}"
  info "Running on COS build id ${BUILD_ID}"
}

configure_kernel_module_locking() {
  info "Checking if third party kernel modules can be installed"
  local -r kernel_cmdline="$(cat /proc/cmdline)"
  # Assume that kernel commandline will never contain "lsm.module_locking=1",
  # which is the default value when unspecified.
  if echo "${kernel_cmdline}" | grep -q -v "lsm.module_locking=0"; then
    local -r esp_partition="/dev/sda12"
    local -r mount_path="/tmp/esp"
    local -r grub_cfg="efi/boot/grub.cfg"

    mkdir -p "${mount_path}"
    mount "${esp_partition}" "${mount_path}"

    pushd "${mount_path}"
    cp "${grub_cfg}" "${grub_cfg}.orig"
    sed 's/cros_efi/cros_efi lsm.module_locking=0 loadpin.enabled=0/g' \
      -i "efi/boot/grub.cfg"
    popd
    sync
    umount "${mount_path}"
    warn "Rebooting"
    echo b > /proc/sysrq-trigger
  fi
}

check_cached_version() {
  info "Checking cached version"
  if [[ ! -f "${CACHE_FILE}" ]]; then
    info "Cache file ${CACHE_FILE} not found."
    return ${RETCODE_ERROR}
  fi

  # Source the cache file and check if the cached driver matches
  # currently running image build and driver versions.
  . "${CACHE_FILE}"
  if [[ "${BUILD_ID}" == "${CACHE_BUILD_ID}" ]]; then
    if [[ "${NVIDIA_DRIVER_VERSION}" == \
          "${CACHE_NVIDIA_DRIVER_VERSION}" ]]; then
      info "Found existing driver installation for image version ${BUILD_ID} \
          and driver version ${NVIDIA_DRIVER_VERSION}."
      return ${RETCODE_SUCCESS}
    fi
  fi
  return ${RETCODE_ERROR}
}

update_cached_version() {
  cat >"${CACHE_FILE}"<<__EOF__
CACHE_BUILD_ID=${BUILD_ID}
CACHE_NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION}
__EOF__

  info "Updated cached version as:"
  cat "${CACHE_FILE}"
}

update_container_ld_cache() {
  info "Updating container's ld cache"
  echo "${NVIDIA_INSTALL_DIR_CONTAINER}/lib64" > /etc/ld.so.conf.d/nvidia.conf
  ldconfig
}

download_nvidia_installer() {
  info "Downloading GPU installer ... "
  pushd "${NVIDIA_INSTALL_DIR_CONTAINER}"
  local -r gpu_installer_download_url="$(get_gpu_installer_url ${NVIDIA_DRIVER_VERSION} ${VERSION_ID} ${BUILD_ID})"
  info "Downloading from ${gpu_installer_download_url}"
  INSTALLER_FILE="$(basename ${gpu_installer_download_url})"
  curl -L -sS "${gpu_installer_download_url}" -o "${INSTALLER_FILE}"
  if [ ! -z "${NVIDIA_DRIVER_MD5SUM}" ]; then
    echo "${NVIDIA_DRIVER_MD5SUM}" "${INSTALLER_FILE}" | md5sum --check
  fi
  popd
}

is_precompiled_installer() {
  # Helper function to decide whether the gpu installer is pre-compiled.
  [[ "${INSTALLER_FILE##*.}" == "cos" ]] || return $?
}

download_kernel_src_archive() {
  local -r download_url="$1"
  info "Kernel source archive download URL: ${download_url}"
  mkdir -p "${KERNEL_SRC_DIR}"
  pushd "${KERNEL_SRC_DIR}"
  local attempts=0
  until time curl -sfS "${download_url}" -o "${COS_KERNEL_SRC_ARCHIVE}"; do
    attempts=$(( ${attempts} + 1 ))
    if (( "${attempts}" >= "${RETRY_COUNT}" )); then
      error "Could not download kernel sources from ${download_url}, giving up."
      return ${RETCODE_ERROR}
    fi
    warn "Error fetching kernel source archive from ${download_url}, retrying"
    sleep 1
  done
  popd
}

download_kernel_src_from_gcs() {
  local -r download_url="${COS_DOWNLOAD_GCS}/${BUILD_ID}/${COS_KERNEL_SRC_ARCHIVE}"
  download_kernel_src_archive "${download_url}"
}

download_kernel_src_from_git_repo() {
  # KERNEL_COMMIT_ID comes from /root/etc/os-release file.
  local -r download_url="${COS_KERNEL_SRC_GIT}/+archive/${KERNEL_COMMIT_ID}.tar.gz"
  download_kernel_src_archive "${download_url}"
}

download_kernel_src() {
  if is_precompiled_installer; then
    info "Found pre-compiled installer, skip downloading kernel sources"
    return
  fi

  if [[ -z "$(ls -A "${KERNEL_SRC_DIR}")" ]]; then
    info "Kernel sources not found locally, downloading"
    mkdir -p "${KERNEL_SRC_DIR}"
    if ! download_kernel_src_from_gcs && ! download_kernel_src_from_git_repo; then
        return ${RETCODE_ERROR}
    fi
    pushd "${KERNEL_SRC_DIR}"
    tar xf "${COS_KERNEL_SRC_ARCHIVE}"
    popd
  fi
}

# Download content from a given URL to specific location.
#
# Args:
# download_url: The URL used to download the archive/file.
# output_name: Output name of the downloaded archive/file.
# info_str: Describes the archive/file that is downloaded.
# Returns:
# 0 if successful; Otherwise 1.
download_content_from_url() {
  local -r download_url=$1
  local -r output_name=$2
  local -r info_str=$3

  local attempts=0
  until time curl -sfS "${download_url}" -o "${output_name}"; do
    attempts=$(( ${attempts} + 1 ))
    if (( "${attempts}" >= "${RETRY_COUNT}" )); then
      error "Could not download ${info_str} from ${download_url}, giving up."
      return ${RETCODE_ERROR}
    fi
    warn "Error fetching ${info_str} from ${download_url}, retrying"
    sleep 1
  done
  return ${RETCODE_SUCCESS}
}

# Get the toolchain from Chromiumos GCS bucket when
# toolchain tarball is not found in COS GCS bucket.
get_cross_toolchain_pkg() {
  # First, check if the toolchain path is available locally.
  local -r tc_path_file="${ROOT_MOUNT_DIR}/etc/toolchain-path"
  if [[ -f "${tc_path_file}" ]]; then
    info "Found toolchain path file locally"
    local -r tc_path="$(cat "${tc_path_file}")"
    local -r download_url="${CHROMIUMOS_SDK_GCS}/${tc_path}"
  else
    # Next, check if the toolchain path is available in GCS.
    local -r tc_path_url="${COS_DOWNLOAD_GCS}/${BUILD_ID}/${TOOLCHAIN_URL_FILENAME}"
    info "Obtaining toolchain download URL from ${tc_path_url}"
    local -r download_url="$(curl -sfS "${tc_path_url}")"
  fi
  echo "${download_url}"
}

# Download, extracts and install the toolchain package
install_cross_toolchain_pkg() {
  info "$TOOLCHAIN_PKG_DIR: $(ls -A "${TOOLCHAIN_PKG_DIR}")"
  if [[ ! -z "$(ls -A "${TOOLCHAIN_PKG_DIR}")" ]]; then
    info "Found existing toolchain package. Skipping download and installation"
  else
    mkdir -p "${TOOLCHAIN_PKG_DIR}"
    pushd "${TOOLCHAIN_PKG_DIR}"
    
    info "Downloading toolchain from ${TOOLCHAIN_DOWNLOAD_URL}"
    
    # Download toolchain from download_url to pkg_name
    local -r pkg_name="$(basename "${TOOLCHAIN_DOWNLOAD_URL}")"
    if ! download_content_from_url "${TOOLCHAIN_DOWNLOAD_URL}" "${pkg_name}" "toolchain archive"; then
      # Failed to download the toolchain
      return ${RETCODE_ERROR}
    fi
    
    tar xf "${pkg_name}"
    popd
  fi
  
  info "Configuring environment variables for cross-compilation"
  export PATH="${TOOLCHAIN_PKG_DIR}/bin:${PATH}"
  export SYSROOT="${TOOLCHAIN_PKG_DIR}/usr/x86_64-cros-linux-gnu"
}

# Set-up compilation environment for compiling GPU drivers
# using toolchain used for kernel compilation
set_compilation_env() {
  info "Setting up compilation environment"
  # Get toolchain_env path from COS GCS bucket
  local -r tc_info_file_path="${COS_DOWNLOAD_GCS}/${BUILD_ID}/${TOOLCHAIN_ENV_FILENAME}"
  info "Obtaining toolchain_env file from ${tc_info_file_path}"

  # Download toolchain_env if present
  if ! download_content_from_url "${tc_info_file_path}" "${TOOLCHAIN_ENV_FILENAME}" "toolchain_env file"; then
        # Required to support COS builds not having toolchain_env file
        TOOLCHAIN_DOWNLOAD_URL=$(get_cross_toolchain_pkg)
        CC="x86_64-cros-linux-gnu-gcc"
        CXX="x86_64-cros-linux-gnu-g++"
  else
        # Successful download of toolchain_env file
        # toolchain_env file will set 'CC' and 'CXX' environment
        # variable based on the toolchain used for kernel compilation
        source "${TOOLCHAIN_ENV_FILENAME}"
        # Downloading toolchain from COS GCS Bucket
        TOOLCHAIN_DOWNLOAD_URL="${COS_DOWNLOAD_GCS}/${BUILD_ID}/${TOOLCHAIN_ARCHIVE}"
  fi

  export CC
  export CXX
}

configure_kernel_src() {
  if is_precompiled_installer; then
    info "Found pre-compiled installer, skip configuring kernel sources"
    return
  fi

  info "Configuring kernel sources"
  pushd "${KERNEL_SRC_DIR}"
  zcat /proc/config.gz > .config
  make CC="${CC}" CXX="${CXX}" olddefconfig
  make CC="${CC}" CXX="${CXX}" modules_prepare

  # TODO: Figure out why the kernel magic version hack is required.
  local kernel_version_uname="$(uname -r)"
  local kernel_version_src="$(cat include/generated/utsrelease.h | awk '{ print $3 }' | tr -d '"')"
  if [[ "${kernel_version_uname}" != "${kernel_version_src}" ]]; then
    info "Modifying kernel version magic string in source files"
    sed -i "s|${kernel_version_src}|${kernel_version_uname}|g" "include/generated/utsrelease.h"
  fi
  popd

  # COS doesn't enable module versioning, disable Module.symvers file check.
  export IGNORE_MISSING_MODULE_SYMVERS=1
}

configure_nvidia_installation_dirs() {
  info "Configuring installation directories"
  mkdir -p "${NVIDIA_INSTALL_DIR_CONTAINER}"
  pushd "${NVIDIA_INSTALL_DIR_CONTAINER}"

  # nvidia-installer does not provide an option to configure the
  # installation path of `nvidia-modprobe` utility and always installs it
  # under /usr/bin. The following workaround ensures that
  # `nvidia-modprobe` is accessible outside the installer container
  # filesystem.
  mkdir -p bin bin-workdir
  mount -t overlay -o lowerdir=/usr/bin,upperdir=bin,workdir=bin-workdir none /usr/bin

  # nvidia-installer does not provide an option to configure the
  # installation path of libraries such as libnvidia-ml.so. The following
  # workaround ensures that the libs are accessible from outside the
  # installer container filesystem.
  mkdir -p lib64 lib64-workdir
  mkdir -p /usr/lib/x86_64-linux-gnu
  mount -t overlay -o lowerdir=/usr/lib/x86_64-linux-gnu,upperdir=lib64,workdir=lib64-workdir none /usr/lib/x86_64-linux-gnu

  # nvidia-installer does not provide an option to configure the
  # installation path of driver kernel modules such as nvidia.ko. The following
  # workaround ensures that the modules are accessible from outside the
  # installer container filesystem.
  mkdir -p drivers drivers-workdir
  mkdir -p /lib/modules/"$(uname -r)"/video
  mount -t overlay -o lowerdir=/lib/modules/"$(uname -r)"/video,upperdir=drivers,workdir=drivers-workdir none /lib/modules/"$(uname -r)"/video

  # Populate ld.so.conf to avoid warning messages in nvidia-installer logs.
  update_container_ld_cache

  # Install an exit handler to cleanup the overlayfs mount points.
  trap "{ umount /lib/modules/\"$(uname -r)\"/video; umount /usr/lib/x86_64-linux-gnu ; umount /usr/bin; }" EXIT
  popd
}

run_nvidia_installer() {
  info "Running Nvidia installer"
  pushd "${NVIDIA_INSTALL_DIR_CONTAINER}"
  if is_precompiled_installer; then
    sh "${INSTALLER_FILE}" \
      --utility-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
      --opengl-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
      --no-install-compat32-libs \
      --log-file-name="${NVIDIA_INSTALL_DIR_CONTAINER}/nvidia-installer.log" \
      --silent \
      --accept-license
  else
    sh "${INSTALLER_FILE}" \
      --kernel-source-path="${KERNEL_SRC_DIR}" \
      --utility-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
      --opengl-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
      --no-install-compat32-libs \
      --log-file-name="${NVIDIA_INSTALL_DIR_CONTAINER}/nvidia-installer.log" \
      --silent \
      --accept-license
  fi
  popd
}

configure_cached_installation() {
  info "Configuring cached driver installation"
  update_container_ld_cache
  if ! lsmod | grep -q -w 'nvidia'; then
    insmod "${NVIDIA_INSTALL_DIR_CONTAINER}/drivers/nvidia.ko"
  fi
  if ! lsmod | grep -q -w 'nvidia_uvm'; then
    insmod "${NVIDIA_INSTALL_DIR_CONTAINER}/drivers/nvidia-uvm.ko"
  fi
  if ! lsmod | grep -q -w 'nvidia_drm'; then
    insmod "${NVIDIA_INSTALL_DIR_CONTAINER}/drivers/nvidia-drm.ko"
  fi
}

verify_nvidia_installation() {
  info "Verifying Nvidia installation"
  export PATH="${NVIDIA_INSTALL_DIR_CONTAINER}/bin:${PATH}"
  nvidia-smi
  # Create unified memory device file.
  nvidia-modprobe -c0 -u

  # TODO: Add support for enabling persistence mode.
}

update_host_ld_cache() {
  info "Updating host's ld cache"
  echo "${NVIDIA_INSTALL_DIR_HOST}/lib64" >> "${ROOT_MOUNT_DIR}/etc/ld.so.conf"
  ldconfig -r "${ROOT_MOUNT_DIR}"
}

usage() {
  echo "usage: $0 [-p]"
  echo "Default behavior installs all components needed for the Nvidia driver."
  echo "  -p: Install cross toolchain package and kernel source only."
}

parse_opt() {
  while getopts ":ph" opt; do
  case ${opt} in
    p)
      PRELOAD="true"
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
  done
}

main() {
  parse_opt "$@"
  info "PRELOAD: ${PRELOAD}"
  if [[ "$PRELOAD" == "true" ]]; then
    load_etc_os_release
    set_compilation_env
    install_cross_toolchain_pkg
    download_kernel_src
    info "Finished installing the cross toolchain package and kernel source."
  else
    lock
    load_etc_os_release
    configure_kernel_module_locking
    if check_cached_version; then
      configure_cached_installation
      verify_nvidia_installation
      info "Found cached version, NOT building the drivers."
    else
      info "Did not find cached version, building the drivers..."
      download_nvidia_installer
      download_kernel_src
      set_compilation_env
      install_cross_toolchain_pkg
      configure_nvidia_installation_dirs
      configure_kernel_src
      run_nvidia_installer
      update_cached_version
      verify_nvidia_installation
      info "Finished installing the drivers."
    fi
    update_host_ld_cache
  fi
}

main "$@"
