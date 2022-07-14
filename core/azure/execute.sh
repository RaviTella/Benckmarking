#!/bin/sh

cloud-init status --wait

echo "##########DEPLOYMENT_NAME###########: $DEPLOYMENT_NAME"
echo "##########VM NAME###########: $VM_NAME"
echo "##########YCSB_RECORD_COUNT###########: $YCSB_RECORD_COUNT"
echo "##########MACHINE_INDEX###########: $MACHINE_INDEX"
echo "##########YCSB_OPERATION_COUNT###########: $YCSB_OPERATION_COUNT"
echo "##########VM_COUNT###########: $VM_COUNT"
echo "##########WRITE_ONLY_OPERATION###########: $WRITE_ONLY_OPERATION"

echo "##########TEST_BENCH_GIT_BRANCH_NAME###########: $TEST_BENCH_GIT_BRANCH_NAME"
echo "##########TEST_BENCH_GIT_REPO_URL###########: $TEST_BENCH_GIT_REPO_URL"
echo "##########YCSB_GIT_BRANCH_NAME###########: $YCSB_GIT_BRANCH_NAME"
echo "##########YCSB_GIT_REPO_URL###########: $YCSB_GIT_REPO_URL"

# The index of the record to start at during the Load
insertstart=$((YCSB_RECORD_COUNT * (MACHINE_INDEX - 1)))
# Records already in the DB + records to be added, during load
recordcount=$((YCSB_RECORD_COUNT * MACHINE_INDEX))
# Record count for Run. Since we run read workload after load this is the total number of records loaded by all VMs/clients during load.
totalrecordcount=$((YCSB_RECORD_COUNT * VM_COUNT))


#Install Software
echo "########## Installing azcopy ###########"
wget https://aka.ms/downloadazcopy-v10-linux
tar -xvf downloadazcopy-v10-linux
sudo cp ./azcopy_linux_amd64_*/azcopy /usr/bin/

#Cloning Test Bench Repo
echo "########## Cloning Test Bench repository ##########"
git clone -b "$TEST_BENCH_GIT_BRANCH_NAME" --single-branch "$TEST_BENCH_GIT_REPO_URL"
mkdir /tmp/ycsb
cp -r ./Benckmarking/core/azure/* /tmp/ycsb
cp -r ./Benckmarking/core/data/* /tmp/ycsb

#Build YCSB from source
echo "########## Cloning YCSB repository ##########"
git clone -b "$YCSB_GIT_BRANCH_NAME" --single-branch "$YCSB_GIT_REPO_URL"

echo "########## Building YCSB ##########"
cd YCSB
mvn -pl site.ycsb:azurecosmos-binding -am clean package
cp -r ./azurecosmos/target/ycsb-azurecosmos-binding*.tar.gz /tmp/ycsb
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
  az storage entity insert --entity PartitionKey="ycsb_sql" RowKey="${GUID}" ClientStartTime=$client_start_time SAS_URL=$result_storage_url JobStatus="Started" NoOfClientsCompleted=0 --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING
else
  for i in $(seq 1 5); do
    table_entry=$(az storage entity show --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING --partition-key "ycsb_sql" --row-key "${GUID}")
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

  ## Removing quotes from the client_start_time and result_storage_url retrieved from table
  client_start_time=${client_start_time:1:-1}
  result_storage_url=${result_storage_url:1:-1}
fi
## converting client_start_time into seconds
client_start_time=$(date -d "$client_start_time" +'%s')

#Execute YCSB test
if [ "$WRITE_ONLY_OPERATION" = True ] || [ "$WRITE_ONLY_OPERATION" = true ]; then
  now=$(date +"%s")
  wait_interval=$(($client_start_time - $now))
  if [ $wait_interval -gt 0 ]; then
    echo "Sleeping for $wait_interval second to sync with other clients"
    sleep $wait_interval
  else
    echo "Not sleeping on clients sync time $client_start_time as it already past"
  fi
  ## Records count for write only ops which start with items count created by previous(machine_index -1) client machine
  recordcountForWriteOps=$((YCSB_OPERATION_COUNT * MACHINE_INDEX ))
  ## Execute run phase for YCSB tests with write only workload
  echo "########## Run operation with write only workload for YCSB tests ###########"
  uri=$COSMOS_URI primaryKey=$COSMOS_KEY workload_type=$WORKLOAD_TYPE ycsb_operation="run" insertproportion=1 readproportion=0 updateproportion=0 scanproportion=0 recordcount=$recordcountForWriteOps operationcount=$YCSB_OPERATION_COUNT threads=$THREAD_COUNT target=$TARGET_OPERATIONS_PER_SECOND diagnosticsLatencyThresholdInMS=$DIAGNOSTICS_LATENCY_THRESHOLD_IN_MS requestdistribution=$REQUEST_DISTRIBUTION insertorder=$INSERT_ORDER sh run.sh
else
  ## Execute load operation for YCSB tests
  echo "########## Load operation for YCSB tests ###########"
  uri=$COSMOS_URI primaryKey=$COSMOS_KEY workload_type=$WORKLOAD_TYPE ycsb_operation="load" recordcount=$recordcount insertstart=$insertstart insertcount=$YCSB_RECORD_COUNT threads=$THREAD_COUNT target=$TARGET_OPERATIONS_PER_SECOND diagnosticsLatencyThresholdInMS=$DIAGNOSTICS_LATENCY_THRESHOLD_IN_MS requestdistribution=$REQUEST_DISTRIBUTION insertorder=$INSERT_ORDER sh run.sh

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
  ## Execute run phase for YCSB tests
  echo "########## Run operation for YCSB tests ###########"
  uri=$COSMOS_URI primaryKey=$COSMOS_KEY workload_type=$WORKLOAD_TYPE ycsb_operation="run" recordcount=$totalrecordcount operationcount=$YCSB_OPERATION_COUNT threads=$THREAD_COUNT target=$TARGET_OPERATIONS_PER_SECOND insertproportion=$INSERT_PROPORTION readproportion=$READ_PROPORTION updateproportion=$UPDATE_PROPORTION scanproportion=$SCAN_PROPORTION diagnosticsLatencyThresholdInMS=$DIAGNOSTICS_LATENCY_THRESHOLD_IN_MS requestdistribution=$REQUEST_DISTRIBUTION insertorder=$INSERT_ORDER sh run.sh
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

  #Updating table entry to change JobStatus to 'Finished' and increment NoOfClientsCompleted
  echo "Reading latest table entry"
  latest_table_entry=$(az storage entity show --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING --partition-key "ycsb_sql" --row-key "${GUID}")
  etag=$(echo $latest_table_entry | jq .etag)
  etag=${etag:1:-1}
  etag=$(echo "$etag" | tr -d '\')
  no_of_clients_completed=$(echo $latest_table_entry | jq .NoOfClientsCompleted)
  no_of_clients_completed=$(echo "$no_of_clients_completed" | tr -d '"')
  no_of_clients_completed=$((no_of_clients_completed + 1))
  echo "Updating latest table entry with incremented NoOfClientsCompleted"
  az storage entity merge --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING --entity PartitionKey="ycsb_sql" RowKey="${GUID}" JobStatus="Finished" NoOfClientsCompleted=$no_of_clients_completed --if-match=$etag
else
  for j in $(seq 1 60); do
    echo "Reading latest table entry"
    latest_table_entry=$(az storage entity show --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING --partition-key "ycsb_sql" --row-key "${GUID}")
    etag=$(echo $latest_table_entry | jq .etag)
    etag=${etag:1:-1}
    etag=$(echo "$etag" | tr -d '\')
    no_of_clients_completed=$(echo $latest_table_entry | jq .NoOfClientsCompleted)
    no_of_clients_completed=$(echo "$no_of_clients_completed" | tr -d '"')
    no_of_clients_completed=$((no_of_clients_completed + 1))
    echo "Updating latest table entry with incremented NoOfClientsCompleted"
    replace_entry_result=$(az storage entity merge --table-name "${DEPLOYMENT_NAME}Metadata" --connection-string $RESULT_STORAGE_CONNECTION_STRING --entity PartitionKey="ycsb_sql" RowKey="${GUID}" NoOfClientsCompleted=$no_of_clients_completed --if-match=$etag)
    if [ -z "$replace_entry_result" ]; then
      echo "Hit race condition on table entry for updating no_of_clients_completed"
      sleep 1s
    else
      break
    fi
  done
fi