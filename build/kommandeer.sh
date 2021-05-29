#! /bin/bash

unset NAMESPACE

usage(){
  echo "Usage $0 <options> <group-name>"
  echo " -n, --namespace namespace to create the claim in"
  echo "Dynamic Provisioning"
  echo "===================="
  echo "Kommandeer can also dynamically provision new volumes if all volumes in the"
  echo "group are currently bound."
  echo ""
  echo " --claim-template"
  echo "    Template string to be used as basis for dynamic provisioning. Needs to specify at least apiVersion, kind and resource requirements. Name, if present will be removed in favor of a generated name based on the group name. Namespace will be removed if present. use -n,--namespace instead."
  echo " --claim-template-file"
  echo "    Read claim template from file instead"
  echo " --claim-limit=<n>"
  echo "    Sets an upper limit on dynamic provisioning. Pool will not be grown beyond <n> volumes even if all are currently bound"
}

#Error if we try to set the same variable twice
set_once(){
  local var_name=$1
  shift
  if [ -z "${!var_name}" ]; then
    export $var_name="${1}"
  else
    echo "Tried to set '$var_name' twice!"
    usage
    exit 1
  fi

}

#Getopt allows us to also handle long args
options=$(getopt -o 'n:h' -l namespace: -l claim-template: -l claim-template-file: -l claim-limit: -- "$@")
if [ $? -ne 0 ]; then
  usage
  exit 1
fi

eval set -- "$options"
while true; do
case $1 in
  -n|--namespace)
    shift
    set_once NAMESPACE "$1"
    ;;
  -h) usage; exit 1 ;;
  --claim-template-file)
    shift
    set_once CLAIM_TEMPLATE "$(cat $1)"
    ;;
  --claim-template)
    shift
    set_once CLAIM_TEMPLATE "$1"
    ;;
  --claim-limit)
    shift
    set_once CLAIM_LIMIT "$1"
    ;;
  --)
    shift
    break
        ;;
esac
shift
done

#Positional Arguments

if [ -z "$1" ]; then
  usage
  exit 1
fi

set -e
set -u
set -o pipefail

GROUP="$1"
ALL_PVS="$(kubectl get pv -l kommandeer/group=$GROUP -o json)"

FIRST_RELEASED_PV="$( printf '%s' "$ALL_PVS" | jq '.items[] | [select(.status.phase == "Released")][0] // empty')"
TOTAL_IN_GROUP="$( printf '%s' "$ALL_PVS" | jq -rc '.items | length')"
: ${TOTAL_IN_GROUP:=0}

if [ -z "${FIRST_RELEASED_PV:+x}" ]; then
  if [ -z "${CLAIM_TEMPLATE:+x}" ]; then
    echo "ERROR: 0/${TOTAL_IN_GROUP} volumes in group '$GROUP' currently in released state"
    exit 1
  fi

  if [ $TOTAL_IN_GROUP -ge ${CLAIM_LIMIT:-$((TOTAL_IN_GROUP+1))} ]; then
    echo "ERROR: No released volumes in group '$GROUP'. Dynamic Provisioning enabled, but group is over limit: ${TOTAL_IN_GROUP}/${CLAIM_LIMIT}"
    exit 2;
  fi

  YQ_COMMAND="del(.metadata.name) | del(.metadata.namespace)| .metadata.generateName=\"kommandeer-${GROUP}-\""

  PVC=$(printf '%s' "${CLAIM_TEMPLATE}" \
  | yq e "${YQ_COMMAND}" /dev/stdin \
  | kubectl create -f /dev/stdin -o yaml
  )

  #Wait for provisioning
  NEXT_WAIT=0
  until [ $NEXT_WAIT -eq 5 ] | [ "$(echo "$PVC" | kubectl get -f /dev/stdin -o jsonpath='{.status.phase}')" = "Bound" ]; do
    sleep $((NEXT_WAIT++))
  done
  if [ $NEXT_WAIT -lt 5 ]; then
    echo "Failed to dynamically provision a new volume. Binding timed out"
    #Cleanup
    printf '%s' "$PVC" | kubectl delete -f /dev/stdin
    exit 1
  fi

  #Make sure the Volume is correctly labeled as part of the group
  kubectl label pv "$(printf '%s' "$PVC" | kubectl get -f /dev/stdin -o jsonpath='{.spec.volumeName}')" "kommandeer/group=$GROUP" > /dev/null

else
  #Claim the first released PV
  VOLUME_NAME=$(printf '%s\n' "$FIRST_RELEASED_PV" | jq '.metadata.name')

  #Use slurp to read in both the PV from memory and the template
  PVC=$(printf '%s\n' "$FIRST_RELEASED_PV" | cat pvc-template.json /dev/stdin \
  | jq --slurp --arg namePrefix "$GROUP-" -f build-pvc.jq | kubectl ${NAMESPACE:+-n $NAMESPACE} create -f - -o yaml)

  #Manually attach the targeted volume by setting claimRef directly
  PATCH=$(printf '%s\n' "$PVC" \
  | yq e '{"name": .metadata.name, "namespace": .metadata.namespace, "uid": .metadata.uid, "resourceVersion": .metadata.resourceVersion, "kind": .kind, "apiVersion": .apiVersion } | {"claimRef": .} | {"spec": .}' - )

  kubectl patch pv $(printf '%s\n' "$FIRST_RELEASED_PV" | jq -rc '.metadata.name') --patch "$PATCH" > /dev/null
fi

echo "---"
echo "$PVC"
