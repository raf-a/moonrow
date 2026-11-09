#!/bin/sh
# One throwaway server per database version Moonrow supports, set up as scripts/test-servers.sh
# sets up its servers (statement logs, TLS, password logins), so the server tests and the backup
# matrix (Tests/AppCoreTests/BackupMatrixTests.swift) run against each. Slow: run it on demand and
# before a release, not with every `swift test`.
#
#   scripts/test-matrix.sh list               the servers, by name
#   scripts/test-matrix.sh up [name…]         start them (all by default) and wait for logins
#   scripts/test-matrix.sh down [name…]       remove them
#   scripts/test-matrix.sh env [name…]        print MOONROW_MATRIX, which switches the tests on
#   scripts/test-matrix.sh run [name…]        the server tests against each server in MOONROW_MATRIX
#
# Then: eval "$(scripts/test-matrix.sh env)" && scripts/test-matrix.sh run
# Or a few at a time: scripts/test-matrix.sh up pg10 mysql57 && eval "$(scripts/test-matrix.sh env pg10 mysql57)" …
# The backup matrix alone: swift test --filter BackupMatrix, with MOONROW_MATRIX set.
#
# `run` sets one server's MOONROW_TEST_PG, _MYSQL or _MARIADB at a time and runs the test targets
# that use them, so every server test sees every version; the backup round trips need the built
# tools (scripts/build-tools.sh). Each server's output goes to build/matrix/<name>.log.
#
# Servers run in Docker, named moonrow-test-matrix-<name>; mysql:5.7 has no arm64 image and runs
# emulated on Apple silicon. With --brew first (`scripts/test-matrix.sh --brew up pg14`), they run
# from Homebrew instead, for CI's macOS runners, which have no Docker: only the versions Homebrew
# has, data in $MOONROW_MATRIX_DIR (default $RUNNER_TEMP or $TMPDIR, then moonrow-matrix).
# Either way ports bind to 127.0.0.1 only and the data goes with the server.
set -eu

PASSWORD=moonrow
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BACKEND=docker
if [ "${1:-}" = "--brew" ]; then
    BACKEND=brew
    shift
fi
DIR="${MOONROW_MATRIX_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/moonrow-matrix}"

# name, image, port, Homebrew formula (- for none; postgresql@14 is disabled from 2026-11-12)
SERVERS="
pg10 postgres:10 56010 -
pg11 postgres:11 56011 -
pg12 postgres:12 56012 -
pg13 postgres:13 56013 -
pg14 postgres:14 56014 -
pg15 postgres:15 56015 postgresql@15
pg16 postgres:16 56016 postgresql@16
pg17 postgres:17 56017 postgresql@17
pg18 postgres:18 56018 postgresql@18
mysql57 mysql:5.7 56157 -
mysql80 mysql:8.0 56180 mysql@8.0
mysql84 mysql:8.4 56184 mysql@8.4
mysql97 mysql:9.7 56197 -
mariadb106 mariadb:10.6 56206 mariadb@10.6
mariadb1011 mariadb:10.11 56211 mariadb@10.11
mariadb114 mariadb:11.4 56214 mariadb@11.4
mariadb118 mariadb:11.8 56218 mariadb@11.8
mariadb123 mariadb:12.3 56223 -
"

# The servers named, or all of them (all that Homebrew has, with --brew): "name image port formula" lines.
pick() {
    if [ $# -eq 0 ]; then
        if [ $BACKEND = brew ]; then echo "$SERVERS" | awk 'NF && $4 != "-"'; else echo "$SERVERS" | grep .; fi
        return
    fi
    for name in "$@"; do
        line="$(echo "$SERVERS" | grep "^$name " || true)"
        [ -n "$line" ] || { echo "unknown server: $name (see: $0 list)" >&2; exit 2; }
        if [ $BACKEND = brew ] && [ "$(echo "$line" | awk '{print $4}')" = "-" ]; then
            echo "$name isn't in Homebrew; run it in Docker" >&2
            exit 2
        fi
        echo "$line"
    done
}

url() { # name port
    case "$1" in
        pg*) echo "postgres://postgres:$PASSWORD@127.0.0.1:$2/postgres" ;;
        mysql*) echo "mysql://root:$PASSWORD@127.0.0.1:$2/moonrow" ;;
        mariadb*) echo "mariadb://root:$PASSWORD@127.0.0.1:$2/moonrow" ;;
    esac
}

# The major version in an image tag: postgres:10 → 10, mysql:8.4 → 8.4.
version() { echo "${1#*:}"; }

# Postgres writes statements to a log the tests read back with pg_read_file: JSON from 15 on,
# CSV before. md5 in pg_hba, so md5 and SCRAM roles both log in.
pg_options() { # image
    format=csvlog
    [ "$(version "$1")" -lt 15 ] || format=jsonlog
    echo "-c log_statement=all -c logging_collector=on -c log_destination=$format -c log_directory=log" \
        "-c log_filename=moonrow -c log_rotation_size=0 -c ssl=on"
}

# MySQL and MariaDB write statements to the mysql.general_log table. 8.4 loads
# mysql_native_password only when asked; 9.x has none.
my_options() { # image
    options="--general-log=1 --log-output=TABLE --innodb-buffer-pool-size=64M --performance-schema=OFF"
    case "$1" in mysql:8.4) options="$options --mysql-native-password=ON" ;; esac
    echo "$options"
}

docker_start() { # name image port
    container="moonrow-test-matrix-$1"
    docker rm -f "$container" >/dev/null 2>&1 || true
    case "$1" in
        pg*)
            # TLS with the image's self-signed snakeoil certificate.
            docker run -d --name "$container" -p "127.0.0.1:$3:5432" \
                -e POSTGRES_PASSWORD=$PASSWORD -e POSTGRES_HOST_AUTH_METHOD=md5 -e POSTGRES_INITDB_ARGS=--auth-host=md5 \
                "$2" $(pg_options "$2") \
                -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
                -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key >/dev/null ;;
        mysql57)
            docker run -d --name "$container" --platform linux/amd64 -p "127.0.0.1:$3:3306" \
                -e MYSQL_ROOT_PASSWORD=$PASSWORD -e MYSQL_DATABASE=moonrow "$2" $(my_options "$2") >/dev/null ;;
        mysql*)
            docker run -d --name "$container" -p "127.0.0.1:$3:3306" \
                -e MYSQL_ROOT_PASSWORD=$PASSWORD -e MYSQL_DATABASE=moonrow "$2" $(my_options "$2") >/dev/null ;;
        mariadb*)
            # MariaDB turns TLS on by itself only from 11.4: a certificate the server's user can read.
            tls="$DIR/docker-tls"
            if [ ! -f "$tls/server.crt" ]; then
                mkdir -p "$tls"
                certificate "$tls"
                chmod 644 "$tls/server.key"
            fi
            docker run -d --name "$container" -p "127.0.0.1:$3:3306" -v "$tls:/etc/moonrow-tls:ro" \
                -e MARIADB_ROOT_PASSWORD=$PASSWORD -e MARIADB_DATABASE=moonrow "$2" $(my_options "$2") \
                --ssl-cert=/etc/moonrow-tls/server.crt --ssl-key=/etc/moonrow-tls/server.key >/dev/null ;;
    esac
}

docker_ready() { # name
    container="moonrow-test-matrix-$1"
    case "$1" in
        # The image's first start runs a temporary server; the real one starts after init says it's done
        # (and then logs to its file, not to Docker).
        pg*) docker logs "$container" 2>&1 | grep -q 'init process complete' \
            && docker exec "$container" pg_isready -q -h 127.0.0.1 ;;
        mysql*) docker exec "$container" mysql -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' moonrow >/dev/null 2>&1 ;;
        mariadb*) docker exec "$container" sh -c "mariadb -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' moonrow || mysql -uroot -p$PASSWORD -h127.0.0.1 -e 'SELECT 1' moonrow" >/dev/null 2>&1 ;;
    esac
}

# A self-signed certificate for a Homebrew server, in its folder.
certificate() { # folder
    openssl req -new -x509 -nodes -days 30 -subj /CN=localhost \
        -keyout "$1/server.key" -out "$1/server.crt" >/dev/null 2>&1
    chmod 600 "$1/server.key"
}

brew_start() { # name image port formula
    brew list "$4" >/dev/null 2>&1 || brew install --quiet "$4" >/dev/null
    prefix="$(brew --prefix "$4")"
    bin="$prefix/bin"
    folder="$DIR/$1"
    brew_stop "$1"
    rm -rf "$folder"
    mkdir -p "$folder"
    case "$1" in
        pg*)
            echo $PASSWORD > "$folder/password"
            "$bin/initdb" -D "$folder/data" -U postgres --auth=md5 --pwfile="$folder/password" >"$folder/initdb.log"
            certificate "$folder"
            "$bin/pg_ctl" -D "$folder/data" -l "$folder/server.log" start -o "-p $3 -k $folder \
                -c listen_addresses=127.0.0.1 $(pg_options "$2") \
                -c ssl_cert_file=$folder/server.crt -c ssl_key_file=$folder/server.key" >/dev/null ;;
        mysql*)
            # --initialize makes the TLS certificates in the data folder; root has no password
            # until the first login below sets one.
            "$bin/mysqld" --no-defaults --initialize-insecure --basedir="$prefix" --datadir="$folder/data" \
                >"$folder/init.log" 2>&1
            "$bin/mysqld" --no-defaults --basedir="$prefix" --datadir="$folder/data" --port="$3" --bind-address=127.0.0.1 \
                --socket="$folder/mysql.sock" --mysqlx=OFF --pid-file="$folder/server.pid" \
                --log-error="$folder/server.log" $(my_options "$2") >/dev/null 2>&1 &
            ;;
        mariadb*)
            certificate "$folder"
            "$bin/mariadb-install-db" --no-defaults --basedir="$prefix" --datadir="$folder/data" \
                --auth-root-authentication-method=normal >"$folder/init.log" 2>&1
            "$bin/mariadbd" --no-defaults --basedir="$prefix" --datadir="$folder/data" --port="$3" --bind-address=127.0.0.1 \
                --socket="$folder/mysql.sock" --pid-file="$folder/server.pid" --log-error="$folder/server.log" \
                --ssl-cert="$folder/server.crt" --ssl-key="$folder/server.key" $(my_options "$2") >/dev/null 2>&1 &
            ;;
    esac
}

# Ready once it takes the password over TCP. MySQL and MariaDB get it, the root login from any
# host the images have, and the moonrow database on their first login over the socket.
brew_ready() { # name image port formula
    bin="$(brew --prefix "$4")/bin"
    folder="$DIR/$1"
    case "$1" in
        pg*) PGPASSWORD=$PASSWORD "$bin/psql" -h 127.0.0.1 -p "$3" -U postgres -Atqc 'SELECT 1' postgres >/dev/null 2>&1 ;;
        *)
            client="$bin/mysql"
            [ -x "$bin/mariadb" ] && client="$bin/mariadb"
            if [ ! -f "$folder/ready" ] && "$client" --no-defaults -uroot --socket="$folder/mysql.sock" -e "
                ALTER USER root@localhost IDENTIFIED BY '$PASSWORD';
                CREATE USER root@'%' IDENTIFIED BY '$PASSWORD';
                GRANT ALL ON *.* TO root@'%' WITH GRANT OPTION;
                CREATE DATABASE moonrow" >/dev/null 2>&1; then
                touch "$folder/ready"
            fi
            "$client" --no-defaults -uroot -p$PASSWORD -h127.0.0.1 -P"$3" -e 'SELECT 1' moonrow >/dev/null 2>&1 ;;
    esac
}

brew_stop() { # name
    folder="$DIR/$1"
    [ -d "$folder/data" ] || return 0
    case "$1" in
        pg*)
            formula="$(echo "$SERVERS" | awk -v n="$1" '$1 == n {print $4}')"
            "$(brew --prefix "$formula")/bin/pg_ctl" -D "$folder/data" -m fast stop >/dev/null 2>&1 || true ;;
        *)
            if [ -f "$folder/server.pid" ]; then
                pid="$(cat "$folder/server.pid")"
                kill "$pid" 2>/dev/null || true
                while kill -0 "$pid" 2>/dev/null; do sleep 1; done
            fi ;;
    esac
}

up() {
    lines="$(pick "$@")"
    if [ $BACKEND = brew ]; then
        mkdir -p "$DIR"
        echo "$lines" | while read -r name image port formula; do brew_start "$name" "$image" "$port" "$formula"; done
    else
        echo "$lines" | while read -r name image port formula; do docker_start "$name" "$image" "$port"; done
    fi
    printf "waiting for servers"
    for i in $(seq 1 180); do
        waiting=""
        while read -r name image port formula; do
            if [ $BACKEND = brew ]; then
                brew_ready "$name" "$image" "$port" "$formula" || waiting="$waiting $name"
            else
                docker_ready "$name" || waiting="$waiting $name"
            fi
        done <<EOF
$lines
EOF
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

down() {
    for name in $(pick "$@" | awk '{print $1}'); do
        if [ $BACKEND = brew ]; then
            brew_stop "$name"
            rm -rf "${DIR:?}/$name"
        else
            docker rm -f "moonrow-test-matrix-$name" >/dev/null 2>&1 || true
        fi
    done
}

# The test targets with server tests. SSH's need MOONROW_TEST_SSH, which `run` leaves unset.
TARGETS='^(AppCoreTests|DriverPostgresTests|DriverMySQLTests|MCPServerTests)\.'
# How long one server's tests may take, in seconds, before `run` stops them.
TIMEOUT="${MOONROW_MATRIX_TIMEOUT:-600}"

kill_tree() { # pid
    for child in $(pgrep -P "$1"); do kill_tree "$child"; done
    kill "$1" 2>/dev/null || true
}

# The tests a log shows starting and not ending: where a run that was stopped hung.
unfinished() { # log
    tr -d '\r' < "$1" | sed -nE 's/^.* Test (.*) started\.$/\1/p' | grep -v -e '^case ' -e '^run$' | sort -u > "$1.started"
    tr -d '\r' < "$1" | sed -nE 's/^.* Test (.*) (passed|failed) after .*/\1/p' \
        | sed -E 's/ with [0-9]+ test cases?$//' | sort -u > "$1.ended"
    comm -23 "$1.started" "$1.ended" | sed 's/^/  /'
    rm -f "$1.started" "$1.ended"
}

run() {
    [ -n "${MOONROW_MATRIX:-}" ] || { echo "no MOONROW_MATRIX: eval \"\$($0 env)\" first" >&2; exit 2; }
    cd "$ROOT"
    mkdir -p build/matrix
    swift build --build-tests
    # The backup matrix needs the built tools; without them it's left out.
    tools="${MOONROW_TOOLS:-$ROOT/build/tools}"
    backups=1
    if [ ! -f "$tools/tools.json" ]; then
        echo "No backup tools in $tools (scripts/build-tools.sh): the backup matrix is left out"
        backups=0
    fi
    failed=""
    summary=""
    for entry in $MOONROW_MATRIX; do
        name="${entry%%=*}"
        if [ $# -gt 0 ] && ! echo " $* " | grep -q " $name "; then continue; fi
        case "$name" in
            pg*) variable=MOONROW_TEST_PG ;;
            mysql*) variable=MOONROW_TEST_MYSQL ;;
            mariadb*) variable=MOONROW_TEST_MARIADB ;;
        esac
        log="build/matrix/$name.log"
        echo "== $name"
        # On a terminal (a pseudo-terminal here) the tests write their log line by line, so a run
        # that hangs shows where.
        env -u MOONROW_TEST_PG -u MOONROW_TEST_MYSQL -u MOONROW_TEST_MARIADB -u MOONROW_TEST_SSH \
            "$variable=${entry#*=}" MOONROW_MATRIX="$([ $backups = 0 ] || echo "$entry")" \
            python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' \
            swift test --skip-build --filter "$TARGETS" </dev/null >"$log" 2>&1 &
        tests=$!
        (sleep "$TIMEOUT"; touch "$log.timeout"; kill_tree "$tests") &
        watchdog=$!
        status=0
        # (Redirected: the shell reports the jobs it reaps after a kill.)
        wait "$tests" 2>/dev/null || status=$?
        { kill_tree "$watchdog"; wait "$watchdog" || true; } 2>/dev/null
        issues="$(grep -c 'recorded an issue' "$log" || true)"
        if [ -f "$log.timeout" ]; then
            rm -f "$log.timeout"
            result="stopped after ${TIMEOUT}s"
            failed="$failed $name"
            echo "stopped after ${TIMEOUT}s, still running:"
            unfinished "$log"
        elif [ $status -eq 0 ]; then
            result=passed
        else
            result="FAILED with $issues issues"
            failed="$failed $name"
            grep -E 'recorded an issue|error:' "$log" | head -40 || true
        fi
        summary="$summary$(printf '%-12s %s' "$name" "$result")
"
    done
    printf '\n%s' "$summary"
    if [ -n "$failed" ]; then
        echo "failed:$failed (logs in build/matrix)" >&2
        exit 1
    fi
}

case "${1:-}" in
    list) pick | awk '{print $1 "\t" $2 "\t127.0.0.1:" $3 "\t" $4}' ;;
    up) shift; up "$@" ;;
    down) shift; down "$@" ;;
    env)
        shift
        list=""
        for entry in $(pick "$@" | awk '{print $1 "=" $3}'); do
            list="$list${list:+ }${entry%%=*}=$(url "${entry%%=*}" "${entry#*=}")"
        done
        echo "export MOONROW_MATRIX='$list'" ;;
    run) shift; run "$@" ;;
    *) echo "usage: $0 [--brew] list | up [name…] | down [name…] | env [name…] | run [name…]" >&2; exit 2 ;;
esac
