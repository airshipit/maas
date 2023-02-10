#!/bin/bash

{{/*
# Copyright (c) 2017 AT&T Intellectual Property. All rights reserved.
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
# limitations under the License. */}}

set -ex

function check_boot_images {
    if maas local boot-resources is-importing | grep -q 'true';
    then
        echo -e '\nBoot resources currently importing\n'
        return 1
    else
        synced_imgs=$(maas local boot-resources read | tr -d '\n' | grep -oE '{[^}]+}' | grep ubuntu | grep -c Synced)
        if [[ $synced_imgs -gt 0 ]]
        then
            echo 'Boot resources have completed importing'
            return 0
        else
            return 1
        fi
    fi
}

function check_rack_controllers {
    rack_cnt=$(maas local rack-controllers read | grep -c hostname)
    if [[ $rack_cnt -gt 0 ]]
    then
      echo "Found $rack_cnt rack controllers."
      return 0
    else
      return 1
    fi
}

function establish_session {
    maas login local ${MAAS_URL} ${MAAS_API_KEY}
    return $?
}

establish_session

if [[ $? -ne 0 ]]
then
    echo "MAAS API login FAILED!"
    exit 1
fi

check_boot_images

if [[ $? -eq 1 ]]
then
    echo "Image import test FAILED!"
    exit 1
fi

check_rack_controllers

if [[ $? -eq 1 ]]
then
    echo "Rack controller query FAILED!"
    exit 1
fi

echo "MAAS Validation SUCCESS!"
exit 0
