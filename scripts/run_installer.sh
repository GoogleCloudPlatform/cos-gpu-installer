#!/bin/bash
#
# Copyright 2018 Google LLC
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
set -o nounset

GPU_INSTALLER_ENV_KEY="cos-gpu-installer-env"
GPU_INSTALLER_ENV_PATH="/etc/gpu-installer-env"

setup() {
  if [ ! -f "${GPU_INSTALLER_ENV_PATH}" ]; then
    /usr/share/google/get_metadata_value "attributes/${GPU_INSTALLER_ENV_KEY}" \
      > "${GPU_INSTALLER_ENV_PATH}"
  fi
  source "${GPU_INSTALLER_ENV_PATH}"
  mkdir -p "${NVIDIA_INSTALL_DIR_HOST}"
  # Make NVIDIA_INSTALL_DIR_HOST executable by bind mounting it.
  mount --bind "${NVIDIA_INSTALL_DIR_HOST}" "${NVIDIA_INSTALL_DIR_HOST}"
  mount -o remount,exec "${NVIDIA_INSTALL_DIR_HOST}"
}

main() {
  setup
  docker run \
    --privileged \
    --net=host \
    --pid=host \
    --volume "${NVIDIA_INSTALL_DIR_HOST}":"${NVIDIA_INSTALL_DIR_CONTAINER}" \
    --volume /dev:/dev \
    --volume "/":"${ROOT_MOUNT_DIR}" \
    --env-file "${GPU_INSTALLER_ENV_PATH}" \
    "${COS_NVIDIA_INSTALLER_CONTAINER}"
  # Verify installation.
  ${NVIDIA_INSTALL_DIR_HOST}/bin/nvidia-smi
}

main
