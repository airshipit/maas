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
REGION_IMG_DIR    ?= images/maas-region-controller
RACK_SUFFIX       ?= maas-rack
RACK_IMG_DIR      ?= images/maas-rack-controller
CACHE_SUFFIX      ?= maas-cache
CACHE_IMG_DIR     ?= images/sstream-cache
IMAGE_PREFIX      ?= airshipit
IMAGE_TAG         ?= untagged
PROXY             ?= http://proxy.foo.com:8000
NO_PROXY          ?= localhost,127.0.0.1,.svc.cluster.local
USE_PROXY         ?= false
PUSH_IMAGE        ?= false
LABEL             ?= commit-id
IMAGE_NAME        := maas-rack-controller maas-region-controller sstream-cache
BUILD_DIR         := $(shell mktemp -d)
HELM              := $(BUILD_DIR)/helm
SSTREAM_IMAGE     := "https://images.maas.io/ephemeral-v3/daily/"
UBUNTU_BASE_IMAGE ?= ubuntu:16.04

.PHONY: images
#Build all images in the list
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
ifeq ($(USE_PROXY), true)
	docker build -t $(IMAGE) --network=host --label $(LABEL) -f $(IMAGE_DIR)/Dockerfile \
		--build-arg FROM=$(UBUNTU_BASE_IMAGE) \
		--build-arg http_proxy=$(PROXY) \
		--build-arg https_proxy=$(PROXY) \
		--build-arg HTTP_PROXY=$(PROXY) \
		--build-arg HTTPS_PROXY=$(PROXY) \
		--build-arg no_proxy=$(NO_PROXY) \
		--build-arg NO_PROXY=$(NO_PROXY) \
                --build-arg SSTREAM_IMAGE=$(SSTREAM_IMAGE) \
		$(IMAGE_DIR)
else
	docker build -t $(IMAGE) --network=host --label $(LABEL) -f $(IMAGE_DIR)/Dockerfile \
		--build-arg FROM=$(UBUNTU_BASE_IMAGE) \
		--build-arg SSTREAM_IMAGE=$(SSTREAM_IMAGE) \
		$(IMAGE_DIR)
endif
ifeq ($(PUSH_IMAGE), true)
	docker push $(IMAGE)
endif

.PHONY: clean
clean:
	rm -rf build

.PHONY: helm_lint
helm_lint: clean helm-install
	tools/helm_tk.sh $(HELM)
	mkdir -p build/charts/maas
	cp -R charts/maas build/charts/
	$(HELM) dep up build/charts/maas
	$(HELM) lint build/charts/maas
