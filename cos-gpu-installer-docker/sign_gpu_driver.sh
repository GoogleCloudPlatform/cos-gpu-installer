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

assert_file_exists() {
  if [[ ! -f ${1} ]]; then
    exit 1
  fi
}

sign_gpu_driver() {
  local -r hash_algo="$1"
  # private key is a dummy key. It is not needed in this script as we already
  # have the signature.
  #local -r priv_key="$2"
  local -r pub_key="$3"
  local -r module="$4"
  # sign-file is used to attach driver signature to gpu driver to generate a
  # signed driver. It is compiled from scripts/sign-file.c of Linux kernel
  # source code. COS team provide it along with gpu driver signature to make
  # sure the sign-file matches the kernel of COS version.
  local -r sign_file="$(dirname "${pub_key}")"/sign-file
  local -r signature="$(dirname "${pub_key}")/$(basename "${module}")".sig

  assert_file_exists "${pub_key}"
  assert_file_exists "${module}"
  assert_file_exists "${sign_file}"
  assert_file_exists "${signature}"

  chmod +x "${sign_file}"

  "${sign_file}" -s "${signature}" "${hash_algo}" "${pub_key}" "${module}"
}

sign_gpu_driver "$@"
