#!/bin/sh
#echo "########## Sleeping to wait for Automatic Upgrades complete ###########"
#sleep 180
#echo "########## Awoke! Ready to procees with the Script ###########"

cloud-init status --wait

echo "##########Storage SAS###########: $RESULT_STORAGE_URL"
echo "##########VM Name###########: $VM_NAME"
echo "##########ITEM_COUNT_FOR_WRITE###########: $ITEM_COUNT_FOR_WRITE"
echo "##########MACHINE_INDEX###########: $MACHINE_INDEX"
echo "##########YCSB_OPERATION_COUNT###########: $YCSB_OPERATION_COUNT"
echo "##########VM_COUNT###########: $VM_COUNT"

# ITEM_COUNT_FOR_WRITE is number of records to insert by each VM/client during load phase


#The index of the record to start at during the Load
insertstart=$((ITEM_COUNT_FOR_WRITE* (MACHINE_INDEX-1)))
#Record cound for Load
recordcount=$((ITEM_COUNT_FOR_WRITE* MACHINE_INDEX))
# Record count for Run. Since we run read workload after load this is the total number of records loaded by all VMs/clients in the load phase.
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
cd  YCSB
mvn -pl site.ycsb:azurecosmos-binding -am clean package
cp -r  ./azurecosmos/target/ /tmp/ycsb
cp -r ./azurecosmos/conf/* /tmp/ycsb
cd /tmp/ycsb/

echo "########## Extracting YCSB ##########"
tar xfvz ycsb-azurecosmos-binding-0.18.0-SNAPSHOT.tar.gz
cp ./run.sh ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cp ./azurecosmos.properties ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cp ./aggregate_multiple_file_results.py ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cp ./converting_log_to_csv.py ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT
cd ./ycsb-azurecosmos-binding-0.18.0-SNAPSHOT


##Load operation for YCSB tests
echo "########## Load operation for YCSB tests ###########"
uri=$COSMOS_URI primaryKey=$COSMOS_KEY workload_type=$WORKLOAD_TYPE ycsb_operation="load" recordcount=$recordcount insertstart=$insertstart insertcount=$ITEM_COUNT_FOR_WRITE threads=$THREAD_COUNT target=$TARGET_OPERATIONS_PER_SECOND sh run.sh

#Execute YCSB test
if [ "$YCSB_OPERATION" = "run" ]; then
  cp /tmp/ycsb.log /home/benchmarking/"$VM_NAME-ycsb-load.txt"
  sudo azcopy copy /home/benchmarking/"$VM_NAME-ycsb-load.txt" "$RESULT_STORAGE_URL"
  # Clearing log file from above load operation  
  sudo rm -f /tmp/ycsb.log
  sudo rm -f "/home/benchmarking/$VM_NAME-ycsb-load.txt"
  # Waiting for 2 minutes, so all the VMs load phase finished before we start run operation 
  sleep 2m
  uri=$COSMOS_URI primaryKey=$COSMOS_KEY workload_type=$WORKLOAD_TYPE ycsb_operation=$YCSB_OPERATION recordcount=$totalrecordcount operationcount=$YCSB_OPERATION_COUNT threads=$THREAD_COUNT target=$TARGET_OPERATIONS_PER_SECOND sh run.sh
fi

#Copy YCSB log to storage account 
echo "########## Copying Results to Storage ###########"
cp /tmp/ycsb.log /home/benchmarking/"$VM_NAME-ycsb.log"
sudo python3 converting_log_to_csv.py /home/benchmarking/"$VM_NAME-ycsb.log"
sudo azcopy copy "$VM_NAME-ycsb.csv" "$RESULT_STORAGE_URL"
sudo azcopy copy "/home/benchmarking/$VM_NAME-ycsb.log" "$RESULT_STORAGE_URL"

if [ $MACHINE_INDEX -eq 1 ]; then
  echo "Waiting on VM1 for 5 min"
  sleep 5m
  cd /home/benchmarking
  mkdir "aggregation"
  cd aggregation
  index_for_regex=`expr index "$RESULT_STORAGE_URL" '?'`
  regex_to_append="/*"
  url_first_part=$(echo $RESULT_STORAGE_URL| cut -c 1-$((index_for_regex-1)))
  url_second_part=$(echo $RESULT_STORAGE_URL| cut -c $((index_for_regex))-${#RESULT_STORAGE_URL})
  new_storage_url="$url_first_part$regex_to_append$url_second_part"
  sudo azcopy copy $new_storage_url '/home/benchmarking/aggregation' --recursive=true
  sudo python3 /tmp/ycsb/ycsb-azurecosmos-binding-0.18.0-SNAPSHOT/aggregate_multiple_file_results.py /home/benchmarking/aggregation
  sudo azcopy copy aggregation.csv "$RESULT_STORAGE_URL"
fi
