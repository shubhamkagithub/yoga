#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -ex

function check_cluster_status() {
  echo "#### Start: Checking Ceph cluster status ####"
  ceph_status_output=$(ceph -s -f json | jq -r '.health')
  ceph_health_status=$(echo $ceph_status_output | jq -r '.status')

  if [ "x${ceph_health_status}" == "xHEALTH_OK" ]; then
    echo "Ceph status is HEALTH_OK"
  else
    echo "Ceph cluster status is not HEALTH_OK, checking PG states"
    retries=0
    # If all PGs are active, pass
    # This grep is just as robust as jq and is Ceph-version agnostic unlike jq
    while [[ $(ceph pg ls -f json-pretty | grep '"state":' | grep -v "active") ]] && [[ retries -lt 60 ]]; do
      # If all inactive PGs are peering, wait for peering to complete
      # Run 'ceph pg ls' again before failing in case PG states have changed
      if [[ $(ceph pg ls -f json-pretty | grep '"state":' | grep -v -e "active" -e "peering") ]]; then
        # If inactive PGs aren't peering, fail
        echo "Failure, found inactive PGs that aren't peering"
        exit 1
      fi
      sleep 3
      ((retries=retries+1))
    done
    # If peering PGs haven't gone active after retries have expired, fail
    if [[ retries -ge 60 ]]; then
      echo "PGs appear to be stuck peering"
      exit 1
    fi
  fi
}

function check_recovery_flags() {
  echo "### Start: Checking for flags that will prevent recovery"

  # Ensure there are no flags set that will prevent recovery of degraded PGs
  if [[ $(ceph osd stat | grep "norecover\|nobackfill\|norebalance") ]]; then
    ceph osd stat
    echo "Flags are set that prevent recovery of degraded PGs"
    exit 1
  fi
}

function check_osd_count() {
  echo "#### Start: Checking OSD count ####"
  noup_flag=$(ceph osd stat | awk '/noup/ {print $2}')
  osd_stat=$(ceph osd stat -f json)
  num_osd=$(jq '.osdmap.num_osds' <<< "$osd_stat")
  num_in_osds=$(jq '.osdmap.num_in_osds' <<< "$osd_stat")
  num_up_osds=$(jq '.osdmap.num_up_osds' <<< "$osd_stat")

  MIN_OSDS=$((${num_osd}*$REQUIRED_PERCENT_OF_OSDS/100))
  if [ ${MIN_OSDS} -lt 1 ]; then
    MIN_OSDS=1
  fi

  if [ "${noup_flag}" ]; then
    osd_status=$(ceph osd dump -f json | jq -c '.osds[] | .state')
    count=0
    for osd in $osd_status; do
      if [[ "$osd" == *"up"* || "$osd" == *"new"* ]]; then
        ((count=count+1))
      fi
    done
    echo "Caution: noup flag is set. ${count} OSDs in up/new state. Required number of OSDs: ${MIN_OSDS}."
    if [ $MIN_OSDS -gt $count ]; then
      exit 1
    fi
  else
    if [ "${num_osd}" -eq 0 ]; then
      echo "There are no osds in the cluster"
      exit 1
    elif [ "${num_in_osds}" -ge "${MIN_OSDS}" ] && [ "${num_up_osds}" -ge "${MIN_OSDS}"  ]; then
      echo "Required number of OSDs (${MIN_OSDS}) are UP and IN status"
    else
      echo "Required number of OSDs (${MIN_OSDS}) are NOT UP and IN status. Cluster shows OSD count=${num_osd}, UP=${num_up_osds}, IN=${num_in_osds}"
      exit 1
    fi
  fi
}

function check_failure_domain_count_per_pool() {
  echo "#### Start: Checking failure domain count per pool ####"
  pools=$(ceph osd pool ls)
  for pool in ${pools}
  do
    crush_rule=$(ceph osd pool get ${pool} crush_rule | awk '{print $2}')
    bucket_type=$(ceph osd crush rule dump ${crush_rule} | grep '"type":' | awk -F'"' 'NR==2 {print $4}')
    num_failure_domains=$(ceph osd tree | grep ${bucket_type} | wc -l)
    pool_replica_size=$(ceph osd pool get ${pool} size | awk '{print $2}')
    if [[ ${num_failure_domains} -ge ${pool_replica_size} ]]; then
      echo "--> Info: Pool ${pool} is configured with enough failure domains ${num_failure_domains} to satisfy pool replica size ${pool_replica_size}"
    else
      echo "--> Error : Pool ${pool} is NOT configured with enough failure domains ${num_failure_domains} to satisfy pool replica size ${pool_replica_size}"
      exit 1
    fi
  done
}

function mgr_validation() {
  echo "#### Start: MGR validation ####"
  mgr_dump=$(ceph mgr dump -f json-pretty)
  echo "Checking for ${MGR_COUNT} MGRs"

  mgr_avl=$(echo ${mgr_dump} | jq -r '.["available"]')

  if [ "x${mgr_avl}" == "xtrue" ]; then
    mgr_active=$(echo ${mgr_dump} | jq -r '.["active_name"]')
    echo "Out of ${MGR_COUNT}, 1 MGR is active"

    # Now lets check for standby managers
    mgr_stdby_count=$(echo ${mgr_dump} | jq -r '.["standbys"]' | jq length)

    #Total MGR Count - 1 Active = Expected MGRs
    expected_standbys=$(( MGR_COUNT -1 ))

    if [ $mgr_stdby_count -eq $expected_standbys ]
    then
      echo "Cluster has 1 Active MGR, $mgr_stdby_count Standbys MGR"
    else
      echo "Cluster Standbys MGR: Expected count= $expected_standbys Available=$mgr_stdby_count"
      retcode=1
    fi

  else
    echo "No Active Manager found, Expected 1 MGR to be active out of ${MGR_COUNT}"
    retcode=1
  fi

  if [ "x${retcode}" == "x1" ]
  then
    exit 1
  fi
}

function pool_validation() {

  echo "#### Start: Checking Ceph pools ####"

  echo "From env variables, RBD pool replication count is: ${RBD}"

  # Assuming all pools have same replication count as RBD
  # If RBD replication count is greater then 1, POOLMINSIZE should be 1 less then replication count
  # If RBD replication count is not greate then 1, then POOLMINSIZE should be 1

  if [ ${RBD} -gt 1 ]; then
    EXPECTED_POOLMINSIZE=$[${RBD}-1]
  else
    EXPECTED_POOLMINSIZE=1
  fi

  echo "EXPECTED_POOLMINSIZE: ${EXPECTED_POOLMINSIZE}"

  expectedCrushRuleId=""
  nrules=$(echo ${OSD_CRUSH_RULE_DUMP} | jq length)
  c=$[nrules-1]
  for n in $(seq 0 ${c})
  do
    osd_crush_rule_obj=$(echo ${OSD_CRUSH_RULE_DUMP} | jq -r .[${n}])

    name=$(echo ${osd_crush_rule_obj} | jq -r .rule_name)
    echo "Expected Crushrule: ${EXPECTED_CRUSHRULE}, Pool Crushmap: ${name}"

    if [ "x${EXPECTED_CRUSHRULE}" == "x${name}" ]; then
      expectedCrushRuleId=$(echo ${osd_crush_rule_obj} | jq .rule_id)
      echo "Checking against rule: id: ${expectedCrushRuleId}, name:${name}"
    else
      echo "Didn't match"
    fi
  done
  echo "Checking cluster for size:${RBD}, min_size:${EXPECTED_POOLMINSIZE}, crush_rule:${EXPECTED_CRUSHRULE}, crush_rule_id:${expectedCrushRuleId}"

  npools=$(echo ${OSD_POOLS_DETAILS} | jq length)
  i=$[npools - 1]
  for n in $(seq 0 ${i})
  do
    pool_obj=$(echo ${OSD_POOLS_DETAILS} | jq -r ".[${n}]")

    size=$(echo ${pool_obj} | jq -r .size)
    min_size=$(echo ${pool_obj} | jq -r .min_size)
    pg_num=$(echo ${pool_obj} | jq -r .pg_num)
    pg_placement_num=$(echo ${pool_obj} | jq -r .pg_placement_num)
    crush_rule=$(echo ${pool_obj} | jq -r .crush_rule)
    name=$(echo ${pool_obj} | jq -r .pool_name)
    pg_autoscale_mode=$(echo ${pool_obj} | jq -r .pg_autoscale_mode)
    if [[ "${ENABLE_AUTOSCALER}" == "true" ]]; then
      if [[ "${pg_autoscale_mode}" != "on" ]]; then
        echo "pg autoscaler not enabled on ${name} pool"
        exit 1
      fi
    fi
    if [[ $(ceph tell mon.* version | egrep -q "nautilus"; echo $?) -eq 0 ]]; then
      if [ "x${size}" != "x${RBD}" ] || [ "x${min_size}" != "x${EXPECTED_POOLMINSIZE}" ] \
        || [ "x${crush_rule}" != "x${expectedCrushRuleId}" ]; then
        echo "Pool ${name} has incorrect parameters!!! Size=${size}, Min_Size=${min_size}, Rule=${crush_rule}, PG_Autoscale_Mode=${pg_autoscale_mode}"
        exit 1
      else
        echo "Pool ${name} seems configured properly. Size=${size}, Min_Size=${min_size}, Rule=${crush_rule}, PG_Autoscale_Mode=${pg_autoscale_mode}"
      fi
    else
      if [ "x${size}" != "x${RBD}" ] || [ "x${min_size}" != "x${EXPECTED_POOLMINSIZE}" ] \
      || [ "x${pg_num}" != "x${pg_placement_num}" ] || [ "x${crush_rule}" != "x${expectedCrushRuleId}" ]; then
        echo "Pool ${name} has incorrect parameters!!! Size=${size}, Min_Size=${min_size}, PG=${pg_num}, PGP=${pg_placement_num}, Rule=${crush_rule}"
        exit 1
      else
        echo "Pool ${name} seems configured properly. Size=${size}, Min_Size=${min_size}, PG=${pg_num}, PGP=${pg_placement_num}, Rule=${crush_rule}"
      fi
    fi
  done
}

function pool_failuredomain_validation() {
  echo "#### Start: Checking Pools are configured with specific failure domain ####"

  expectedCrushRuleId=""
  nrules=$(echo ${OSD_CRUSH_RULE_DUMP} | jq length)
  c=$[nrules-1]
  for n in $(seq 0 ${c})
  do
    osd_crush_rule_obj=$(echo ${OSD_CRUSH_RULE_DUMP} | jq -r .[${n}])

    name=$(echo ${osd_crush_rule_obj} | jq -r .rule_name)

    if [ "x${EXPECTED_CRUSHRULE}" == "x${name}" ]; then
      expectedCrushRuleId=$(echo ${osd_crush_rule_obj} | jq .rule_id)
      echo "Checking against rule: id: ${expectedCrushRuleId}, name:${name}"
    fi
  done

  echo "Checking OSD pools are configured with Crush rule name:${EXPECTED_CRUSHRULE}, id:${expectedCrushRuleId}"

  npools=$(echo ${OSD_POOLS_DETAILS} | jq length)
  i=$[npools-1]
  for p in $(seq 0 ${i})
  do
    pool_obj=$(echo ${OSD_POOLS_DETAILS} | jq -r ".[${p}]")

    pool_crush_rule_id=$(echo $pool_obj | jq -r .crush_rule)
    pool_name=$(echo $pool_obj | jq -r .pool_name)

    if [ "x${pool_crush_rule_id}" == "x${expectedCrushRuleId}" ]; then
      echo "--> Info: Pool ${pool_name} is configured with the correct rule ${pool_crush_rule_id}"
    else
      echo "--> Error : Pool ${pool_name} is NOT configured with the correct rule ${pool_crush_rule_id}"
      exit 1
    fi
  done
}

function pg_validation() {
  ceph pg ls
  inactive_pgs=(`ceph --cluster ${CLUSTER} pg ls -f json-pretty | grep '"pgid":\|"state":' | grep -v "active" | grep -B1 '"state":' | awk -F "\"" '/pgid/{print $4}'`)
  if [ ${#inactive_pgs[*]} -gt 0 ];then
    echo "There are few incomplete pgs in the cluster"
    echo ${inactive_pgs[*]}
    exit 1
  fi
}

function check_ceph_osd_crush_weight(){
  OSDS_WITH_ZERO_WEIGHT=(`ceph --cluster ${CLUSTER} osd df -f json-pretty | awk -F"[, ]*" '/"crush_weight":/{if ($3 == 0) print $3}'`)
  if [[ ${#OSDS_WITH_ZERO_WEIGHT[*]} -eq 0 ]]; then
    echo "All OSDs from namespace have crush weight!"
  else
    echo "OSDs from namespace have zero crush weight"
    exit 1
  fi
}

check_osd_count
mgr_validation

OSD_POOLS_DETAILS=$(ceph osd pool ls detail -f json-pretty)
OSD_CRUSH_RULE_DUMP=$(ceph osd crush rule dump -f json-pretty)
PG_STAT=$(ceph pg stat -f json-pretty)

ceph -s
pg_validation
pool_validation
pool_failuredomain_validation
check_failure_domain_count_per_pool
check_cluster_status
check_recovery_flags
check_ceph_osd_crush_weight
