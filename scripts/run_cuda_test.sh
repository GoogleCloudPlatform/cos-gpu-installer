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
# The following environment variables may be changed by cos-gpu-installer-env.
NVIDIA_INSTALL_DIR_HOST="/var/lib/nvidia"
NVIDIA_INSTALL_DIR_CONTAINER="/usr/local/nvidia"
CUDA_TEST_CONTAINER="gcr.io/google_containers/cuda-vector-add:v0.1"

setup() {
  if [ ! -f "${GPU_INSTALLER_ENV_PATH}" ]; then
    /usr/share/google/get_metadata_value "attributes/${GPU_INSTALLER_ENV_KEY}" \
      > "${GPU_INSTALLER_ENV_PATH}" || true
  fi
  source "${GPU_INSTALLER_ENV_PATH}"
}

main() {
  setup
  docker run \
    --volume "${NVIDIA_INSTALL_DIR_HOST}"/lib64:"${NVIDIA_INSTALL_DIR_CONTAINER}"/lib64 \
    --device /dev/nvidia0:/dev/nvidia0 \
    --device /dev/nvidia-uvm:/dev/nvidia-uvm \
    --device /dev/nvidiactl:/dev/nvidiactl \
    "${CUDA_TEST_CONTAINER}"
}

main
