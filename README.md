# [ARCHIVED repository] COS GPU installer has relocated to https://cos.googlesource.com/cos/tools.
## This Git repository is archived and is now read-only.

# GPU Driver Installer containers for Container-Optimized OS from Google

Note: This is not an official Google product.

This repository contains scripts to build Docker containers that can be used to
download, compile and install GPU drivers on
[Container-Optimized OS](https://cloud.google.com/container-optimized-os/) images.

## How to use

Example command:
``` shell
gcloud compute instances create $USER-cos-gpu-test \
    --image-family cos-stable \
    --image-project cos-cloud \
    --accelerator=type=nvidia-tesla-k80 \
    --boot-disk-size=25GB \
    --maintenance-policy=TERMINATE \
    --metadata-from-file "cos-gpu-installer-env=scripts/gpu-installer-env,user-data=install-test-gpu.cfg,run-installer-script=scripts/run_installer.sh,run-cuda-test-script=scripts/run_cuda_test.sh"
```

The command above creates a GCE instance based on cos-stable image. Then it
installs GPU driver on the instance by running a container 'cos-gpu-installer'
which is implemented in this repository.

The GPU driver version and container image version are specified in
scripts/gpu-installer-env. You can edit the file if you want to install
GPU driver version or use container image other than the default.

## Release

Releases follow the naming pattern 'vYYYYMMDD' and are based on Git tags that
have the same name. Whenever a new release is published, a new container image
will be pushed to gcr.io/cos-cloud/cos-gpu-installer. It will use
container_build_request.yaml to build the image.

The container images in gcr.io/cos-cloud/cos-gpu-installer have the same tag
as the releases. Besides, the latest image will have a 'latest' tag.
