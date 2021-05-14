#!/bin/bash
set -euo pipefail

# fetch the oc binary so we can talk to the cluster.  
#export PATH=$PATH:/tmp/shared/bin
#mkdir /tmp/shared/bin
#curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/4.5/linux/oc.tar.gz | tar xvzf - -C /tmp/shared/bin/ oc
#chmod ug+x /tmp/shared/bin/oc

# setup the persisted metadata.json and kubeconfig files that 
# correspond to the endurance cluster so we can interact with it.
# (endurance cluster credentials injected by ci-operator)
#mkdir -p /tmp/shared/auth
#mkdir -p ${ARTIFACT_DIR}/installer

# files may not exist if cluster is brand new
set +e
#cp /tmp/cluster-credentials/metadata.json ${ARTIFACT_DIR}/installer
#cp /tmp/cluster-credentials/kubeconfig /tmp/shared/auth
#cp /tmp/cluster-credentials/kubeadmin /tmp/shared/auth/kubeadmin-password
oc --config /etc/appci/kubeconfig extract secret/endurance-cluster-credentials-${OPENSHIFT_VERSION}-aws -n bparees --to ${SHARED_DIR}

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# to force a teardown of the cluster, create a configmap with this name on the cluster
oc get configmap/teardown -n openshift-config
rc=$?
if [ $rc -eq 0 ]; then
  echo "Cluster marked for teardown, tearing down and reinstalling"
  touch ${SHARED_DIR}/mustgather
  touch ${SHARED_DIR}/teardown
  exit 0
fi

# check if all the operators are reporting available. If anything
# goes wrong or any operator is not reporting available, we will 
# gather artifacts, tear down the endurance cluster, install a new one, 
# and fail this job.
echo "Fetching cluster operator status...."
oc get clusteroperators > /tmp/operators.out
rc=$?
cat /tmp/operators.out
if [ ! $rc -eq 0 ]; then
  echo "Could not retrieve cluster operator objects, collecting must-gather and tearing down cluster"
  touch ${SHARED_DIR}/mustgather
  touch ${SHARED_DIR}/teardown
  exit 0
fi

awk '{print $3}' < /tmp/operators.out  | grep -v AVAILABLE | grep -v True
rc=$?
if [ ! $rc -eq 1 ]; then
  echo "Some operators are not available, collecting must-gather from cluster"
  touch ${SHARED_DIR}/mustgather
  exit 0
fi          

echo "Fetching node status...."
oc get nodes > /tmp/nodes.out
rc=$?
cat /tmp/nodes.out
if [ ! $rc -eq 0 ]; then
  echo "Could not retrieve nodes, collecting must-gather and tearing down cluster"
  touch ${SHARED_DIR}/mustgather
  touch ${SHARED_DIR}/teardown
  exit 0
fi

grep NotReady /tmp/nodes.out
rc=$?
if [ $rc -eq 0 ]; then
  echo "Some nodes are not available, collecting must-gather from cluster"
  touch ${SHARED_DIR}/mustgather
  exit 0
fi          
set -e

echo "Cluster appears healthy"