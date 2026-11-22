#!/bin/bash
# Start or stop the local test mail servers the integration suite needs
# (TESTING.md, "Protocol" row). Nothing here ever touches a real mail
# account: GreenMail is an in-memory IMAP/SMTP server seeded empty.
#
#   scripts/imap-servers.sh start   # download if needed, wait for readiness
#   scripts/imap-servers.sh stop
#
# The integration tests read the address from GEIST9_GREENMAIL_HOST /
# GEIST9_GREENMAIL_PORT and fail loudly when nothing answers.
set -euo pipefail

GREENMAIL_VERSION="2.1.3"
HOST="127.0.0.1"
PORT="${GEIST9_GREENMAIL_PORT:-13143}"
# The scratch dir keeps the jar out of the repository (never commit binaries).
SCRATCH_DIR="${GEIST9_GREENMAIL_DIR:-${TMPDIR:-/tmp}/geist9-greenmail}"
JAR="$SCRATCH_DIR/greenmail-$GREENMAIL_VERSION.jar"
URL="https://repo1.maven.org/maven2/com/icegreen/greenmail-standalone/$GREENMAIL_VERSION/greenmail-standalone-$GREENMAIL_VERSION.jar"
# Fixtures only: obviously fake local test values, never real credentials.
USER="alice"
PASSWORD="secret"


wait_ready() {
    local deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        if exec 3<>"/dev/tcp/$HOST/$PORT" 2>/dev/null; then
            local greeting
            greeting=$(head -c 256 <&3 2>/dev/null || true)
            exec 3<&- 3>&- || true
            case "$greeting" in
                *OK*) return 0 ;;
            esac
        fi
        sleep 1
    done
    echo "imap-servers: $HOST:$PORT never answered" >&2
    return 1
}

start_greenmail() {
    # Homebrew's OpenJDK is keg-only and /usr/bin/java is a stub that fails
    # without a registered JVM, so probe the keg paths FIRST and only fall
    # back to whatever `java` resolves to.
    local java_bin=""
    for candidate in /opt/homebrew/opt/openjdk/bin/java \
                     /usr/local/opt/openjdk/bin/java \
                     "$(/usr/libexec/java_home 2>/dev/null)/bin/java"; do
        if [[ -x "$candidate" ]]; then java_bin="$candidate"; break; fi
    done
    if [[ -z "$java_bin" ]]; then
        java_bin="$(command -v java || true)"
    fi
    if [[ -z "$java_bin" ]] || ! "$java_bin" -version >/dev/null 2>&1; then
        echo "imap-servers: a working java is required (brew install openjdk / apt-get install default-jre-headless)" >&2
        return 1
    fi
    mkdir -p "$SCRATCH_DIR"
    if [[ ! -s "$JAR" ]]; then
        echo "imap-servers: downloading GreenMail $GREENMAIL_VERSION" >&2
        curl -fsSL -o "$JAR" "$URL"
    fi
    # Already answering? Nothing to do (idempotent: another session may have
    # started it).
    if wait_ready 2>/dev/null; then
        echo "imap-servers: GreenMail already listening on $HOST:$PORT"
        return 0
    fi
    # Unprivileged, from the scratch dir: no root, no writes outside it.
    ( cd "$SCRATCH_DIR" && nohup "$java_bin" \
        -Dgreenmail.imap.hostname="$HOST" \
        -Dgreenmail.imap.port="$PORT" \
        -Dgreenmail.users="$USER:$PASSWORD@example.com" \
        -Dgreenmail.users.login=email \
        -jar "$JAR" > greenmail.log 2>&1 & )
    wait_ready
    echo "imap-servers: GreenMail listening on $HOST:$PORT (log: $SCRATCH_DIR/greenmail.log)"
}

stop_greenmail() {
    # Kill only the exact command line this script starts (never another
    # process's java).
    pkill -f "greenmail.*-Dgreenmail.imap.port=$PORT" 2>/dev/null || true
    echo "imap-servers: stopped"
}

case "${1:-}" in
    start) start_greenmail ;;
    stop) stop_greenmail ;;
    *)
        echo "usage: $0 {start|stop}" >&2
        exit 2
        ;;
esac
