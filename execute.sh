#!/bin/sh
#echo "########## Sleeping to wait for Automatic Upgrades complete ###########"
#sleep 180
#echo "########## Awoke! Ready to procees with the Script ###########"

cloud-init status --wait

echo "##########DEPLOYMENT_NAME###########: $DEPLOYMENT_NAME"
echo "##########VM NAME###########: $VM_NAME"
echo "##########ITEM_COUNT_FOR_WRITE###########: $ITEM_COUNT_FOR_WRITE"
echo "##########MACHINE_INDEX###########: $MACHINE_INDEX"
echo "##########YCSB_OPERATION_COUNT###########: $YCSB_OPERATION_COUNT"
echo "##########VM_COUNT###########: $VM_COUNT"

# The index of the record to start at during the Load
insertstart=$((ITEM_COUNT_FOR_WRITE* (MACHINE_INDEX-1)))
# Records already in the DB + records to be added, during load 
recordcount=$((ITEM_COUNT_FOR_WRITE* MACHINE_INDEX))
# Record count for Run. Since we run read workload after load this is the total number of records loaded by all VMs/clients during load. 
totalrecordcount=$((ITEM_COUNT_FOR_WRITE* VM_COUNT))

#Install Software
echo "########## Installing azcopy ###########"
wget https://aka.ms/downloadazcopy-v10-linux
tar -xvf downloadazcopy-v10-linux
sudo cp ./azcopy_linux_amd64_*/azcopy /usr/bin/

#Build YCSB from source and create a docker container
echo "##########Cloning YCSB ##########"
git clone -b "$YCSB_GIT_BRANCH_NAME" --single-branch "$YCSB_GIT_REPO_URL"

echo "########## Building YCSB ##########"
cd YCSB
mvn -pl site.ycsb:azurecosmos-binding -am clean package
cp -r ./azurecosmos/target/ /tmp/ycsb
cp -r ./azurecosmos/conf/* /tmp/ycsb
cd /tmp/ycsb/

echo "########## Extracting YCSB ##########"
tar xfvz ycsb-azurecosmos-binding-0.18.0-SNAPSHOT.tar.gz
cp ./run.sh ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cp ./azurecosmos.properties ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cp ./aggregate_multiple_file_results.py ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cp ./converting_log_to_csv.py ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cd ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT

if [ $MACHINE_INDEX -eq 1 ]; then
  table_exist=$(az storage table exists --name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING | jq '.exists')
  if [ "$table_exist" = true ]; then
    echo "${DEPLOYMENT_NAME}Metadata already exists"
  else
    az storage table create --name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING
  fi

  ## Creating SAS URL for result storage container
  echo "########## Creating SAS URL for result storage container ###########"
  end=$(date -u -d "180 minutes" '+%Y-%m-%dT%H:%MZ')
  current_time="$(date '+%Y-%m-%d-%Hh%Mm%Ss')"
  az storage container create -n "result-$current_time" --connection-string $RESULT_STORAGE_CONNECTION_STRING

  sas=$(az storage container generate-sas -n "result-$current_time" --connection-string $RESULT_STORAGE_CONNECTION_STRING --https-only --permissions dlrw --expiry $end -o tsv)

  arr_connection=(${RESULT_STORAGE_CONNECTION_STRING//;/ })

  protocol_string=${arr_connection[0]}
  arr_protocol_string=(${protocol_string//=/ })
  protocol=${arr_protocol_string[1]}

  account_string=${arr_connection[1]}
  arr_account_string=(${account_string//=/ })
  account_name=${arr_account_string[1]}

  result_storage_url="${protocol}://${account_name}.blob.core.windows.net/result-${current_time}?${sas}"

  client_start_time=$(date -u -d "5 minutes" '+%Y-%m-%dT%H:%M:%S') # date in ISO 8601 format
  az storage entity insert --entity PartitionKey="${DEPLOYMENT_NAME}_${GUID}" RowKey="ycsb_sql" ClientStartTime=$client_start_time SAS_URL=$result_storage_url --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING
else
  for i in $(seq 1 5); do
    table_entry=$(az storage entity show --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING --partition-key "${DEPLOYMENT_NAME}_${GUID}" --row-key "ycsb_sql")
    if [ -z "$table_entry" ]; then
      echo "sleeping for 1 min, table row not availble yet"
      sleep 1m
      continue
    fi
    client_start_time=$(echo $table_entry | jq .ClientStartTime)
    result_storage_url=$(echo $table_entry | jq .SAS_URL)
    break
  done
  if [ -z "$client_start_time" ] || [ -z "$result_storage_url" ]; then
    echo "Error while getting client_start_time/result_storage_url, exiting from this machine"
    exit 1
  fi
fi
## Removing quotes from the client_start_time and converting it into seconds
client_start_time=$(echo "$client_start_time" | tr -d '"')
client_start_time=$(date -d "$client_start_time" +'%s')
## Removing quotes from the result_storage_url
result_storage_url=$(echo "$result_storage_url" | tr -d '"')

## If it is load operation sync the clients start time
if [ "$YCSB_OPERATION" = "load" ]; then
  now=$(date +"%s")
  wait_interval=$(($client_start_time - $now))
  if [ $wait_interval -gt 0 ]; then
    echo "Sleeping for $wait_interval second to sync with other clients"
    sleep $wait_interval
  else
    echo "Not sleeping on clients sync time $client_start_time as it already past"
  fi
fi

##Load operation for YCSB tests
echo "########## Load operation for YCSB tests ###########"
uri=$COSMOS_URI primaryKey=$COSMOS_KEY workload_type=$WORKLOAD_TYPE ycsb_operation="load" recordcount=$recordcount insertstart=$insertstart insertcount=$ITEM_COUNT_FOR_WRITE threads=$THREAD_COUNT target=$TARGET_OPERATIONS_PER_SECOND sh run.sh

#Execute YCSB test
if [ "$YCSB_OPERATION" = "run" ]; then
  now=$(date +"%s")
  wait_interval=$(($client_start_time - $now))
  if [ $wait_interval -gt 0 ]; then
    echo "Sleeping for $wait_interval second to sync with other clients"
    sleep $wait_interval
  else
    echo "Not sleeping on clients sync time $client_start_time as it already past"
  fi
  cp /tmp/ycsb.log /home/benchmarking/"$VM_NAME-ycsb-load.txt"
  sudo azcopy copy /home/benchmarking/"$VM_NAME-ycsb-load.txt" "$result_storage_url"
  # Clearing log file from above load operation
  sudo rm -f /tmp/ycsb.log
  sudo rm -f "/home/benchmarking/$VM_NAME-ycsb-load.txt"
  uri=$COSMOS_URI primaryKey=$COSMOS_KEY workload_type=$WORKLOAD_TYPE ycsb_operation=$YCSB_OPERATION recordcount=$totalrecordcount operationcount=$YCSB_OPERATION_COUNT threads=$THREAD_COUNT target=$TARGET_OPERATIONS_PER_SECOND sh run.sh
fi

#Copy YCSB log to storage account
echo "########## Copying Results to Storage ###########"
cp /tmp/ycsb.log /home/benchmarking/"$VM_NAME-ycsb.log"
sudo python3 converting_log_to_csv.py /home/benchmarking/"$VM_NAME-ycsb.log"
sudo azcopy copy "$VM_NAME-ycsb.csv" "$result_storage_url"
sudo azcopy copy "/home/benchmarking/$VM_NAME-ycsb.log" "$result_storage_url"

if [ $MACHINE_INDEX -eq 1 ]; then
  echo "Waiting on VM1 for 5 min"
  sleep 5m
  cd /home/benchmarking
  mkdir "aggregation"
  cd aggregation
  index_for_regex=$(expr index "$result_storage_url" '?')
  regex_to_append="/*"
  url_first_part=$(echo $result_storage_url | cut -c 1-$((index_for_regex - 1)))
  url_second_part=$(echo $result_storage_url | cut -c $((index_for_regex))-${#result_storage_url})
  new_storage_url="$url_first_part$regex_to_append$url_second_part"
  sudo azcopy copy $new_storage_url '/home/benchmarking/aggregation' --recursive=true
  sudo python3 /tmp/ycsb/ycsb-azurecosmos-binding-0.18.0-SNAPSHOT/aggregate_multiple_file_results.py /home/benchmarking/aggregation
  sudo azcopy copy aggregation.csv "$result_storage_url"
fi