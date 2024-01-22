#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

cluster_id=$(head -n 1 "${SHARED_DIR}/cluster-id")

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

upgraded_to_version=$(head -n 1 "${SHARED_DIR}/available_upgraded_to_version.txt")
if [[ -z "$upgraded_to_version" ]]; then
  echo "No available upgraded_to openshift version is found!"
  exit 1
fi

# Get the machinepool information before upgrading
rosa list machinepool -c $cluster_id

# Upgrade machinepool
if [[ "$HOSTED_CP" == "true" ]]; then
  mp_id_list=$(rosa list machinepool -c $cluster_id -o json | jq -r ".[].id")
  for mp_id in $mp_id_list; do
    echo "Upgrade the machinepool $mp_id to $upgraded_to_version"
    rosa upgrade machinepool $mp_id -y -c $cluster_id --version $upgraded_to_version
  done

  for mp_id in $mp_id_list; do
    start_time=$(date +"%s")
    while true; do
        node_version=$(rosa list machinepool -c $cluster_id -o json | jq -r --arg k $mp_id '.[] | select(.id==$k) .version.id')
        current_time=$(date +"%s")
        if [[ "$node_version" =~ ${upgraded_to_version}- ]]; then
          record_cluster ".timers.machinset_upgrade" "${mp_id}" "$(( ${current_time} - ${start_time} ))"
          echo "Upgrade the machinepool $mp_id successfully after $(( ${current_time} - ${start_time} )) seconds"
          break
        else
          if (( $current_time - $start_time >= $NODE_UPGRADE_TIMEOUT )); then
            echo "error: Timed out while waiting for the machinepool ${mp_id} upgrading to be ready"
            record_cluster ".timers.machinset_upgrade" "${mp_id}" "not completed"
            rosa list machinepool -c $cluster_id
            exit 1
          else
            echo "Waiting 60 seconds for the next check on ${mp_id} machinepool"
            sleep 60
          fi
        fi
    done
  done
fi
rosa list machinepool -c $cluster_id
