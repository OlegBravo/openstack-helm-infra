#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
#
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
make ceph-mon
make ceph-osd
make ceph-client
make ceph-provisioners

#NOTE: Deploy command
[ -s /tmp/ceph-fs-uuid.txt ] || uuidgen > /tmp/ceph-fs-uuid.txt
CEPH_PUBLIC_NETWORK="$(./tools/deployment/multinode/kube-node-subnet.sh)"
CEPH_CLUSTER_NETWORK="${CEPH_PUBLIC_NETWORK}"
CEPH_FS_ID="$(cat /tmp/ceph-fs-uuid.txt)"
#NOTE(portdirect): to use RBD devices with kernels < 4.5 this should be set to 'hammer'
LOWEST_CLUSTER_KERNEL_VERSION=$(kubectl get node  -o go-template='{{range .items}}{{.status.nodeInfo.kernelVersion}}{{"\n"}}{{ end }}' | sort -V | tail -1)
if [ "$(echo ${LOWEST_CLUSTER_KERNEL_VERSION} | awk -F "." '{ print $1 }')" -lt "4" ] || [ "$(echo ${LOWEST_CLUSTER_KERNEL_VERSION} | awk -F "." '{ print $2 }')" -lt "15" ]; then
  echo "Using hammer crush tunables"
  CRUSH_TUNABLES=hammer
else
  CRUSH_TUNABLES=null
fi
NUMBER_OF_OSDS="$(kubectl get nodes -l ceph-osd=enabled --no-headers | wc -l)"
tee /tmp/ceph.yaml << EOF
endpoints:
  identity:
    namespace: openstack
  object_store:
    namespace: ceph
  ceph_mon:
    namespace: ceph
network:
  public: ${CEPH_PUBLIC_NETWORK}
  cluster: ${CEPH_CLUSTER_NETWORK}
deployment:
  storage_secrets: true
  ceph: true
  rbd_provisioner: true
  cephfs_provisioner: false
  client_secrets: false
  rgw_keystone_user_and_endpoints: false
bootstrap:
  enabled: true
conf:
  ceph:
    global:
      fsid: ${CEPH_FS_ID}
  rgw_ks:
    enabled: true
  pool:
    crush:
      tunables: ${CRUSH_TUNABLES}
    target:
      osd: ${NUMBER_OF_OSDS}
      pg_per_osd: 100
  storage:
    osd:
      - data:
          type: directory
          location: /var/lib/openstack-helm/ceph/osd/osd-one
        journal:
          type: directory
          location: /var/lib/openstack-helm/ceph/osd/journal-one
jobs:
  ceph_defragosds:
    # Execute every 15 minutes for gates
    cron: "*/15 * * * *"
    history:
      # Number of successful job to keep
      successJob: 1
      # Number of failed job to keep
      failJob: 1
    concurrency:
      # Skip new job if previous job still active
      execPolicy: Forbid
    startingDeadlineSecs: 60
storageclass:
  cephfs:
    provision_storage_class: false
manifests:
  cronjob_defragosds: true
  deployment_cephfs_provisioner: false
  job_cephfs_client_key: false
EOF

for CHART in ceph-mon ceph-osd ceph-client ceph-provisioners; do
  helm upgrade --install ${CHART} ./${CHART} \
    --namespace=ceph \
    --values=/tmp/ceph.yaml \
    ${OSH_INFRA_EXTRA_HELM_ARGS} \
    ${OSH_INFRA_EXTRA_HELM_ARGS_CEPH_DEPLOY}

  #NOTE: Wait for deploy
  ./tools/deployment/common/wait-for-pods.sh ceph 1200

  #NOTE: Validate deploy
  MON_POD=$(kubectl get pods \
    --namespace=ceph \
    --selector="application=ceph" \
    --selector="component=mon" \
    --no-headers | awk '{ print $1; exit }')
  kubectl exec -n ceph ${MON_POD} -- ceph -s
done
helm test ceph-osd --timeout 900
helm test ceph-client --timeout 900
