#!/bin/bash
#
# Copyright 2019 Google LLC
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

GPU_INSTALLER_DOWNLOAD_URL="${GPU_INSTALLER_DOWNLOAD_URL:-}"

get_major_version() {
  echo "$1" | cut -d "." -f 1
}

get_minor_version() {
  echo "$1" | cut -d "." -f 2
}

get_download_location() {
  # projects/000000000000/zones/us-west1-a -> us
  local -r instance_location="$(curl --http1.1 -sfS "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" | cut -d '/' -f4 | cut -d '-' -f1)"
  declare -A location_mapping
  location_mapping=( ["us"]="us" ["asia"]="asia" ["europe"]="eu" )
  # Use us as default download location.
  echo "${location_mapping[${instance_location}]:-us}"
}

precompiled_installer_download_url() {
  local -r driver_version="$1"
  local -r milestone="$2"
  local -r build_id="${3//\./-}"  # 11895.86.0 -> 11895-86-0
  local -r major_version="$(get_major_version "${driver_version}")"
  local -r minor_version="$(get_minor_version "${driver_version}")"
  local -r download_location="$(get_download_location)"

  echo "https://storage.googleapis.com/nvidia-drivers-${download_location}-public/nvidia-cos-project/${milestone}/tesla/${major_version}_00/${driver_version}/NVIDIA-Linux-x86_64-${driver_version}_${milestone}-${build_id}.cos"
}

default_installer_download_url() {
  local -r driver_version="$1"
  local -r major_version="$(get_major_version "${driver_version}")"
  local -r minor_version="$(get_minor_version "${driver_version}")"
  local -r download_location="$(get_download_location)"

  if (( "${major_version}" < 390 )); then
    # Versions prior to 390 are downloaded from the upstream location.
    echo "https://us.download.nvidia.com/tesla/${driver_version}/NVIDIA-Linux-x86_64-${driver_version}.run"
  elif (( "${major_version}" == 390 )) && (( "${minor_version}" == 46 )); then
    # 390.46 is the only version residing in the TESLSA/ dir
    echo "https://storage.googleapis.com/nvidia-drivers-${download_location}-public/TESLA/NVIDIA-Linux-x86_64-${driver_version}.run"
  elif (( "${major_version}" == 396 )) && (( "${minor_version}" == 26 )); then
    # Different naming format for 396.26 including the -dignostic keyword.
    echo "https://storage.googleapis.com/nvidia-drivers-${download_location}-public/tesla/${driver_version}/NVIDIA-Linux-x86_64-${driver_version}-diagnostic.run"
  else
    # All other versions available in the gs conform to this naming convention.
    echo "https://storage.googleapis.com/nvidia-drivers-${download_location}-public/tesla/${driver_version}/NVIDIA-Linux-x86_64-${driver_version}.run"
  fi
}

get_gpu_installer_url() {
  if [[ -z "${GPU_INSTALLER_DOWNLOAD_URL}" ]]; then
    # First try to find the precompiled gpu installer.
    local -r url="$(precompiled_installer_download_url "$@")"
    if curl --http1.1 -s -I "${url}"  2>&1 | grep -q 'HTTP/2 200'; then
      GPU_INSTALLER_DOWNLOAD_URL="${url}"
    else
      # Fallback to default gpu installer.
      GPU_INSTALLER_DOWNLOAD_URL="$(default_installer_download_url "$@")"
    fi
  fi
  echo "${GPU_INSTALLER_DOWNLOAD_URL}"
}
