#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$DIR/common.sh"

paramsFile=$1
echo "Reading parameters from: $paramsFile"
source $paramsFile
required_envvars githubUser githubBranch resource_group vmSku vmssName computeNodeImage instanceCount rsaPublicKey rootLogDir linpack_N linpack_P linpack_Q linpack_NB linpack_Peak
if [ "$logToStorage" = true ]; then
        required_envvars cosmos_account cosmos_database cosmos_collection cosmos_key logStorageAccountName logStorageContainerName logStoragePath logStorageSasKey
fi

benchmarkScript=$2
echo "Benchmark script: $benchmarkScript"
source $benchmarkScript

scriptname=$(basename "$0")
scriptname="${scriptname%.*}"
paramsname=$(basename "$paramsFile")
paramsname="${paramsname%.*}"
benchmarkname=$(basename "$benchmarkScript")
benchmarkname="${benchmarkname%.*}"
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
LOGDIR=$rootLogDir/${scriptname}_${paramsname}_${benchmarkname}_${timestamp}
mkdir $LOGDIR

# creating a new document with a unique id (intention to put in documentdb)
telemetryData="{ \"id\" : \"$(uuidgen)\" }"

function clear_up {
	execute "delete_resource_group" az group delete --name "$resource_group" --yes
        echo $telemetryData > $LOGDIR/telemetry.json
        if [ "$logToStorage" = true ]; then
                $DIR/cosmos_upload_doc.sh "$cosmos_account" "$cosmos_database" "$cosmos_collection" "$cosmos_key" "$telemetryData"
        fi
}

# assuming already logged in a the moment or use the Service Principal params
if [ "$azLogin" != "" ]; then
        echo "login to azure with Service Principal"
        az login --service-principal -u $azLogin -p $azPassword --tenant $azTenant
fi

# make sure the resource group does not exist
if [ "$(az group exists --name $resource_group)" = "true" ]; then
        echo "Error: Resource group already exists"
        exit 1
fi

# create the resource group
execute "create_resource_group" az group create --name "$resource_group" --location "$location"
subscriptionId=$(jq '.id' $(get_log "create_resource_group") | cut -d'/' -f3)
telemetryData="$(jq ".subscription=\"$subscriptionId\" | .location=\$data.location | .resourceGroup=\$data.name" --argjson data "$(<$(get_log "create_resource_group"))" <<< $telemetryData)"

parameters=$(cat << EOF
{
        "vmSku": {
                "value": "$vmSku"
        },
        "vmssName": {
                "value": "$vmssName"
        },
        "computeNodeImage": {
                "value": "$computeNodeImage"
        },
        "instanceCount": {
                "value": $instanceCount
        },
        "rsaPublicKey": {
                "value": "$rsaPublicKey"
        }
}
EOF
)

# deploy azhpc
execute "deploy_azhpc" az group deployment create \
    --resource-group "$resource_group" \
    --template-uri "https://raw.githubusercontent.com/$githubUser/azhpc/$githubBranch/azuredeploy.json" \
    --parameters "$parameters"

deploymentTime=$(grep deploy_azhpc $LOGDIR/times.csv | cut -d',' -f2)

telemetryData="$(jq '.vmSize=$data.properties.parameters.vmSku.value | .computeNodeImage=$data.properties.parameters.computeNodeImage.value | .instanceCount=$data.properties.parameters.instanceCount.value | .provisioningState=$data.properties.provisioningState | .deploymentTimestamp=$data.properties.timestamp | .correlationId=$data.properties.correlationId' --argjson data "$(<$(get_log "deploy_azhpc"))" <<< $telemetryData)"
telemetryData="$(jq '.deploymentDuration=$data' --arg data $deploymentTime <<< $telemetryData)"

public_ip=$(az network public-ip list --resource-group "$resource_group" --query [0].dnsSettings.fqdn | sed 's/"//g')

execute "get_hosts" ssh hpcuser@${public_ip} nmapForHosts
working_hosts=$(sed -n "s/.*sshin=\([^;]*\).*/\1/p" $(get_log "get_hosts"))
retry=1
while [ "$retry" -lt "6" -a "$working_hosts" -ne "$instanceCount" ]; do
        sleep 60
        execute "get_hosts_retry_$retry" ssh hpcuser@${public_ip} nmapForHosts
        working_hosts=$(sed -n "s/.*sshin=\([^;]*\).*/\1/p" $(get_log "get_hosts_retry_$retry"))
        let retry=$retry+1
done

telemetryData="$(jq ".clusterDeployment.sshretries=\"$retry\"" <<< $telemetryData)"

if [ "$working_hosts" -ne "$instanceCount" ]; then
        echo "Error: all hosts are not accessible with ssh."
        telemetryData="$(jq ".clusterDeployment.status=\"failed\"" <<< $telemetryData)"
        clear_up
        exit 1
fi
telemetryData="$(jq ".clusterDeployment.status=\"success\"" <<< $telemetryData)"

execute "show_bad_nodes" ssh hpcuser@${public_ip} testForBadNodes

# run the STREAM benchmark
execute "get_stream" ssh hpcuser@${public_ip} 'wget https://paedwar.blob.core.windows.net/public/stream.96GB && chmod +x stream.96GB'
execute "run_stream" ssh hpcuser@${public_ip} pdsh 'KMP_AFFINITY=scatter ./stream.96GB'
stream_results=$(cat $(get_log "run_stream") | jq -s -R 'split("\n") | map(select(contains("Triad"))) | map(split(" ") | map(select(. != ""))) | map({"hostname": .[0]|rtrimstr(":"),"triad":.[2]})')
telemetryData="$(jq '.stream.results=$data' --argjson data "$stream_results" <<< $telemetryData)"

# run the LINPACK benchmark
execute "get_linpack" ssh hpcuser@${public_ip} "wget 'https://pintaprod.blob.core.windows.net/private/hpl.tgz?sv=2016-05-31&si=read&sr=b&sig=5ZluFkKL%2F3GyNexDVQBB1sEmUdHpkutLlXaLfE%2BmUN4%3D' -q -O -  | tar zx --skip-old-files"
execute "run_linpack" ssh hpcuser@${public_ip} "pdsh 'cd hpl; mpirun -np 2 -perhost 2 ./xhpl_intel64_static -n $linpack_N -p $linpack_P -q $linpack_Q -nb $linpack_NB | grep WC00C2R2'"
linpack_results="$(cat $(get_log "run_linpack") | jq -s -R 'split("\n") | map(select(contains("WC00C2R2"))) | map(split(" ") | map(select(. != ""))) | map({"hostname": .[0]|rtrimstr(":"),"duration": .[6],"gflops": .[7]})')"
telemetryData="$(jq ".singlehpl.parameters={N:$linpack_N, P:$linpack_P, Q:$linpack_Q, NB:$linpack_NB, PeakGflops:$linpack_Peak}" <<< $telemetryData)"
telemetryData="$(jq '.singlehpl.results=$data' --argjson data "$linpack_results" <<< $telemetryData)"

# run the ring pingpong benchmark
execute "run_ring_pingpong" ssh hpcuser@${public_ip} 'ssh $(head -n1 bin/hostlist) ./azhpc/benchmarks/run_ring_pingpong.sh'
get_files '*_to_*_pingpong.log'
for i in $LOGDIR/*_to_*_pingpong.log; do
        src=$(echo ${i##*/} | cut -d'_' -f1)
        dst=$(echo ${i##*/} | cut -d'_' -f3)
        cat $LOGDIR/${src}_to_${dst}_pingpong.log | grep -A27 'Benchmarking PingPong' | tail -n24 | jq -s -R 'split("\n") | map(select(. != "")) | map(split(" ") | map(select(. != ""))) | map({"src":"'$src'","dst":"'$dst'","bytes":.[0],"repetitions":.[1],"t_usec":.[2],"Mbytes_sec":.[3]})' >$LOGDIR/${src}_to_${dst}_pingpong.json
done
ringpingpongData=$(jq -s add $LOGDIR/*_to_*_pingpong.json)
telemetryData="$(jq '.ringpingpong.results=$data' --argjson data "$ringpingpongData" <<< $telemetryData)"

# run the benchmark function
benchmarkData="{}"
run_benchmark

telemetryData="$(jq '.benchmark=$data' --argjson data "$benchmarkData" <<< $telemetryData)"

clear_up
