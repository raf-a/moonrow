#!/bin/sh
# One throwaway server per database version the bundled backup tools support, for the backup
# matrix tests (Tests/AppCoreTests/BackupMatrixTests.swift). Slow: run it on demand and before a
# release, not with every `swift test`.
#
#   scripts/test-matrix.sh list               the servers, by name
#   scripts/test-matrix.sh up [name…]         start them (all by default) and wait for logins
#   scripts/test-matrix.sh down [name…]       remove them
#   scripts/test-matrix.sh env [name…]        print MOONROW_MATRIX, which switches the tests on
#
# Then: eval "$(scripts/test-matrix.sh env)" && swift test --filter BackupMatrix
# Or a few at a time: scripts/test-matrix.sh up pg10 mysql57 && eval "$(scripts/test-matrix.sh env pg10 mysql57)" …
#
# Containers are named moonrow-test-matrix-<name>, ports bind to 127.0.0.1 only, and the data
# goes with the container. mysql:5.7 has no arm64 image and runs emulated on Apple silicon.
set -eu

PASSWORD=moonrow

# name, image, port
SERVERS="
pg10 postgres:10 56010
pg11 postgres:11 56011
pg12 postgres:12 56012
pg13 postgres:13 56013
pg14 postgres:14 56014
pg15 postgres:15 56015
pg16 postgres:16 56016
pg17 postgres:17 56017
pg18 postgres:18 56018
mysql57 mysql:5.7 56157
mysql80 mysql:8.0 56180
mysql84 mysql:8.4 56184
mysql97 mysql:9.7 56197
mariadb106 mariadb:10.6 56206
mariadb1011 mariadb:10.11 56211
mariadb114 mariadb:11.4 56214
mariadb118 mariadb:11.8 56218
mariadb123 mariadb:12.3 56223
"

# The servers named, or all of them: "name image port" lines.
pick() {
    if [ $# -eq 0 ]; then
        echo "$SERVERS" | grep .
        return
    fi
    for name in "$@"; do
        line="$(echo "$SERVERS" | grep "^$name " || true)"
        [ -n "$line" ] || { echo "unknown server: $name (see: $0 list)" >&2; exit 2; }
        echo "$line"
    done
}

url() { # name port
    case "$1" in
        pg*) echo "postgres://postgres:$PASSWORD@127.0.0.1:$2/postgres" ;;
        mysql*) echo "mysql://root:$PASSWORD@127.0.0.1:$2/mysql" ;;
        mariadb*) echo "mariadb://root:$PASSWORD@127.0.0.1:$2/mysql" ;;
    esac
}

start() { # name image port
    container="moonrow-test-matrix-$1"
    docker rm -f "$container" >/dev/null 2>&1 || true
    case "$1" in
        pg*)
            docker run -d --name "$container" -p "127.0.0.1:$3:5432" -e POSTGRES_PASSWORD=$PASSWORD "$2" >/dev/null ;;
        mysql57)
            docker run -d --name "$container" --platform linux/amd64 -p "127.0.0.1:$3:3306" \
                -e MYSQL_ROOT_PASSWORD=$PASSWORD "$2" \
                --innodb-buffer-pool-size=64M --performance-schema=OFF >/dev/null ;;
        mysql*)
            docker run -d --name "$container" -p "127.0.0.1:$3:3306" -e MYSQL_ROOT_PASSWORD=$PASSWORD "$2" \
                --innodb-buffer-pool-size=64M --performance-schema=OFF >/dev/null ;;
        mariadb*)
            docker run -d --name "$container" -p "127.0.0.1:$3:3306" -e MARIADB_ROOT_PASSWORD=$PASSWORD "$2" \
                --innodb-buffer-pool-size=64M --performance-schema=OFF >/dev/null ;;
    esac
}

ready() { # name
    container="moonrow-test-matrix-$1"
    case "$1" in
        # The image's first start runs a temporary server; the real one says so a second time.
        pg*) [ "$(docker logs "$container" 2>&1 | grep -c 'ready to accept connections')" -ge 2 ] \
            && docker exec "$container" pg_isready -q -h 127.0.0.1 ;;
        mysql*) docker exec "$container" mysql -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' >/dev/null 2>&1 ;;
        mariadb*) docker exec "$container" sh -c "mariadb -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' || mysql -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1'" >/dev/null 2>&1 ;;
    esac
}

up() {
    lines="$(pick "$@")"
    echo "$lines" | while read -r name image port; do start "$name" "$image" "$port"; done
    printf "waiting for servers"
    for i in $(seq 1 180); do
        waiting=""
        for name in $(echo "$lines" | awk '{print $1}'); do ready "$name" || waiting="$waiting $name"; done
        if [ -z "$waiting" ]; then
            echo " ready"
            return 0
        fi
        printf "."
        sleep 2
    done
    echo " timed out:$waiting" >&2
    exit 1
}

case "${1:-}" in
    list) echo "$SERVERS" | awk 'NF {print $1 "\t" $2 "\t127.0.0.1:" $3}' ;;
    up) shift; up "$@" ;;
    down)
        shift
        for name in $(pick "$@" | awk '{print $1}'); do docker rm -f "moonrow-test-matrix-$name" >/dev/null 2>&1 || true; done ;;
    env)
        shift
        list=""
        for entry in $(pick "$@" | awk '{print $1 "=" $3}'); do
            list="$list${list:+ }${entry%%=*}=$(url "${entry%%=*}" "${entry#*=}")"
        done
        echo "export MOONROW_MATRIX='$list'" ;;
    *) echo "usage: $0 list | up [name…] | down [name…] | env [name…]" >&2; exit 2 ;;
esac
