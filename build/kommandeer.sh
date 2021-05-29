#! /bin/bash

unset NAMESPACE

usage(){
  echo "Usage $0 <options> <group-name>"
  echo " -n, --namespace namespace to create the claim in"
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
options=$(getopt -o 'n:h' -l namespace: -- "$@")
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
  echo "ERROR: 0/${TOTAL_IN_GROUP} volumes in group '$GROUP' currently in released state"
  exit 1
fi

VOLUME_NAME=$(printf '%s\n' "$FIRST_RELEASED_PV" | jq '.metadata.name')

#Use slurp to read in both the PV from memory and the template
PVC=$(printf '%s\n' "$FIRST_RELEASED_PV" | cat pvc-template.json /dev/stdin \
 | jq --slurp --arg namePrefix "$GROUP-" -f build-pvc.jq | kubectl ${NAMESPACE:+-n $NAMESPACE} create -f - -o yaml)

#Manually attach the targeted volume by setting claimRef directly
PATCH=$(printf '%s\n' "$PVC" \
 | yq e '{"name": .metadata.name, "namespace": .metadata.namespace, "uid": .metadata.uid, "resourceVersion": .metadata.resourceVersion, "kind": .kind, "apiVersion": .apiVersion } | {"claimRef": .} | {"spec": .}' - )

kubectl patch pv $(printf '%s\n' "$FIRST_RELEASED_PV" | jq -rc '.metadata.name') --patch "$PATCH" > /dev/null

echo "---"
echo "$PVC"
