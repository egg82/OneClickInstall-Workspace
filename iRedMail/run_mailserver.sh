#!/bin/bash

NGINX_LOG_DIR="/var/log/nginx"
TMP_SQL="/tmp/cluebringer_init_sql.${RANDOM}${RANDOM}"
HOSTNAME="$(hostname -f)"

IP_ADDRESS=""
RETRY_COUNT=3
SUCCESS=false

for i in $(seq 1 $RETRY_COUNT); do
    if ping -c 1 -W 5 resolver1.opendns.com &> /dev/null; then
        SUCCESS=true
        break
    else
        sleep 2 # Wait for 2 seconds before retrying
    fi
done

if $SUCCESS; then
    # If resolver1.opendns.com is reachable, get both internal and external IP addresses
    IP_ADDRESS="$(hostname -i && dig +short myip.opendns.com @resolver1.opendns.com)"
else
    # If resolver1.opendns.com is not reachable, get only the internal IP address
    IP_ADDRESS="$(hostname -i)"
fi

tmprootdir="$(dirname $0)"
echo ${tmprootdir} | grep '^/' >/dev/null 2>&1
if [ X"$?" == X"0" ]; then
    ROOTDIR="${tmprootdir}"
else
    ROOTDIR="$(pwd)"
fi

cd ${ROOTDIR}

export CONF_DIR="${ROOTDIR}/conf"

. ${ROOTDIR}/config
. ${CONF_DIR}/global
. ${CONF_DIR}/core
. ${CONF_DIR}/mysql
. ${ROOTDIR}/functions/postfix.sh
. ${ROOTDIR}/functions/mysql.sh

if [ ! -d ${NGINX_LOG_DIR} ]; then
    mkdir -p ${NGINX_LOG_DIR}
fi

rm -f /var/run/syslogd.pid
rm -f /var/run/cbpolicyd.pid
rm -f /var/run/opendkim/opendkim.pid

if [ ${MYSQL_SERVER} != "127.0.0.1" ] && [ ${MYSQL_SERVER} != "localhost" ]; then
    echo "Waiting for external MySql response"

    while ! mysqladmin ping -h ${MYSQL_SERVER} -P ${MYSQL_SERVER_PORT} -u ${MYSQL_ROOT_USER} --password=${MYSQL_ROOT_PASSW} --silent; do
          sleep 1
    done
else
# start services
    systemctl start mysqld
fi

# update rows in 'greylisting_whitelist'
mysql_generate_defaults_file_root

cat >> ${TMP_SQL} <<EOF
USE ${CLUEBRINGER_DB_NAME};
DELETE FROM greylisting_whitelist WHERE Comment='${HOSTNAME}';
EOF

for i in $IP_ADDRESS; do
    cat >> ${TMP_SQL} <<EOF
INSERT INTO greylisting_whitelist (Source, Comment, Disabled) VALUES ("SenderIP:$i", '${HOSTNAME}', 0);
EOF
done

# generate and insert access_token into 'api_keys'
cur_date="$(date +'%F %T')"
expires_at="$(date +'%F %T' -d "+36500 days")"
access_token=$(date | md5sum | awk '{ print $1 }')

cat >> ${TMP_SQL} <<EOF
INSERT IGNORE INTO api_keys (id, access_token, active, expires_at, created_at, updated_at) VALUES (1, '${access_token}', 1, '${expires_at}', '${cur_date}', '${cur_date}');
EOF

${MYSQL_CLIENT_ROOT} <<EOF
SOURCE ${TMP_SQL};
EOF

systemctl start crond dovecot rsyslog amavisd postfix cbpolicyd clamd clamd.amavisd nginx opendkim spamassassin fail2ban spamtrainer

rm -f ${MYSQL_DEFAULTS_FILE_ROOT} &>/dev/null
rm -f ${TMP_SQL} 2>/dev/null
unset TMP_SQL

EXTERNAL_SCRIPT="/var/vmail/external.sh"

if [ -f "$EXTERNAL_SCRIPT" ]
then
	bash -C ${EXTERNAL_SCRIPT}
fi
