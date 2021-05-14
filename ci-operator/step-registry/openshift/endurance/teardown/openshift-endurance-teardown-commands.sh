#!/bin/bash
set -eo pipefail

#export PATH=$PATH:/tmp/shared/bin
export KUBECONFIG=${SHARED_DIR}/kubeconfig

if [[ ! -f ${SHARED_DIR}/teardown && ! -f ${SHARED_DIR}/mustgather ]];then
  echo "Long lived cluster appears healthy, taking no action"
  exit 0
fi


function queue() {
  local TARGET="${1}"
  shift
  local LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 45 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  if [[ -n "${FILTER}" ]]; then
    "${@}" | "${FILTER}" >"${TARGET}" &
  else
    "${@}" >"${TARGET}" &
  fi
}

function teardown() {
  set +e

  echo "Gathering artifacts ..."
  mkdir -p ${ARTIFACT_DIR}/pods ${ARTIFACT_DIR}/nodes ${ARTIFACT_DIR}/metrics ${ARTIFACT_DIR}/bootstrap ${ARTIFACT_DIR}/network

  oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o jsonpath --template '{range .items[*]}{.metadata.name}{"\n"}{end}' > /tmp/nodes
  oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces --template '{{ range .items }}{{ $name := .metadata.name }}{{ $ns := .metadata.namespace }}{{ range .spec.containers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ range .spec.initContainers }}-n {{ $ns }} {{ $name }} -c {{ .name }}{{ "\n" }}{{ end }}{{ end }}' > /tmp/containers
  oc --insecure-skip-tls-verify --request-timeout=5s get pods -l openshift.io/component=api --all-namespaces --template '{{ range .items }}-n {{ .metadata.namespace }} {{ .metadata.name }}{{ "\n" }}{{ end }}' > /tmp/pods-api

  queue ${ARTIFACT_DIR}/config-resources.json oc --insecure-skip-tls-verify --request-timeout=5s get apiserver.config.openshift.io authentication.config.openshift.io build.config.openshift.io console.config.openshift.io dns.config.openshift.io featuregate.config.openshift.io image.config.openshift.io infrastructure.config.openshift.io ingress.config.openshift.io network.config.openshift.io oauth.config.openshift.io project.config.openshift.io scheduler.config.openshift.io -o json
  queue ${ARTIFACT_DIR}/apiservices.json oc --insecure-skip-tls-verify --request-timeout=5s get apiservices -o json
  queue ${ARTIFACT_DIR}/clusteroperators.json oc --insecure-skip-tls-verify --request-timeout=5s get clusteroperators -o json
  queue ${ARTIFACT_DIR}/clusterversion.json oc --insecure-skip-tls-verify --request-timeout=5s get clusterversion -o json
  queue ${ARTIFACT_DIR}/configmaps.json oc --insecure-skip-tls-verify --request-timeout=5s get configmaps --all-namespaces -o json
  queue ${ARTIFACT_DIR}/credentialsrequests.json oc --insecure-skip-tls-verify --request-timeout=5s get credentialsrequests --all-namespaces -o json
  queue ${ARTIFACT_DIR}/csr.json oc --insecure-skip-tls-verify --request-timeout=5s get csr -o json
  queue ${ARTIFACT_DIR}/endpoints.json oc --insecure-skip-tls-verify --request-timeout=5s get endpoints --all-namespaces -o json
  FILTER=gzip queue ${ARTIFACT_DIR}/deployments.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get deployments --all-namespaces -o json
  FILTER=gzip queue ${ARTIFACT_DIR}/daemonsets.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get daemonsets --all-namespaces -o json
  queue ${ARTIFACT_DIR}/events.json oc --insecure-skip-tls-verify --request-timeout=5s get events --all-namespaces -o json
  queue ${ARTIFACT_DIR}/kubeapiserver.json oc --insecure-skip-tls-verify --request-timeout=5s get kubeapiserver -o json
  queue ${ARTIFACT_DIR}/kubecontrollermanager.json oc --insecure-skip-tls-verify --request-timeout=5s get kubecontrollermanager -o json
  queue ${ARTIFACT_DIR}/machineconfigpools.json oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigpools -o json
  queue ${ARTIFACT_DIR}/machineconfigs.json oc --insecure-skip-tls-verify --request-timeout=5s get machineconfigs -o json
  queue ${ARTIFACT_DIR}/namespaces.json oc --insecure-skip-tls-verify --request-timeout=5s get namespaces -o json
  queue ${ARTIFACT_DIR}/nodes.json oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o json
  queue ${ARTIFACT_DIR}/openshiftapiserver.json oc --insecure-skip-tls-verify --request-timeout=5s get openshiftapiserver -o json
  queue ${ARTIFACT_DIR}/pods.json oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces -o json
  queue ${ARTIFACT_DIR}/persistentvolumes.json oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumes --all-namespaces -o json
  queue ${ARTIFACT_DIR}/persistentvolumeclaims.json oc --insecure-skip-tls-verify --request-timeout=5s get persistentvolumeclaims --all-namespaces -o json
  FILTER=gzip queue ${ARTIFACT_DIR}/replicasets.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get replicasets --all-namespaces -o json
  queue ${ARTIFACT_DIR}/rolebindings.json oc --insecure-skip-tls-verify --request-timeout=5s get rolebindings --all-namespaces -o json
  queue ${ARTIFACT_DIR}/roles.json oc --insecure-skip-tls-verify --request-timeout=5s get roles --all-namespaces -o json
  queue ${ARTIFACT_DIR}/services.json oc --insecure-skip-tls-verify --request-timeout=5s get services --all-namespaces -o json
  FILTER=gzip queue ${ARTIFACT_DIR}/statefulsets.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get statefulsets --all-namespaces -o json

  FILTER=gzip queue ${ARTIFACT_DIR}/openapi.json.gz oc --insecure-skip-tls-verify --request-timeout=5s get --raw /openapi/v2

  # gather nodes first in parallel since they may contain the most relevant debugging info
  while IFS= read -r i; do
    mkdir -p ${ARTIFACT_DIR}/nodes/$i
    queue ${ARTIFACT_DIR}/nodes/$i/heap oc --insecure-skip-tls-verify get --request-timeout=20s --raw /api/v1/nodes/$i/proxy/debug/pprof/heap
    FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/journal.gz oc --insecure-skip-tls-verify adm node-logs $i --unify=false
  done < /tmp/nodes

  if oc --insecure-skip-tls-verify adm node-logs -h &>/dev/null; then
    # starting in 4.0 we can query node logs directly
    FILTER=gzip queue ${ARTIFACT_DIR}/nodes/masters-journal.gz oc --insecure-skip-tls-verify adm node-logs --role=master --unify=false
    FILTER=gzip queue ${ARTIFACT_DIR}/nodes/workers-journal.gz oc --insecure-skip-tls-verify adm node-logs --role=worker --unify=false
  else
    while IFS= read -r i; do
      FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/messages.gz oc --insecure-skip-tls-verify get --request-timeout=20s --raw /api/v1/nodes/$i/proxy/logs/messages
      oc --insecure-skip-tls-verify get --request-timeout=20s --raw /api/v1/nodes/$i/proxy/logs/journal | sed -e 's|.*href="\(.*\)".*|\1|;t;d' > /tmp/journals
      while IFS= read -r j; do
        FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/journal.gz oc --insecure-skip-tls-verify get --request-timeout=20s --raw /api/v1/nodes/$i/proxy/logs/journal/${j}system.journal
      done < /tmp/journals
      FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/secure.gz oc --insecure-skip-tls-verify get --request-timeout=20s --raw /api/v1/nodes/$i/proxy/logs/secure
      FILTER=gzip queue ${ARTIFACT_DIR}/nodes/$i/audit.gz oc --insecure-skip-tls-verify get --request-timeout=20s --raw /api/v1/nodes/$i/proxy/logs/audit
    done < /tmp/nodes
  fi

  # Snapshot iptables-save on each node for debugging possible kube-proxy issues
  oc --insecure-skip-tls-verify get --request-timeout=20s -n openshift-sdn -l app=sdn pods --template '{{ range .items }}{{ .metadata.name }}{{ "\n" }}{{ end }}' > /tmp/sdn-pods
  while IFS= read -r i; do
    queue ${ARTIFACT_DIR}/network/iptables-save-$i oc --insecure-skip-tls-verify rsh --timeout=20 -n openshift-sdn -c sdn $i iptables-save -c
  done < /tmp/sdn-pods

  while IFS= read -r i; do
    file="$( echo "$i" | cut -d ' ' -f 3 | tr -s ' ' '_' )"
    queue ${ARTIFACT_DIR}/metrics/${file}-heap oc --insecure-skip-tls-verify exec $i -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8443" --config /etc/origin/master/admin.kubeconfig'
    queue ${ARTIFACT_DIR}/metrics/${file}-controllers-heap oc --insecure-skip-tls-verify exec $i -- /bin/bash -c 'oc --insecure-skip-tls-verify get --raw /debug/pprof/heap --server "https://$( hostname ):8444" --config /etc/origin/master/admin.kubeconfig'
  done < /tmp/pods-api

  while IFS= read -r i; do
    file="$( echo "$i" | cut -d ' ' -f 2,3,5 | tr -s ' ' '_' )"
    FILTER=gzip queue ${ARTIFACT_DIR}/pods/${file}.log.gz oc --insecure-skip-tls-verify logs --request-timeout=20s $i
    FILTER=gzip queue ${ARTIFACT_DIR}/pods/${file}_previous.log.gz oc --insecure-skip-tls-verify logs --request-timeout=20s -p $i
  done < /tmp/containers

  echo "Gathering kube-apiserver audit.log ..."
  oc --insecure-skip-tls-verify adm node-logs --role=master --path=kube-apiserver/ > /tmp/kube-audit-logs
  while IFS=$'\n' read -r line; do
    IFS=' ' read -ra log <<< "${line}"
    FILTER=gzip queue ${ARTIFACT_DIR}/nodes/"${log[0]}"-"${log[1]}".gz oc --insecure-skip-tls-verify adm node-logs "${log[0]}" --path=kube-apiserver/"${log[1]}"
  done < /tmp/kube-audit-logs

  echo "Gathering openshift-apiserver audit.log ..."
  oc --insecure-skip-tls-verify adm node-logs --role=master --path=openshift-apiserver/ > /tmp/openshift-audit-logs
  while IFS=$'\n' read -r line; do
    IFS=' ' read -ra log <<< "${line}"
    FILTER=gzip queue ${ARTIFACT_DIR}/nodes/"${log[0]}"-"${log[1]}".gz oc --insecure-skip-tls-verify adm node-logs "${log[0]}" --path=openshift-apiserver/"${log[1]}"
  done < /tmp/openshift-audit-logs

  echo "Snapshotting prometheus (may take 15s) ..."
  queue ${ARTIFACT_DIR}/metrics/prometheus.tar.gz oc --insecure-skip-tls-verify exec -n openshift-monitoring prometheus-k8s-0 -- tar cvzf - -C /prometheus .

  echo "Running must-gather..."
  mkdir -p ${ARTIFACT_DIR}/must-gather
  queue ${ARTIFACT_DIR}/must-gather/must-gather.log oc --insecure-skip-tls-verify adm must-gather --dest-dir ${ARTIFACT_DIR}/must-gather

  echo "Gathering audit logs..."
  mkdir -p ${ARTIFACT_DIR}/audit-logs
  queue ${ARTIFACT_DIR}/audit-logs/must-gather.log oc --insecure-skip-tls-verify adm must-gather --dest-dir ${ARTIFACT_DIR}/audit-logs -- /usr/bin/gather_audit_logs

  echo "Waiting for logs ..."
  wait

  # This is a temporary conversion of cluster operator status to JSON matching the upgrade - may be moved to code in the future
  mkdir -p ${ARTIFACT_DIR}/junit
  curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 >/tmp/jq && chmod ug+x /tmp/jq
  <${ARTIFACT_DIR}/clusteroperators.json /tmp/jq -r 'def one(condition; t): t as $t | first([.[] | select(condition)] | map(.type=t)[]) // null; def msg: "Operator \(.type) (\(.reason)): \(.message)"; def xmlfailure: if .failure then "<failure message=\"\(.failure | @html)\">\(.failure | @html)</failure>" else "" end; def xmltest: "<testcase name=\"\(.name | @html)\">\( xmlfailure )</testcase>"; def withconditions: map({name: "operator conditions \(.metadata.name)"} + ((.status.conditions // [{type:"Available",status: "False",message:"operator is not reporting conditions"}]) | (one(.type=="Available" and .status!="True"; "unavailable") // one(.type=="Degraded" and .status=="True"; "degraded") // one(.type=="Progressing" and .status=="True"; "progressing") // null) | if . then {failure: .|msg} else null end)); .items | withconditions | "<testsuite name=\"Operator results\" tests=\"\( length )\" failures=\"\( [.[] | select(.failure)] | length )\">\n\( [.[] | xmltest] | join("\n"))\n</testsuite>"' >${ARTIFACT_DIR}/junit/junit_install_status.xml

  for artifact in must-gather audit-logs ; do
    tar -czC ${ARTIFACT_DIR}/${artifact} -f ${ARTIFACT_DIR}/${artifact}.tar.gz . &&
    rm -rf ${ARTIFACT_DIR}/${artifact}
  done

  if [ -f ${SHARED_DIR}/teardown ];then
    # flag that we're going to need to install a new endurance cluster
    # after gathering artifacts/teardown.
    touch ${SHARED_DIR}/install
    if [ -f ${ARTIFACT_DIR}/installer/metadata.json ]; then
      echo "Deprovisioning cluster ..."
      export AWS_SHARED_CREDENTIALS_FILE=/etc/cloud-credentials/.awscred
      openshift-install --dir ${ARTIFACT_DIR}/installer destroy cluster
      echo "Done"
    else
      echo "no cluster metadata.json found so skipping teardown"
    fi
  fi
}

trap 'jobs -p | xargs -r kill || true; exit 0' TERM
teardown