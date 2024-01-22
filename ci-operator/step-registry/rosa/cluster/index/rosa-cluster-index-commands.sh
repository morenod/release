#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function is_valid_json(){
  file=$1
  if [ ! -f "${file}" ]; then
    echo "ERROR: File ${file} not found"
    return 1
  elif jq '.' "${file}" >/dev/null 2>&1; then
    echo "INFO: File ${file} contains a valid json"
    return 0
  else
    echo "ERROR: File ${file} is not a valid json"
    return 1
  fi
}

function is_valid_es(){
  URL=$1
  INDEX=$2
  if [[ $(curl -sS "${URL}" | jq -r .cluster_name) == "null" ]]; then
    echo "ERROR: Cannot connect to ES ${URL}"
    return 1
  elif [[ $(curl -sS "${URL}"/_stats | jq -r .indices."${INDEX}".status) != "open" ]]; then
    echo "ERROR: Index ${URL}/${INDEX} not healthy"
    return 1
  else
    echo "INFO: ${URL}/${INDEX} healthy"
    return 0
  fi
}

index_metadata(){
  METADATA="${1}"
  URL="${2}/${3}/_doc"
  cat "${METADATA}"
  RESULT=$(curl -X POST "${URL}" -H 'Content-Type: application/json' -d "$(cat ${METADATA})" 2>/dev/null)
  if [[ $(echo "${RESULT}" | jq -r .result) == "created" ]]; then
    echo "INFO: Index of ${METADATA} completed"
  else
    echo "ERROR: Failed to index ${METADATA}"
    echo "${RESULT}"
  fi
}

if is_valid_json "${SHARED_DIR}/${METADATA_FILE}" && is_valid_es "${ES_SERVER}" "${ES_INDEX}" ; then
  cat "${SHARED_DIR}/${METADATA_FILE}" | jq 'to_entries | map(select(.key | contains("AWS") | not)) | from_entries' > "${SHARED_DIR}/${METADATA_FILE}_filtered"
  index_metadata "${SHARED_DIR}/${METADATA_FILE}_filtered" "${ES_SERVER}" "${ES_INDEX}"
fi
