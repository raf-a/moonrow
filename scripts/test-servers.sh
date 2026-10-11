#!/bin/sh
# Throwaway database servers for the driver tests, with every statement logged, plus an SSH
# server on the same Docker network for the tunnel tests.
#
#   scripts/test-servers.sh up      start (or restart) them and wait until they accept logins
#   scripts/test-servers.sh down    remove them
#   scripts/test-servers.sh env     print the variables that switch the server tests on
#   scripts/test-servers.sh up-ssh  (re)start only the SSH server
#
# Then: eval "$(scripts/test-servers.sh env)" && swift test
#
# Ports bind to 127.0.0.1 only. The data lives inside the containers and goes with them.
set -eu

PG_IMAGE=postgres:18
MYSQL_IMAGE=mysql:8.4
MARIADB_IMAGE=mariadb:11.4
SSH_IMAGE=alpine:3.22
PASSWORD=tabula
NETWORK=tabula-test
KEYS="$(cd "$(dirname "$0")/.." && pwd)/Tests/SSHTunnelTests/Fixtures"

env_vars() {
    echo "export TABULA_TEST_PG=postgres://postgres:$PASSWORD@127.0.0.1:55432/postgres"
    echo "export TABULA_TEST_MYSQL=mysql://root:$PASSWORD@127.0.0.1:53306/tabula"
    echo "export TABULA_TEST_MARIADB=mysql://root:$PASSWORD@127.0.0.1:53307/tabula"
    # Reaches the databases by container name: tabula-test-pg:5432, tabula-test-mysql:3306.
    echo "export TABULA_TEST_SSH=ssh://tabula:$PASSWORD@127.0.0.1:52222"
}

# OpenSSH on the databases' network: user `tabula` with a password, and the throwaway keys in
# Tests/SSHTunnelTests/Fixtures authorized.
up_ssh() {
    docker network create $NETWORK >/dev/null 2>&1 || true
    docker rm -f tabula-test-ssh >/dev/null 2>&1 || true
    docker run -d --name tabula-test-ssh --network $NETWORK -p 127.0.0.1:52222:22 \
        -e AUTHORIZED_KEYS="$(cat "$KEYS"/*.pub)" -e PASSWORD=$PASSWORD \
        $SSH_IMAGE sh -c '
            apk add --no-cache openssh-server >/dev/null && ssh-keygen -A >/dev/null &&
            adduser -D -s /bin/sh tabula && echo "tabula:$PASSWORD" | chpasswd 2>/dev/null &&
            mkdir -p /home/tabula/.ssh && echo "$AUTHORIZED_KEYS" > /home/tabula/.ssh/authorized_keys &&
            chown -R tabula /home/tabula/.ssh && chmod 700 /home/tabula/.ssh &&
            chmod 600 /home/tabula/.ssh/authorized_keys &&
            exec /usr/sbin/sshd -D -e -o PasswordAuthentication=yes -o AllowTcpForwarding=yes \
                -o KbdInteractiveAuthentication=no' >/dev/null
}

ssh_ready() {
    docker logs tabula-test-ssh 2>&1 | grep -q 'Server listening'
}

up() {
    down >/dev/null 2>&1 || true
    docker network create $NETWORK >/dev/null

    # Postgres: statements to a JSON log the tests read back with pg_read_file; TLS with the
    # image's self-signed snakeoil certificate; md5 in pg_hba so md5 and SCRAM roles both work.
    docker run -d --name tabula-test-pg --network $NETWORK -p 127.0.0.1:55432:5432 \
        -e POSTGRES_PASSWORD=$PASSWORD -e POSTGRES_HOST_AUTH_METHOD=md5 \
        -e POSTGRES_INITDB_ARGS=--auth-host=md5 \
        $PG_IMAGE \
        -c log_statement=all -c logging_collector=on -c log_destination=jsonlog \
        -c log_directory=log -c log_filename=tabula -c log_rotation_size=0 \
        -c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
        -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key >/dev/null

    # MySQL: the general log as a table (mysql.general_log), so tests read it with SQL.
    docker run -d --name tabula-test-mysql --network $NETWORK -p 127.0.0.1:53306:3306 \
        -e MYSQL_ROOT_PASSWORD=$PASSWORD -e MYSQL_DATABASE=tabula \
        $MYSQL_IMAGE --general-log=1 --log-output=TABLE --mysql-native-password=ON >/dev/null

    docker run -d --name tabula-test-mariadb --network $NETWORK -p 127.0.0.1:53307:3306 \
        -e MARIADB_ROOT_PASSWORD=$PASSWORD -e MARIADB_DATABASE=tabula \
        $MARIADB_IMAGE --general-log=1 --log-output=TABLE >/dev/null

    up_ssh

    printf "waiting for servers"
    for i in $(seq 1 90); do
        if docker exec tabula-test-pg pg_isready -q -h 127.0.0.1 2>/dev/null \
            && docker exec tabula-test-mysql mysql -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' tabula >/dev/null 2>&1 \
            && docker exec tabula-test-mariadb mariadb -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' tabula >/dev/null 2>&1 \
            && ssh_ready
        then
            echo " ready"
            env_vars
            return 0
        fi
        printf "."
        sleep 2
    done
    echo " timed out" >&2
    exit 1
}

down() {
    docker rm -f tabula-test-pg tabula-test-mysql tabula-test-mariadb tabula-test-ssh
    docker network rm $NETWORK >/dev/null 2>&1 || true
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    env) env_vars ;;
    # Leaves the databases running. Ones started by an older copy of this script aren't on the
    # network yet: `docker network connect tabula-test tabula-test-pg` (and -mysql) adds them.
    up-ssh) up_ssh; until ssh_ready; do sleep 1; done ;;
    *) echo "usage: $0 up|down|env|up-ssh" >&2; exit 2 ;;
esac
