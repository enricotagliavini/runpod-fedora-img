#!/bin/bash

podman run -d \
  -p 2222:22 \
  --rm \
  -v ~/.ssh/id_rsa_ovh.pub:/root/.ssh/authorized_keys:ro,Z \
  --name fedora-lemonade-test \
  fedora-lemonade

podman exec -it -u 0 fedora-lemonade-test /bin/bash -l
podman kill fedora-lemonade-test
