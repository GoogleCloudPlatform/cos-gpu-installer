# GPU Driver Installer containers for Container-Optimized OS from Google

Note: This is not an official Google product.

This repository contains scripts to build Docker containers that can be used to
download, compile and install GPU drivers on [Container-Optimized OS]
(https://cloud.google.com/container-optimized-os/) images.

## How to use

Example command:
``` shell
gcloud compute instances create $USER-cos-gpu-test \
    --image-family cos-stable \
    --image-project cos-cloud \
    --accelerator=type=nvidia-tesla-k80 \
    --boot-disk-size=25GB \
    --maintenance-policy=TERMINATE \
    --metadata-from-file "user-data=install-test-gpu.cfg"
```
