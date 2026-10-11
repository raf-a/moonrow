#!/bin/sh
# Throwaway database servers for the driver tests, with every statement logged.
#
#   scripts/test-servers.sh up      start (or restart) them and wait until they accept logins
#   scripts/test-servers.sh down    remove them
#   scripts/test-servers.sh env     print the variables that switch the server tests on
#
# Then: eval "$(scripts/test-servers.sh env)" && swift test
#
# Ports bind to 127.0.0.1 only. The data lives inside the containers and goes with them.
set -eu

PG_IMAGE=postgres:18
MYSQL_IMAGE=mysql:8.4
MARIADB_IMAGE=mariadb:11.4
PASSWORD=tabula

env_vars() {
    echo "export TABULA_TEST_PG=postgres://postgres:$PASSWORD@127.0.0.1:55432/postgres"
    echo "export TABULA_TEST_MYSQL=mysql://root:$PASSWORD@127.0.0.1:53306/tabula"
    echo "export TABULA_TEST_MARIADB=mysql://root:$PASSWORD@127.0.0.1:53307/tabula"
}

up() {
    down >/dev/null 2>&1 || true

    # Postgres: statements to a JSON log the tests read back with pg_read_file; TLS with the
    # image's self-signed snakeoil certificate; md5 in pg_hba so md5 and SCRAM roles both work.
    docker run -d --name tabula-test-pg -p 127.0.0.1:55432:5432 \
        -e POSTGRES_PASSWORD=$PASSWORD -e POSTGRES_HOST_AUTH_METHOD=md5 \
        -e POSTGRES_INITDB_ARGS=--auth-host=md5 \
        $PG_IMAGE \
        -c log_statement=all -c logging_collector=on -c log_destination=jsonlog \
        -c log_directory=log -c log_filename=tabula -c log_rotation_size=0 \
        -c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
        -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key >/dev/null

    # MySQL: the general log as a table (mysql.general_log), so tests read it with SQL.
    docker run -d --name tabula-test-mysql -p 127.0.0.1:53306:3306 \
        -e MYSQL_ROOT_PASSWORD=$PASSWORD -e MYSQL_DATABASE=tabula \
        $MYSQL_IMAGE --general-log=1 --log-output=TABLE --mysql-native-password=ON >/dev/null

    docker run -d --name tabula-test-mariadb -p 127.0.0.1:53307:3306 \
        -e MARIADB_ROOT_PASSWORD=$PASSWORD -e MARIADB_DATABASE=tabula \
        $MARIADB_IMAGE --general-log=1 --log-output=TABLE >/dev/null

    printf "waiting for servers"
    for i in $(seq 1 90); do
        if docker exec tabula-test-pg pg_isready -q -h 127.0.0.1 2>/dev/null \
            && docker exec tabula-test-mysql mysql -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' tabula >/dev/null 2>&1 \
            && docker exec tabula-test-mariadb mariadb -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' tabula >/dev/null 2>&1
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
    docker rm -f tabula-test-pg tabula-test-mysql tabula-test-mariadb
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    env) env_vars ;;
    *) echo "usage: $0 up|down|env" >&2; exit 2 ;;
esac
