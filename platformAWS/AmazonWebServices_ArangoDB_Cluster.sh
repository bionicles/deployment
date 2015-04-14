# This starts multiple coreos instances using amazon web services and then
# starts an ArangoDB cluster on them.
#
# Use -r to permanently remove an existing cluster and all machine instances.
#
# Optional prerequisites:
# The following environment variables are used:
#
#   ZONE  : size of the server (e.g. -z europe-west1-b)
#   SIZE    : size/machine-type of the instance (e.g. -m n1-standard-2)
#   NUMBER  : count of machines to create (e.g. -n 3)
#   OUTPUT  : local output log folder (e.g. -d /my/directory)

trap "kill 0" SIGINT

ZONE="eu-central-1"

#CoreOS AWS Image List
#https://coreos.com/docs/running-coreos/cloud-providers/ec2/
IMAGE="ami-0e300d13"

MACHINE_TYPE="t1.medium"
NUMBER="3"
OUTPUT="aws"
PROJECT=""
SSH_KEY_PATH=""
DEFAULT_KEY_PATH="$HOME/.ssh/arangodb_aws_key"

function deleteMachine () {
  echo "deleting machine $PREFIX$1"
  id=${SERVERS_IDS[`expr $1 - 1`]}

  #TODO DELETE AWS
  ##gcloud compute instances delete "$id" --zone "$ZONE" -q
}

AmazonWebServicesDestroyMachines() {

    if [ ! -e "$OUTPUT" ] ;  then
      echo "$0: directory '$OUTPUT' not found"
      exit 1
    fi

    . $OUTPUT/clusterinfo.sh

    declare -a SERVERS_IDS_ARR=(${SERVERS_IDS[@]})

    NUMBER=${#SERVERS_IDS_ARR[@]}

    echo "NUMBER OF MACHINES: $NUMBER"
    echo "OUTPUT DIRECTORY: $OUTPUT"
    echo "MACHINE PREFIX: $PREFIX"

    #firewall TODO
    #gcloud compute firewall-rules delete "arangodb-test"

    for i in `seq $NUMBER`; do
      deleteMachine $i &
    done

    wait

    exit 0
}

REMOVE=0

while getopts ":z:m:n:d:s:hr" opt; do
  case $opt in
    h)
       cat <<EOT
This starts multiple coreos instances using amazon web services and then
starts an ArangoDB cluster on them.

Use -r to permanently remove an existing cluster and all machine instances.

Optional prerequisites:
The following environment variables are used:

  ZONE  : size of the server (e.g. -z europe-west1-b)
  SIZE    : size/machine-type of the instance (e.g. -m n1-standard-2)
  NUMBER  : count of machines to create (e.g. -n 3)
  OUTPUT  : local output log folder (e.g. -d /my/directory)
EOT
      ;;
    z)
      ZONE="$OPTARG"
      ;;
    m)
      MACHINE_TYPE="$OPTARG"
      ;;
    n)
      NUMBER="$OPTARG"
      ;;
    d)
      OUTPUT="$OPTARG"
      ;;
    s)
      SSH_KEY_PATH="$OPTARG"
      ;;
    r)
      REMOVE=1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

PREFIX="arangodb-test-$$-"

echo "OUTPUT DIRECTORY: $OUTPUT"
echo "ZONE: $ZONE"
echo "PROJECT: $PROJECT"

#check if project is already set
zone=`cat $HOME/.aws/config | grep region`

if test -z "$zone";  then
  echo "AWS zone is not configured. Please run: aws configure"
  exit 1
fi

if test -e "$OUTPUT";  then
  if [ "$REMOVE" == "1" ] ; then
    AmazonWebServicesDestroyMachines
    exit 0
  fi

  echo "$0: refusing to use existing directory '$OUTPUT'"
  exit 1
fi

if [ "$REMOVE" == "1" ] ; then
  echo "$0: did not find an existing directory '$OUTPUT'"
  exit 1
fi

echo "MACHINE_TYPE: $MACHINE_TYPE"
echo "NUMBER OF MACHINES: $NUMBER"
echo "MACHINE PREFIX: $PREFIX"

mkdir -p "$OUTPUT/temp"

if [[ -s "$HOME/.ssh/arangodb_aws_key" ]] ; then
  echo "AWS SSH-Key existing."
else
  echo "No AWS SSH-Key existing. Creating a new SSH-Key."

  aws ec2 create-key-pair --key-name "arangodb_aws_key" --output text > arangodb_aws_key

  if [ $? -eq 0 ]; then
    echo OK
  else
    echo Failed to create SSH-Key. Exiting.
    exit 1
  fi

  cp "$OUTPUT/arangodb_aws_key"* "$HOME/.ssh/"
fi ;

#check if ssh agent is running
if [ -n "${SSH_AUTH_SOCK}" ]; then
    echo "SSH-Agent is running."

    #check if key already added to ssh agent
    if ssh-add -l | grep $DEFAULT_KEY_PATH > /dev/null ; then
      echo SSH-Key already added to SSH-Agent;
    else
      ssh-add "$DEFAULT_KEY_PATH"
    fi

  else
    echo "No SSH-Agent running. Skipping."
fi

#FIREWALL TODO
#add firewall rule for arangodb-test tag
#gcloud compute firewall-rules create "arangodb-test" --allow tcp:8529 --target-tags "arangodb-test"
function getMachine () {
  currentid=`cat $OUTPUT/temp/IDS$1`
  aws ec2 describe-instances --instance-ids $currentid
  public=`aws ec2 describe-instances --instance-ids $currentid | grep PublicIpAddress | awk '{print $2}' | cut -c 2- | rev | cut -c 3- | rev`

  state=0
  while [ "$state" == 0 ]; do
    if test -z "$public";  then
     echo "Machine $PREFIX$1 not ready yet."
     sleep 3
    else
     echo "Machine $PREFIX$1 ready."
     state=1
    fi
  done

  echo $public > "$OUTPUT/temp/EXTERNAL$1"
}

function createMachine () {
  echo "creating machine $PREFIX$1"

  INSTANCE=`aws ec2 run-instances --image-id "$IMAGE" --count 1 --instance-type t2.medium \
  --key-name "arangodb_aws_key" --associate-public-ip-address`

  id=`echo $INSTANCE | python -mjson.tool | grep InstanceId | awk '{print $2}' | cut -c 2- | rev | cut -c 3- | rev`
  priv=`echo $INSTANCE | python -mjson.tool | grep PrivateIpAddress | awk '{print $2}' | head -n 1 | cut -c 2- | rev | cut -c 3- | rev`

  echo $priv > "$OUTPUT/temp/INTERNAL$1"
  echo $id > "$OUTPUT/temp/IDS$1"
}

#CoreOS PARAMS
declare -a SERVERS_EXTERNAL_AWS
declare -a SERVERS_INTERNAL_AWS
declare -a SERVERS_IDS_AWS

SSH_USER="core"
SSH_CMD="ssh"

for i in `seq $NUMBER`; do
  createMachine $i &
done

wait

sleep 5

for i in `seq $NUMBER`; do
  getMachine $i &
done

wait

exit 0

while :
do

  FINISHED=0

  for i in `seq $NUMBER`; do

    if [ -s "$OUTPUT/temp/INTERNAL$i" ] ; then
      echo "Machine $PREFIX$i finished"
      SERVERS_INTERNAL_AWS[`expr $i - 1`]=`cat "$OUTPUT/temp/INTERNAL$i"`
      SERVERS_EXTERNAL_AWS[`expr $i - 1`]=`cat "$OUTPUT/temp/EXTERNAL$i"`
      SERVERS_IDS_AWS[`expr $i - 1`]=$PREFIX$i
      FINISHED=1
    else
      echo "Machine $PREFIX$i not ready yet."
      FINISHED=0
      break
    fi

  done

  if [ $FINISHED == 1 ] ; then
    echo "All machines are set up"
    break
  fi

  sleep 1

done

rm -rf $OUTPUT/temp

echo Internal IPs: ${SERVERS_INTERNAL_AWS[@]}
echo External IPs: ${SERVERS_EXTERNAL_AWS[@]}
echo IDs         : ${SERVERS_IDS_AWS[@]}

SERVERS_INTERNAL="${SERVERS_INTERNAL_AWS[@]}"
SERVERS_EXTERNAL="${SERVERS_EXTERNAL_AWS[@]}"
SERVERS_IDS="${SERVERS_IDS_AWS[@]}"

# Write data to file:
echo > $OUTPUT/clusterinfo.sh "SERVERS_INTERNAL=\"$SERVERS_INTERNAL\""
echo >>$OUTPUT/clusterinfo.sh "SERVERS_EXTERNAL=\"$SERVERS_EXTERNAL\""
echo >>$OUTPUT/clusterinfo.sh "SERVERS_IDS=\"$SERVERS_IDS\""
echo >>$OUTPUT/clusterinfo.sh "SSH_USER=\"$SSH_USER\""
echo >>$OUTPUT/clusterinfo.sh "SSH_CMD=\"$SSH_CMD\""
echo >>$OUTPUT/clusterinfo.sh "SSH_SUFFIX=\"$SSH_SUFFIX\""
echo >>$OUTPUT/clusterinfo.sh "PREFIX=\"$PREFIX\""
echo >>$OUTPUT/clusterinfo.sh "ZONE=\"$ZONE\""

# Export needed variables
export SERVERS_INTERNAL
export SERVERS_EXTERNAL
export SERVERS_IDS
export SSH_USER="core"
export SSH_CMD="ssh"
export SSH_SUFFIX="-i $DEFAULT_KEY_PATH -l $SSH_USER"
export ZONE

sleep 5

startArangoDBClusterWithDocker