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

MAAS_IMAGE_COMMON          ?= maas
REGION_SUFFIX              ?= regiond
REGION_IMG_DIR             ?= images/maas-region-controller
RACK_SUFFIX                ?= rackd
RACK_IMG_DIR               ?= images/maas-rack-controller
CACHE_SUFFIX               ?= cache
CACHE_IMG_DIR              ?= images/sstream-cache
IMAGE_PREFIX               ?= attcomdev
IMAGE_TAG                  ?= latest
HELM                       ?= helm
PROXY                      ?= http://one.proxy.att.com:8080
USE_PROXY                  ?= false

# Build all docker images for this project
.PHONY: images
images: build_rack build_region build_cache

# Create tgz of the chart
.PHONY: charts
charts: clean
	$(HELM) dep up charts/maas
	$(HELM) package charts/maas

# Perform Linting
.PHONY: lint
lint: helm_lint

# Dry run templating of chart
.PHONY: dry-run
dry-run: clean
	tools/helm_tk.sh $(HELM)
	$(HELM) template charts/maas

# Make targets intended for use by the primary targets above.

.PHONY: build_rack
build_rack:
ifeq ($(USE_PROXY), true)
	docker build -t $(IMAGE_PREFIX)/$(MAAS_IMAGE_COMMON)-$(RACK_SUFFIX):$(IMAGE_TAG) -f $(RACK_IMG_DIR)/Dockerfile $(RACK_IMG_DIR) --build-arg http_proxy=$(PROXY) --build-arg https_proxy=$(PROXY)
else
	docker build -t $(IMAGE_PREFIX)/$(MAAS_IMAGE_COMMON)-$(RACK_SUFFIX):$(IMAGE_TAG) -f $(RACK_IMG_DIR)/Dockerfile $(RACK_IMG_DIR)
endif

.PHONY: build_region
build_region:
ifeq ($(USE_PROXY), true)
	docker build -t $(IMAGE_PREFIX)/$(MAAS_IMAGE_COMMON)-$(REGION_SUFFIX):$(IMAGE_TAG) -f $(REGION_IMG_DIR)/Dockerfile $(REGION_IMG_DIR) --build-arg http_proxy=$(PROXY) --build-arg https_proxy=$(PROXY)
else
	docker build -t $(IMAGE_PREFIX)/$(MAAS_IMAGE_COMMON)-$(REGION_SUFFIX):$(IMAGE_TAG) -f $(REGION_IMG_DIR)/Dockerfile $(REGION_IMG_DIR)
endif

.PHONY: build_cache
build_cache:
ifeq ($(USE_PROXY), true)
	docker build -t $(IMAGE_PREFIX)/$(MAAS_IMAGE_COMMON)-$(CACHE_SUFFIX):$(IMAGE_TAG) -f $(CACHE_IMG_DIR)/Dockerfile $(CACHE_IMG_DIR) --build-arg http_proxy=$(PROXY) --build-arg https_proxy=$(PROXY)
else
	docker build -t $(IMAGE_PREFIX)/$(MAAS_IMAGE_COMMON)-$(CACHE_SUFFIX):$(IMAGE_TAG) -f $(CACHE_IMG_DIR)/Dockerfile $(CACHE_IMG_DIR)
endif

.PHONY: clean
clean:
	rm -rf build

.PHONY: helm_lint
helm_lint: clean
	tools/helm_tk.sh $(HELM)
	$(HELM) lint charts/maas
