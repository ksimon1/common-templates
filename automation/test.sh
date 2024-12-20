#!/bin/bash
#
# This file is part of the KubeVirt project
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
#
# Copyright 2018 Red Hat, Inc.
#

# This function will be used in release branches
function latest_patch_version() {
  local repo="$1"
  local minor_version="$2"

  # The loop is necessary, because GitHub API call cannot return more than 100 items
  local latest_version=""
  local page=1
  while true ; do
    # Declared separately to not mask return value
    local versions_in_page
    versions_in_page=$(
      curl --fail -s "https://api.github.com/repos/kubevirt/${repo}/releases?per_page=100&page=${page}" |
      jq '.[] | select(.prerelease==false) | .tag_name' |
      tr -d '"'
    )
    if [ $? -ne 0 ]; then
      return 1
    fi

    if [ -z "${versions_in_page}" ]; then
      break
    fi

    latest_version=$(
      echo "${versions_in_page} ${latest_version}" |
      tr " " "\n" |
      grep "^${minor_version}\\." |
      sort --version-sort |
      tail -n1
    )

    ((++page))
  done

  echo "${latest_version}"
}

function latest_version() {
  local repo="$1"

  # The API call sorts releases by creation timestamp, so it is enough to request only a few latest ones.
  curl --fail -s "https://api.github.com/repos/kubevirt/${repo}/releases" | \
    jq '.[] | select(.prerelease==false) | .tag_name' | \
    tr -d '"' | \
    sort --version-sort | \
    tail -n1
}

# Check if the TARGET environment variable is set
if [ -z "$TARGET" ]; then
  echo "Error: a target is needed: please set the TARGET environment variable"
  exit 1
fi

ocenv="OC"

if [ -z "$CLUSTERENV" ]
then
    export CLUSTERENV=$ocenv
fi

keyPath="/tmp/secrets/accessKeyId"
tokenPath="/tmp/secrets/secretKey"
caBundle="/tmp/secrets/ca-bundle"
namespace="kubevirt"
oc create namespace "${namespace}"

if [ "${CLUSTERENV}" == "$ocenv" ]
then
  if test -f "$keyPath" && test -f "$tokenPath"; then
    id=$(cat ${keyPath} | tr -d '\n')
    token=$(cat ${tokenPath} | tr -d '\n')

    oc apply -n $namespace -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: common-templates-container-disk-puller
  labels:
    app: containerized-data-importer
type: Opaque
data:
  accessKeyId: "$(echo -n ${id} | base64 -w 0)"
  secretKey: "$(echo -n ${token} | base64 -w 0)"
EOF
    if test -f "${caBundle}"; then
      oc create configmap custom-ca \
        --from-file=ca-bundle.crt="${caBundle}" \
        -n openshift-config

      oc patch proxy/cluster \
        --type=merge \
        --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

      oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > config.json

      oc registry login --registry="ibmc.artifactory.cnv-qe.rhood.us" \
        --auth-basic="${id}:${token}" \
        --to=config.json

      oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=config.json
    fi
  fi
fi

# Latest released Kubevirt version
export KUBEVIRT_VERSION=$(latest_version "kubevirt")

# Latest released CDI version
export CDI_VERSION=$(latest_version "containerized-data-importer")

# switch to faster storage class for widows tests (slower storage class is causing timeouts due 
# to not able to copy whole windows disk into cluster)
if [[ ! "$(oc get storageclass | grep -q 'ssd-csi (default)')" ]] && [[ $TARGET =~ windows.* ]]; then
  oc annotate storageclass ssd-csi storageclass.kubernetes.io/is-default-class=true --overwrite
  oc annotate storageclass standard-csi storageclass.kubernetes.io/is-default-class- --overwrite
fi

# Start CPU manager only for templates which require it.
if [[ $TARGET =~ rhel7.* ]] || [[ $TARGET =~ rhel8.* ]] || [[ $TARGET =~ fedora.* ]] || [[ $TARGET =~ windows2.* ]]; then
  oc label machineconfigpool worker custom-kubelet=enabled
  oc create -f - <<EOF
---
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: custom-config 
spec:
  machineConfigPoolSelector:
    matchLabels:
      custom-kubelet: enabled
  kubeletConfig: 
    cpuManagerPolicy: static
    reservedSystemCPUs: "2"
EOF

  # Verify if the machine configuration has been updated (this will increase test speed when running the second time)
  machineconfigpool_updated=$(oc get machineconfigpool worker -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}' | grep Updated | awk '{print $2}')

  if [ $machineconfigpool_updated != "True" ]; then
    oc wait --for=condition=Updating --timeout=300s machineconfigpool worker
    # it can take a while to enable CPU manager
    oc wait --for=condition=Updated --timeout=900s machineconfigpool worker
  fi
fi

_curl() {
	# this dupes the baseline "curl" command line, but is simpler
	# wrt shell quoting/expansion.
	if [ -n "${GITHUB_TOKEN}" ]; then
		curl -H "Authorization: token ${GITHUB_TOKEN}" $@
	else
		curl $@
	fi
}

git submodule update --init

make generate

#set terminationGracePeriodSeconds to 0
for filename in dist/templates/*; do
    sed -i -e 's/^\(\s*terminationGracePeriodSeconds\s*:\s*\).*/\10/' $filename
done

ARCH=$(uname -m | sed 's/x86_64/amd64/')
curl -Lo virtctl \
    https://github.com/kubevirt/kubevirt/releases/download/$KUBEVIRT_VERSION/virtctl-$KUBEVIRT_VERSION-linux-$ARCH
chmod +x virtctl

oc apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml
oc apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

timeout=600

# Waiting for kubevirt cr to report available
oc wait --for=condition=Available --timeout=${timeout}s kubevirt/kubevirt -n $namespace

oc patch kubevirt kubevirt -n $namespace --type merge -p '{"spec":{"configuration":{"developerConfiguration":{"featureGates": ["DataVolumes", "CPUManager", "NUMA", "DownwardMetrics", "VMPersistentState"]}}}}'

echo "Deploying CDI"
oc apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$CDI_VERSION/cdi-operator.yaml
oc apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$CDI_VERSION/cdi-cr.yaml

oc wait --for=condition=Available --timeout=${timeout}s CDI/cdi -n cdi

oc patch cdi cdi -n cdi --patch '{"spec": {"config": {"dataVolumeTTLSeconds": -1}}}' --type merge

oc apply -f - <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cdi-role
  namespace: cdi
rules:
- apiGroups: ["cdi.kubevirt.io"]
  resources: ["datavolumes/source"]
  verbs: ["*"]
---
EOF

if [ "${CLUSTERENV}" == "$ocenv" ]
then
    # Deploy ssp-operator
    export SSP_VERSION=$(curl -s https://api.github.com/repos/kubevirt/ssp-operator/releases | \
            jq '.[] | select(.prerelease==false) | .tag_name' | sort -V | tail -n1 | tr -d '"')
    oc apply -f https://github.com/kubevirt/ssp-operator/releases/download/${SSP_VERSION}/ssp-operator.yaml
    oc apply -f https://github.com/kubevirt/ssp-operator/releases/download/${SSP_VERSION}/olm-crds.yaml
    oc apply -f https://github.com/kubevirt/ssp-operator/releases/download/${SSP_VERSION}/olm-ssp-operator.clusterserviceversion.yaml
    oc wait --for=condition=Available --timeout=${timeout}s deployment/ssp-operator -n $namespace
    # Apply templates
    echo "Deploying templates"
    oc apply -n $namespace  -f dist/templates
fi

for node in $(oc get nodes -o name -l node-role.kubernetes.io/worker); do
    tscLabel="$(oc describe $node | grep scheduling.node.kubevirt.io/tsc-frequency- | xargs | cut -d"=" -f1)"
    # disable node labeller
    oc annotate ${node} node-labeller.kubevirt.io/skip-node=true --overwrite
    # remove tsc labels
    oc label ${node} cpu-timer.node.kubevirt.io/tsc-frequency- --overwrite
    oc label ${node} cpu-timer.node.kubevirt.io/tsc-scalable- --overwrite
    oc label ${node} ${tscLabel}- --overwrite
done

if [[ $TARGET =~ windows.* ]]; then
  ./automation/test-windows.sh $TARGET
else
  ./automation/test-linux.sh $TARGET
fi
