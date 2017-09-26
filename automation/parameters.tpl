my_uid=$(uuidgen | cut -c1-6)

githubUser=$(git config --get remote.origin.url | cut -d'/' -f4)
githubBranch=$(git status | sed -n 's/[# ]*On branch \([^ ]\+\)/\1/p')

resource_group=tony-azhpc-${my_uid}
location="North Central US"
vmSku=Standard_H16r
vmssName=az${my_uid}
computeNodeImage=CentOS-HPC_7.1
instanceCount=16
rsaPublicKey=$(cat ~/.ssh/id_rsa.pub)

numberOfNodesToTest="8 16"
processesPerNode=16
podKey=

linpack_N=69120
linpack_P=1
linpack_Q=2
linpack_NB=192
linpack_Peak=691.2

azLogin=
azPassword=
azTenant=

rootLogDir='.'

logToStorage=true
logStorageAccountName=ninalogs
logStorageContainerName=results
logStoragePath=
logStorageSasKey="?sv=2016-05-31&si=write&sr=c&sig=6GmwqU6WAP9%2FsAuq5fAMo8kJqW3ZSNsYRoGFUECu728%3D"
cosmos_account=ninadb
cosmos_database=Nina
cosmos_collection=Results
cosmos_key=$(az keyvault secret show --name cosmoskey --vault-name NinaVault | jq '.value' -r)

# openfoam parameters
storageAccountName=paedwar
storageContainerName=azhpc
storageBenchmarkPath=benchmarks
storageBenchmarkName=motorbike82M
storageSasKey=
