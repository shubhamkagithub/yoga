#!/bin/bash

#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -xe

#NOTE: Lint and package chart
make kafka

#NOTE: Deploy command
helm upgrade --install kafka ./kafka \
    --namespace=osh-infra \

#NOTE: Wait for deploy
./tools/deployment/common/wait-for-pods.sh osh-infra

#NOTE: Validate deployment info
helm status kafka

# Delete the test pod if it still exists
kubectl delete pods -l application=kafka,release_group=kafka,component=test --namespace=osh-infra --ignore-not-found
#NOTE: Test deployment
helm test kafka
