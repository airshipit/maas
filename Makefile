# Copyright 2017 AT&T Intellectual Property.  All other rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

DOCKER_REGISTRY   ?= quay.io
REGION_SUFFIX     ?= maas-region
IMG_COMMON_DIR    ?= images
RACK_SUFFIX       ?= maas-rack
CACHE_SUFFIX      ?= maas-cache
IMAGE_PREFIX      ?= airshipit
IMAGE_TAG         ?= latest
PROXY             ?= http://proxy.foo.com:8000
NO_PROXY          ?= localhost,127.0.0.1,.svc.cluster.local
USE_PROXY         ?= false
PUSH_IMAGE        ?= false
# use this variable for image labels added in internal build process
LABEL             ?= org.airshipit.build=community
COMMIT            ?= $(shell git rev-parse HEAD)
DISTRO            ?= ubuntu_jammy
STRIPPED_DISTRO   := $(shell echo $(DISTRO) | sed 's/^ubuntu_//')
IMAGE_NAME        := maas-rack-controller-$(STRIPPED_DISTRO) maas-region-controller-$(STRIPPED_DISTRO) sstream-cache-$(STRIPPED_DISTRO)
BUILD_DIR         := $(shell mktemp -d)
HELM              := $(BUILD_DIR)/helm
SSTREAM_IMAGE     := "https://images.maas.io/ephemeral-v3/stable/"
SSTREAM_RELEASE   := $(STRIPPED_DISTRO)
UBUNTU_BASE_IMAGE ?= quay.io/airshipit/ubuntu:$(STRIPPED_DISTRO)
USE_CACHED_IMG    ?= false
DOCKER_EXTRA_ARGS ?=

ifeq ($(USE_CACHED_IMG), true)
    DOCKER_EXTRA_ARGS += --build-arg BUILDKIT_INLINE_CACHE=1
else
    DOCKER_EXTRA_ARGS += --pull --no-cache --build-arg BUILDKIT_INLINE_CACHE=0
endif

ifeq ($(USE_PROXY), true)
    DOCKER_EXTRA_ARGS += --build-arg "http_proxy=$(PROXY)" --build-arg "https_proxy=$(PROXY)"
    DOCKER_EXTRA_ARGS += --build-arg "HTTP_PROXY=$(PROXY)" --build-arg "HTTPS_PROXY=$(PROXY)"
    DOCKER_EXTRA_ARGS += --build-arg "no_proxy=$(NO_PROXY)" --build-arg "NO_PROXY=$(NO_PROXY)"
endif

.PHONY: images
# Build all images in the list
images: $(IMAGE_NAME)

$(IMAGE_NAME):
	@echo
	@echo "===== Processing [$@] image ====="
	@make build IMAGE=${DOCKER_REGISTRY}/${IMAGE_PREFIX}/$@:${IMAGE_TAG} IMAGE_DIR=images/$@

# Create tgz of the chart
.PHONY: charts
charts: helm_lint
	$(HELM) package build/charts/maas

# Perform Linting
.PHONY: lint
lint: helm_lint

# Dry run templating of chart
.PHONY: dry-run
dry-run: helm_lint
	tools/helm_tk.sh $(HELM)
	$(HELM) template build/charts/maas

# Make targets intended for use by the primary targets above.

# Install helm binary
.PHONY: helm-install
helm-install:
	tools/helm_install.sh $(HELM)

.PHONY: build
build:
	docker build -t $(IMAGE) --label $(LABEL) --network=host \
        --label "org.opencontainers.image.revision=$(COMMIT)" \
        --label "org.opencontainers.image.created=$(shell date --rfc-3339=seconds --utc)" \
        --label "org.opencontainers.image.title=$(IMAGE_NAME)" \
        -f $(IMAGE_DIR)/Dockerfile \
        $(DOCKER_EXTRA_ARGS) \
        --build-arg FROM=$(UBUNTU_BASE_IMAGE) \
        --build-arg SSTREAM_IMAGE=$(SSTREAM_IMAGE) \
        --build-arg SSTREAM_RELEASE=$(SSTREAM_RELEASE) \
        $(IMAGE_DIR)
ifeq ($(PUSH_IMAGE), true)
	docker push $(IMAGE)
endif

.PHONY: clean
clean:
	rm -rf build

.PHONY: helm_lint
helm_lint: clean helm-install
	tools/helm_tk.sh $(HELM)
	mkdir -p build/charts/
	cp -R charts/* build/charts/
	$(HELM) dep up build/charts/maas
	$(HELM) lint build/charts/maas
