#!/bin/bash
set -euo pipefail

#export PATH=$PATH:/tmp/shared/bin
export KUBECONFIG=${SHARED_DIR}/kubeconfig


if [ ! -f ${SHARED_DIR}/install ];then
  if [ -f /tmp/shared/mustgather ]; then
    echo "Cluster was found to be in an unhealthy state, artifacts gathered, cluster left intact"
    exit 1
  fi

  echo "Existing long lived cluster is healthy, not reinstalling"
#  oc create secret generic endurance-cluster-credentials-${CLUSTER_TYPE}-new -n ${NAMESPACE} --from-file=kubeconfig=${SHARED_DIR}/kubeconfig --from-file=kubeadmin=${SHARED_DIR}/kubeadmin-password --from-file=metadata.json=${SHARED_DIR}/metadata.json
  exit 0
fi

rm -rf ${ARTIFACT_DIR}/installer
mkdir -p ${ARTIFACT_DIR}/installer

echo "Installing from release ${RELEASE_IMAGE_LATEST}"

export EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
export SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
export PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

export HOME=/tmp

case "${CLUSTER_TYPE}" in
aws) export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred;;

export CLUSTER_NAME=${NAMESPACE}-endurance-${JOB_NAME_HASH}


if [[ "${CLUSTER_TYPE}" == "aws" ]]; then
    cat > ${ARTIFACT_DIR}/installer/install-config.yaml << EOF
apiVersion: v1beta4
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      zones:
      - us-east-2a
      - us-east-2b
compute:
- name: worker
  replicas: 3
  platform:
    type: m4.xlarge
    aws:
      zones:
      - us-east-2a
      - us-east-2b
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineCIDR: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
  networkType: OpenShiftSDN
platform:
  aws:
    region:       ${AWS_REGION}
    userTags:
      expirationDate: ${EXPIRATION_DATE}
      owner: bparees
pullSecret: |
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF
else
    echo "Unsupported cluster type '${CLUSTER_NAME}'"
    exit 1
fi

TF_LOG=debug openshift-install --dir=${ARTIFACT_DIR}/installer create cluster 2>&1 | grep --line-buffered -v password &
wait "$!"

grep -v password ${ARTIFACT_DIR}/installer/.openshift_install.log > ${ARTIFACT_DIR}/installer/install.log
mv ${ARTIFACT_DIR}/installer/install.log ${ARTIFACT_DIR}/installer/.openshift_installer.log

echo "##################### start cluster metadata.json ##########################"
cat ${ARTIFACT_DIR}/installer/metadata.json
echo
echo "##################### end cluster metadata.json ############################"       

echo "Confirming cluster is up"
oc --config ${ARTIFACT_DIR}/installer/auth/kubeconfig get clusteroperators
rc=$?
if [ ! $rc -eq 0 ]; then
  echo "Failed to communicate with newly installed cluster"
  exit 1
fi
echo "Successfully pinged new cluster"

# the ci-operator pod will copy this secret into the ci namespace to persist
# it for future jobs to use when accessing the long lived cluster.
#oc create secret generic endurance-cluster-credentials-${CLUSTER_TYPE}-new -n ${NAMESPACE} --from-file=kubeconfig=${ARTIFACT_DIR}/installer/auth/kubeconfig --from-file=metadata.json=${ARTIFACT_DIR}/installer/metadata.json --from-file=kubeadmin=${ARTIFACT_DIR}/installer/auth/kubeadmin-password


oc --config /etc/appci/kubeconfig delete secret endurance-cluster-credentials-4.8-aws -n bparees
oc --config /etc/appci/kubeconfig create secret generic endurance-cluster-credentials-4.8-aws -n bparees --from-file=kubeconfig=${ARTIFACT_DIR}/installer/auth/kubeconfig --from-file=metadata.json=${ARTIFACT_DIR}/installer/metadata.json --from-file=kubeadmin=${ARTIFACT_DIR}/installer/auth/kubeadmin-password
rm ${ARTIFACT_DIR}/installer/auth/kubeconfig 

echo "Cluster was found to be in a failed state, artifacts gathered and cluster reinstalled"
exit 1

