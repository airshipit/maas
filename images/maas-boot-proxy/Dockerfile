# Copyright 2026 The Airship Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG FROM=quay.io/airshipit/ubuntu:noble
ARG GO_IMAGE=quay.io/airshipit/golang:1.27.2-trixie
ARG IPXE_EFI_URL=https://boot.ipxe.org/x86_64-efi/ipxe.efi

# ------------------------------------------------------------------------------
# Stage 1: Go Proxy Builder (also fetches ipxe.efi)
# ------------------------------------------------------------------------------
FROM ${GO_IMAGE} AS builder
ARG TARGETOS
ARG TARGETARCH
ARG IPXE_EFI_URL

WORKDIR /workspace
COPY . /workspace/

RUN mkdir -p /out && curl -fsSL --retry 3 -o /out/ipxe.efi "${IPXE_EFI_URL}" \
 && for f in autoexec.ipxe vcreate busloc https; do \
      grep -aq "$f" /out/ipxe.efi || { echo "ipxe.efi lacks $f"; exit 1; }; \
    done

RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -a -o /out/maas-boot-proxy .

# ------------------------------------------------------------------------------
# Stage 2: Runtime
# ------------------------------------------------------------------------------
FROM ${FROM}

LABEL org.opencontainers.image.authors='airship-discuss@lists.airshipit.org, irc://#airshipit@freenode'
LABEL org.opencontainers.image.url='https://airshipit.org'
LABEL org.opencontainers.image.documentation='https://github.com/openstack/airship-maas'
LABEL org.opencontainers.image.source='https://git.openstack.org/openstack/airship-maas'
LABEL org.opencontainers.image.vendor='The Airship Authors'
LABEL org.opencontainers.image.licenses='Apache-2.0'
LABEL org.opencontainers.image.title='maas-boot-proxy'
LABEL org.opencontainers.image.description='Unified Smart Boot Proxy fronting MAAS rack boot server with hot-reloaded file-based node data, dynamic ISO generation, and payload rewriting.'

RUN apt-get update -qq && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /
COPY --from=builder /out/ /
USER 65534:65534

EXPOSE 8248

ENTRYPOINT ["/maas-boot-proxy"]
