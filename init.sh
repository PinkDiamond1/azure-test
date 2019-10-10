#!/usr/bin/env bash

function fail {
  echo "$1" >&2
  exit 1
}

# install utils
apt-get update > /dev/null
apt-get install -y jq software-properties-common > /dev/null
add-apt-repository -y ppa:certbot/certbot
apt-get install -y certbot

# read script parameters
export CONFIG=$1
export IP=$2
export FQDN=$3

[[ -z "$CONFIG" ]] && fail "no configuration was provided"
[[ -z "$IP" ]] && fail "no ip address was provided"
[[ -z "$FQDN" ]] && fail "no fqdn was provided"

export CONFIG_FILE=/root/config.json 
echo "$CONFIG" | base64 -d > $CONFIG_FILE

# read configuration into env-vars
export CHAIN_NAME=$(jq -r ."chain_name // empty" $CONFIG_FILE)
export SEED_NODE_URL=$(jq -r ."seed_node // empty" $CONFIG_FILE)
export EMAIL=$(jq -r ."email // empty" $CONFIG_FILE)
export CREATE_PARAMETERS=$(jq -r ."create_parameters // empty" $CONFIG_FILE)
export RUNTIME_FLAGS=$(jq -r ."runtime_flags // empty" $CONFIG_FILE)

[[ -z "$CHAIN_NAME" ]] && fail "no chain name was provided"

# add seed node to connect string if set
export CONNECT_STRING="$CHAIN_NAME"
[[ -n "$SEED_NODE_URL" ]] && export CONNECT_STRING="${CHAIN_NAME}@${SEED_NODE_URL}"

# set additional variables
export EXTERNAL="-externalip=$IP"
export BASIC_AUTH_USER=multichain
export BASIC_AUTH_PASSWORD=$(cat /dev/urandom | tr -dc a-zA-Z0-9 | fold -w 64 | head -n 1)
export OS_USER=multichain
export OS_GROUP=multichain
export OS_USER_HOME=/home/${OS_USER}

export MC_RPC_PORT=7999
export MC_P2P_PORT=7000
export MC_LOCAL_RPC=http://127.0.0.1:$MC_RPC_PORT
export MC_P2P_ENDPOINT=${CHAIN_NAME}@${IP}:${MC_P2P_PORT}
export MC_DOWNLOAD_URL=https://www.multichain.com/download/multichain-2.0-latest.tar.gz

export MC_START_SCRIPT=$OS_USER_HOME/start.sh
export MC_INSTALL_SCRIPT=/root/multichain-2.0-latest-download-install.sh
export MC_DIAGNOSTIC_SCRIPT=$OS_USER_HOME/diagnostics.sh
export MC_LOG_SCRIPT=$OS_USER_HOME/getdebuglog.sh
export MC_SERVICE=/lib/systemd/system/multichain.service

export CERTBOT_FLAG="--register-unsafely-without-email"
[[ -n "$EMAIL" ]] && export CERTBOT_FLAG="-m ${EMAIL}"

export NGINX_PORT=443
export SSL_CERT=/etc/letsencrypt/live/${FQDN}/fullchain.pem;
export SSL_KEY=/etc/letsencrypt/live/${FQDN}/privkey.pem;
export NGINX_HTPASSWD=/etc/nginx/htpasswd
export NGINX_CONFIG=/etc/nginx/nginx.conf
export NGINX_SERVICE=/lib/systemd/system/nginx.service
export NGINX_RELOAD_SCRIPT=/etc/letsencrypt/renewal-hooks/deploy/reload_nginx.sh

export DASHBOARD_PHP=https://raw.githubusercontent.com/MultiChain/azure-test/master/index.php

# create script to download and install latest multichain 2.0
cat <<EOF >$MC_INSTALL_SCRIPT
cd /tmp
rm -fr multichain*
wget -q -O multichain.tar.gz '$MC_DOWNLOAD_URL'
while [ $? -ne 0 ]; do
  sleep 5
  wget -q -O multichain.tar.gz '$MC_DOWNLOAD_URL'
done
tar -xvzf multichain.tar.gz
cd multichain-*
mv multichaind multichain-cli multichain-util /usr/local/bin
cd ..
rm -rf multichain*
EOF

# run the script to download and install latest multichain 2.0
chmod 700 $MC_INSTALL_SCRIPT
$MC_INSTALL_SCRIPT

# retrieve certificate using letsencrypt certbot
certbot certonly --agree-tos $CERTBOT_FLAG --domain $FQDN --standalone

# install and configure nginx as reverse proxy
apt-get install -y nginx php-fpm > /dev/null

# basic auth
echo -n "${BASIC_AUTH_USER}:" > $NGINX_HTPASSWD
echo "${BASIC_AUTH_PASSWORD}" | openssl passwd -apr1 -stdin >> $NGINX_HTPASSWD

# nginx config
cat <<EOF > $NGINX_CONFIG
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
  worker_connections 512;
}

http {
  server {
    listen 443 ssl;
    server_name ${FQDN};
  
    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
  
    location /rpc {
      proxy_pass ${MC_LOCAL_RPC}/;
    }
  
    location /dashboard {
      auth_basic "Login";
      auth_basic_user_file ${NGINX_HTPASSWD};
  
      alias /var/www/html;
      index index.php;
  
      location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$request_filename;
        fastcgi_pass unix:/var/run/php/php7.2-fpm.sock;
      }
    }
  }
  
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 10m;
  ssl_protocols TLSv1.2;
  ssl_prefer_server_ciphers on;
  
  keepalive_timeout 60;
  
  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log;
}
EOF
systemctl restart nginx

# make nginx robust and directly restart it if stopped / killed
if [[ -f $NGINX_SERVICE ]]
then
    if [[ ! $(grep -i "Restart=" $NGINX_SERVICE) ]]
    then
        sed -i '/\[Service\]/a Restart=always' $NGINX_SERVICE
        systemctl daemon-reload
    fi
fi

# this will be executed when new letsencrypt certificate arives
cat <<EOF > $NGINX_RELOAD_SCRIPT
#!/usr/bin/env /bin/bash
systemctl reload nginx
EOF
chmod 770 $NGINX_RELOAD_SCRIPT

# if seed node was zero, create a new network on behalf of the user
[[ -z $SEED_NODE_URL ]] && su - -c "multichain-util create $CHAIN_NAME $CREATE_PARAMETERS" ${OS_USER}

# create a start script
cat <<EOF > $MC_START_SCRIPT
#!/usr/bin/env /bin/bash
multichaind -daemon -retryinittime=30000000 -rpcport=${MC_RPC_PORT} -port=${MC_P2P_PORT} $EXTERNAL -rpcuser=$BASIC_AUTH_USER -rpcpassword=$BASIC_AUTH_PASSWORD $RUNTIME_FLAGS $CONNECT_STRING
EOF
chown ${OS_USER}:${OS_GROUP} $MC_START_SCRIPT
chmod 700 $MC_START_SCRIPT

# configure multichain as systemd service for automatic crash restart
cat <<EOF > $MC_SERVICE
[Unit]
Description=MultiChain

[Service]
Type=forking
User=${OS_USER}
WorkingDirectory=$OS_USER_HOME
ExecStart=$MC_START_SCRIPT

Restart=always
RestartSec=10
TimeoutStopSec=20

KillMode=mixed
KillSignal=SIGTERM
SendSIGKILL=yes
FinalKillSignal=SIGKILL

[Install]
WantedBy=multi-user.target
EOF

systemctl enable multichain
systemctl start multichain


apt-get install -y sysstat > /dev/null

# create script to run diagnostic commands
cat <<EOF >$MC_DIAGNOSTIC_SCRIPT
echo 'getinfo >>>>>'
curl -k -u${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD} --data-binary '{"method":"getinfo"}' '$MC_LOCAL_RPC'
echo '<<<<< getinfo | getblockchainparams >>>>>'
curl -k -u${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD} --data-binary '{"method":"getblockchainparams"}' '$MC_LOCAL_RPC'
echo '<<<<< getblockchainparams | getmempoolinfo >>>>>'
curl -k -u${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD} --data-binary '{"method":"getmempoolinfo"}' '$MC_LOCAL_RPC'
echo '<<<<< getmempoolinfo | getwalletinfo >>>>>'
curl -k -u${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD} --data-binary '{"method":"getwalletinfo"}' '$MC_LOCAL_RPC'
echo '<<<<< getwalletinfo | listblocks >>>>>'
curl -k -u${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD} --data-binary '{"method":"listblocks","params":[-1, true]}' '$MC_LOCAL_RPC'
echo '<<<<< listblocks | getpeerinfo >>>>>'
curl -k -u${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD} --data-binary '{"method":"getpeerinfo"}' '$MC_LOCAL_RPC'
echo '<<<<< getpeerinfo'
EOF

# create script to get debug log lines
cat <<EOF >$MC_LOG_SCRIPT
tail -n 10000 $OS_USER_HOME/.multichain/$CHAIN_NAME/debug.log
EOF

# set ownership and permissions for nginx-accessible scripts
chown ${OS_USER}:${OS_GROUP} $MC_DIAGNOSTIC_SCRIPT $MC_LOG_SCRIPT
chmod 700 $MC_DIAGNOSTIC_SCRIPT $MC_LOG_SCRIPT

# allow nginx user to run specific scripts
cat <<EOF >/etc/sudoers.d/www-data-multichain
www-data ALL=(${OS_USER}) NOPASSWD:$MC_DIAGNOSTIC_SCRIPT
www-data ALL=(${OS_USER}) NOPASSWD:$MC_LOG_SCRIPT
EOF

# install monitoring page
rm -rf /var/www/html/*
wget -q -O /var/www/html/index.php $DASHBOARD_PHP

echo "#rpcaddr#https://${FQDN}/rpc#rpcaddr#"
echo "#dashboard#https://${FQDN}/dashboard#dashboard#"
echo "#p2paddr#${MC_P2P_ENDPOINT}#p2paddr#"
echo "#rpcuser#${BASIC_AUTH_USER}#rpcuser#"
echo "#rpcpassword#${BASIC_AUTH_PASSWORD}#rpcpassword#"
