#!/usr/bin/env bash

# install multichain
cd /tmp
wget -q -O multichain.tar.gz 'https://www.multichain.com/download/multichain-2.0.3.tar.gz'
while [ $? -ne 0 ]; do
  sleep 5
  wget -q -O multichain.tar.gz 'https://www.multichain.com/download/multichain-2.0.3.tar.gz'
done

tar -xvzf multichain.tar.gz
cd multichain-*
mv multichaind multichain-cli multichain-util /usr/local/bin
cd ..
rm -rf multichain*

# install utils
apt-get update -y > /dev/null
apt-get install -y jq > /dev/null

# configure automatic start on reboot
cat <<EOF > /etc/rc.local
#!/usr/bin/env bash
su - -c 'nohup /home/multichain/start.sh &' multichain
exit 0
EOF
chmod +x /etc/rc.local

cd /home/multichain

# check if we are already setup
if [[ -f start.sh ]]
then
    su - -c 'nohup ./start.sh &' multichain
    exit
fi

# decode config and write to file
if [[ -z $1 ]]
then
    echo "{}" > config.json
else
    echo "$1" | base64 -d > config.json
fi

chown multichain:multichain config.json

# read configuration into env-vars
export CHAIN_NAME=$(jq -r ."chain_name" config.json)
export SEED_NODE_URL=$(jq -r ."seed_node" config.json)
export RPC_USER=$(jq -r ."rpc_user" config.json)
export RPC_PASSWORD=$(jq -r ."rpc_password" config.json)
export CREATE_PARAMETERS=$(jq -r ."create_parameters" config.json)
export RUNTIME_FLAGS=$(jq -r ."runtime_flags" config.json)

# set default chain name if not set
if [[ -z $CHAIN_NAME ]]
then
    export CHAIN_NAME="mychain"
fi

# if seed node is set, generate node url
if [[ ! -z $SEED_NODE_URL ]]
then
    export CHAIN_NAME="${CHAIN_NAME}@${SEED_NODE_URL}"
fi

# if ip address is given, create commandline flag
export EXTERNAL=""
if [[ ! -z $2 ]]
then
    export EXTERNAL="-externalip=$2"
fi

cat <<EOF > req.conf
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
C = DE
ST = BW
L = Walldorf
O = SAP SE
OU = ICN Blockchain
CN = $CHAIN_NAME
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
IP.1 = $2
EOF

openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -config req.conf

chmod 600 cert.pem key.pem req.conf
chown multichain:multichain cert.pem key.pem req.conf

# if seed node was zero, create a new network
if [[ -z $SEED_NODE_URL ]]
then
    su - -c "multichain-util create $CHAIN_NAME $CREATE_PARAMETERS" multichain
fi

# create a start script, do not use -daemon here!
cat <<EOF > start.sh
while :
do
multichaind -retryinittime=30000000 -rpcssl -rpcsslcertificatechainfile=/home/multichain/cert.pem -rpcsslprivatekeyfile=/home/multichain/key.pem -rpcport=8000 -port=7000 $EXTERNAL -rpcuser=$RPC_USER -rpcpassword=$RPC_PASSWORD -rpcallowip=0.0.0.0/0 $RUNTIME_FLAGS $CHAIN_NAME
sleep 5
done
EOF

PUB_CERT=$(base64 -w0 cert.pem)

echo "#certificate#${PUB_CERT}#certificate#"


chown multichain:multichain start.sh
chmod 700 start.sh

# run start script loop
su - -c 'nohup ./start.sh &' multichain
