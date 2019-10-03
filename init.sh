#!/usr/bin/env bash

# create script to download and install latest multichain 2.0
cat <<EOF >/root/multichain-2.0-latest-download-install.sh
cd /tmp
rm -fr multichain*
wget -q 'https://www.multichain.com/download/multichain-2.0-latest.tar.gz'
while [ $? -ne 0 ]; do
  sleep 5
  wget -q 'https://www.multichain.com/download/multichain-2.0-latest.tar.gz'
done
tar -xvzf multichain-2.0-latest.tar.gz
cd multichain-*
mv multichaind multichain-cli multichain-util /usr/local/bin
cd ..
rm -rf multichain*
EOF

chmod u+x /root/multichain-2.0-latest-download-install.sh

# run the script to download and install latest multichain 2.0
/root/multichain-2.0-latest-download-install.sh

# install required utilities, Apache, PHP
apt-get update -y > /dev/null
apt-get install -y jq > /dev/null
apt-get install -y apache2 > /dev/null
apt-get install -y php > /dev/null
apt-get install -y sysstat > /dev/null

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

chown multichain:multichain start.sh
chmod 700 start.sh

# create script to run diagnostic commands
cat <<EOF >diagnostics.sh
multichain-cli -datadir=/home/multichain/.multichain/$CHAIN_NAME/ -requestout=null -rpcport=8000 -rpcuser=$RPC_USER -rpcpassword=$RPC_PASSWORD chain1 getinfo
echo '<<<<< getinfo'
multichain-cli -datadir=/home/multichain/.multichain/$CHAIN_NAME/ -requestout=null -rpcport=8000 -rpcuser=$RPC_USER -rpcpassword=$RPC_PASSWORD chain1 getmempoolinfo
echo '<<<<< getmempoolinfo'
multichain-cli -datadir=/home/multichain/.multichain/$CHAIN_NAME/ -requestout=null -rpcport=8000 -rpcuser=$RPC_USER -rpcpassword=$RPC_PASSWORD chain1 getwalletinfo
echo '<<<<< getwalletinfo'
multichain-cli -datadir=/home/multichain/.multichain/$CHAIN_NAME/ -requestout=null -rpcport=8000 -rpcuser=$RPC_USER -rpcpassword=$RPC_PASSWORD chain1 getpeerinfo
echo '<<<<< getpeerinfo'
EOF

chown multichain:multichain diagnostics.sh
chmod 700 diagnostics.sh

#allow Apache user to get diagnostics
cat <<EOF >/etc/sudoers.d/www-data-multichain
www-data ALL=(multichain) NOPASSWD:/home/multichain/diagnostics.sh
EOF

PUB_CERT=$(base64 -w0 cert.pem)

echo "#certificate#${PUB_CERT}#certificate#"

# install monitoring page (unprotected for now)
rm /var/www/html/index.html
wget -q -O /var/www/html/index.php https://raw.githubusercontent.com/MultiChain/azure-test/master/index.php

# run start script loop
su - -c 'nohup ./start.sh &' multichain
