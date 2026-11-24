#!/bin/bash
# Start or stop the local test mail servers the integration suite needs
# (TESTING.md, "Protocol" row). Nothing here ever touches a real mail
# account: GreenMail is an in-memory IMAP/SMTP server seeded empty, and
# Dovecot runs against a scratch Maildir with a throwaway passwd file.
#
#   scripts/imap-servers.sh start   # download if needed, wait for readiness
#   scripts/imap-servers.sh stop
#
# The integration tests read the addresses from
# GEIST9_GREENMAIL_HOST / GEIST9_GREENMAIL_PORT and
# GEIST9_DOVECOT_HOST / GEIST9_DOVECOT_PORT and fail loudly when nothing
# answers. A server can be left out only by naming it in
# GEIST9_SKIP_SERVERS (comma-separated) — an explicit environment choice,
# never a silent skip.
set -euo pipefail

GREENMAIL_VERSION="2.1.3"
HOST="127.0.0.1"
GREENMAIL_PORT="${GEIST9_GREENMAIL_PORT:-13143}"
DOVECOT_PORT="${GEIST9_DOVECOT_PORT:-14399}"
# The scratch dirs keep binaries and state out of the repository (never
# commit binaries) and out of everything but temporary space.
GREENMAIL_DIR="${GEIST9_GREENMAIL_DIR:-${TMPDIR:-/tmp}/geist9-greenmail}"
DOVECOT_DIR="${GEIST9_DOVECOT_DIR:-${TMPDIR:-/tmp}/geist9-dovecot}"
JAR="$GREENMAIL_DIR/greenmail-$GREENMAIL_VERSION.jar"
URL="https://repo1.maven.org/maven2/com/icegreen/greenmail-standalone/$GREENMAIL_VERSION/greenmail-standalone-$GREENMAIL_VERSION.jar"
# Fixtures only: obviously fake local test values, never real credentials.
USER="alice@example.com"
PASSWORD="secret"


is_listening() {
    # Instant probe: one attempt, no waiting. Used only for the idempotence
    # check; wait_ready does the actual waiting after a launch.
    #
    # In a SUBSHELL: `exec 3<>...` replaces this shell's descriptors and the
    # redirection persists after the function returns — the 2>/dev/null of
    # the failed connect then swallows every later diagnostic (and a probe
    # during server boot spams "Connection refused" that under `set -e` the
    # surrounding caller must not see as a command failure). The subshell
    # confines both the descriptor change and the exit status.
    local port="$1"
    (
        if exec 3<>"/dev/tcp/$HOST/$port" 2>/dev/null; then
            local greeting
            greeting=$(head -c 256 <&3 2>/dev/null || true)
            exec 3<&- 3>&- || true
            case "$greeting" in
                *OK*) exit 0 ;;
            esac
        fi
        exit 1
    )
}

wait_ready() {
    # $1: port. 120 s: the deadline also covers a cold GreenMail jar
    # download on a fresh CI container, not just server startup.
    local port="$1"
    local deadline=$((SECONDS + 120))
    while (( SECONDS < deadline )); do
        if is_listening "$port"; then
            return 0
        fi
        sleep 1
    done
    echo "imap-servers: $HOST:$port never answered" >&2
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
    mkdir -p "$GREENMAIL_DIR"
    if [[ ! -s "$JAR" ]]; then
        echo "imap-servers: downloading GreenMail $GREENMAIL_VERSION" >&2
        # Transient maven/TLS hiccups otherwise kill a whole CI run. HTTP
        # 429 from the release host is retried too: curl's --retry covers
        # it with --retry-all-errors, and a fresh runner has nothing to
        # lose by waiting a little for the rate limit to clear.
        curl -fsSL --retry 5 --retry-delay 20 --retry-all-errors -o "$JAR" "$URL"
    fi
    # Already answering? Nothing to do (idempotent: another session may have
    # started it).
    if is_listening "$GREENMAIL_PORT"; then
        echo "imap-servers: GreenMail already listening on $HOST:$GREENMAIL_PORT"
        return 0
    fi
    # Unprivileged, from the scratch dir: no root, no writes outside it.
    # GreenMail's users property is `login:pwd[@domain]`; with login=email
    # the login local part combines with the domain into the full address.
    ( cd "$GREENMAIL_DIR" && nohup "$java_bin" \
        -Dgreenmail.imap.hostname="$HOST" \
        -Dgreenmail.imap.port="$GREENMAIL_PORT" \
        -Dgreenmail.users="alice:$PASSWORD@example.com" \
        -Dgreenmail.users.login=email \
        -jar "$JAR" > greenmail.log 2>&1 & )
    wait_ready "$GREENMAIL_PORT"
    echo "imap-servers: GreenMail listening on $HOST:$GREENMAIL_PORT (log: $GREENMAIL_DIR/greenmail.log)"
}

# Generates a standalone Dovecot 2.4 config for an unprivileged fixture
# instance. The recipe (paths aside) is the verified local probe config:
# plain IMAP on the loopback, maildir storage under the scratch dir,
# passwd-file passdb/userdb, imaps listener disabled.
write_dovecot_config() {
    local bin="$1" conf="$2" passwd="$3"
    local libexec_dir=""
    local internal_user="" internal_group="" login_user=""

    if [[ "$(uname)" == Darwin ]]; then
        # Homebrew's dovecot lives in its Cellar; the built-in default
        # internal users (dovecot/dovenull, created by the Linux package)
        # do not exist on macOS, so run everything as the current user.
        # The helper binaries (anvil, imap-login) must come from the same
        # Cellar version — resolve through the sbin symlink so a version
        # bump keeps pointing at the right libexec dir.
        libexec_dir="$(dirname "$(dirname "$(readlink -f "$bin")")")/libexec/dovecot"
        internal_user="$(id -un)"
        internal_group="$(id -gn)"
        login_user="$(id -un)"
    fi

    # Mail storage ownership: as root (a container CI job) the login UID
    # must be a real non-root account — Dovecot refuses UID 0 logins — so
    # use nobody:nogroup and chown the mail tree to it. Unprivileged runs
    # (macOS) use the invoking user's own ids.
    if [[ "$(id -u)" == 0 ]]; then
        MAIL_UID=65534
        MAIL_GID=65534
    else
        MAIL_UID="$(id -u)"
        MAIL_GID="$(id -g)"
    fi

    # The userdb home field must be absolute and per-user: a relative value
    # (or the global mail_home alone) makes `mail_path = ~/Maildir` resolve
    # to a relative path and login fails with "initialization failed".
    cat > "$passwd" <<EOF
$USER:{PLAIN}$PASSWORD:$MAIL_UID:$MAIL_GID::$DOVECOT_DIR/mail/$USER::
EOF

    # The config header versions must match the INSTALLED dovecot, not a
    # pinned number: noble ships 2.4.0 and rejects a 2.4.5 header, while a
    # future brew bump may reject a 2.4.0 one. Parse `dovecot --version`
    # ("2.4.5 (0cbb641e3e)" — first whitespace field is the number).
    local dovecot_version=""
    dovecot_version="$("$bin" --version 2>/dev/null | head -n1 | awk '{print $1}')"
    case "$dovecot_version" in
        2.4.*) : ;;
        *)
            echo "imap-servers: cannot parse a 2.4.x dovecot version from '$bin --version' (got: ${dovecot_version:-nothing}); the fixture needs Dovecot 2.4" >&2
            return 1
            ;;
    esac

    {
        echo "dovecot_config_version = $dovecot_version"
        echo "dovecot_storage_version = $dovecot_version"
        if [[ -n "$internal_user" ]]; then
            echo "default_internal_user = $internal_user"
            echo "default_internal_group = $internal_group"
            echo "default_login_user = $login_user"
        fi
        echo "base_dir = $DOVECOT_DIR/base"
        echo "state_dir = $DOVECOT_DIR/state"
        if [[ -n "$libexec_dir" ]]; then
            echo "libexec_dir = $libexec_dir"
        fi
        echo "instance_name = geist9-imap-fixture"
        echo "protocols {"
        echo "  imap = yes"
        echo "}"
        echo "log_path = stderr"
        echo "listen = $HOST"
        echo "service imap-login {"
        echo "  inet_listener imap {"
        echo "    port = $DOVECOT_PORT"
        echo "  }"
        echo "  inet_listener imaps {"
        echo "    port = 0"
        echo "  }"
        echo "  chroot ="
        echo "}"
        echo "auth_mechanisms = plain"
        echo "passdb pw {"
        echo "  driver = passwd-file"
        echo "  passwd_file_path = $passwd"
        echo "}"
        echo "userdb pw {"
        echo "  driver = passwd-file"
        echo "  passwd_file_path = $passwd"
        echo "}"
        echo "mail_home = $DOVECOT_DIR/mail/%{user}"
        echo "mail_driver = maildir"
        echo "mail_path = ~/Maildir"
        echo "first_valid_uid = 100"
        echo "last_valid_uid = 60000"
        echo "namespace inbox {"
        echo "  inbox = yes"
        echo "  separator = /"
        echo "}"
        echo "default_vsz_limit = 9223372036854775807"
    } > "$conf"

    # The mail tree must be writable by the login uid chosen above.
    mkdir -p "$DOVECOT_DIR/mail"
    if [[ "$(id -u)" == 0 ]]; then
        chown -R "$MAIL_UID:$MAIL_GID" "$DOVECOT_DIR/mail" || true
    fi
}

start_dovecot() {
    local dovecot_bin=""
    for candidate in /opt/homebrew/sbin/dovecot /usr/sbin/dovecot; do
        if [[ -x "$candidate" ]]; then dovecot_bin="$candidate"; break; fi
    done
    if [[ -z "$dovecot_bin" ]]; then
        dovecot_bin="$(command -v dovecot || true)"
    fi
    if [[ -z "$dovecot_bin" ]]; then
        echo "imap-servers: dovecot is required for the Dovecot integration tests (brew install dovecot / apt-get install dovecot-core), or leave it out with GEIST9_SKIP_SERVERS=dovecot" >&2
        return 1
    fi
    mkdir -p "$DOVECOT_DIR"
    # Already answering? Nothing to do (idempotent).
    if is_listening "$DOVECOT_PORT"; then
        echo "imap-servers: Dovecot already listening on $HOST:$DOVECOT_PORT"
        return 0
    fi
    write_dovecot_config "$dovecot_bin" "$DOVECOT_DIR/dovecot.conf" "$DOVECOT_DIR/passwd"
    # -F: stay in the foreground of the nohup'd child. Unprivileged, from
    # the scratch dir: no root (except a container job, which drops to the
    # configured internal/login users), no writes outside it.
    ( cd "$DOVECOT_DIR" && nohup "$dovecot_bin" -c "$DOVECOT_DIR/dovecot.conf" -F > dovecot.log 2>&1 & )
    wait_ready "$DOVECOT_PORT"
    echo "imap-servers: Dovecot listening on $HOST:$DOVECOT_PORT (log: $DOVECOT_DIR/dovecot.log)"
}

stop_greenmail() {
    # Kill only the exact command line this script starts (never another
    # process's java).
    pkill -f "greenmail.*-Dgreenmail.imap.port=$GREENMAIL_PORT" 2>/dev/null || true
}

stop_dovecot() {
    # Kill only the instance whose config this script generated.
    pkill -f "dovecot -c $DOVECOT_DIR/dovecot.conf" 2>/dev/null || true
}

case "${1:-}" in
    start)
        # GEIST9_SKIP_SERVERS is an explicit operator choice to leave a
        # server out; everything not named there must come up or the run
        # fails loudly here.
        skipped="${GEIST9_SKIP_SERVERS:-}"
        case ",$skipped," in
            *,greenmail,*) echo "imap-servers: greenmail skipped (GEIST9_SKIP_SERVERS)" ;;
            *) start_greenmail ;;
        esac
        case ",$skipped," in
            *,dovecot,*) echo "imap-servers: dovecot skipped (GEIST9_SKIP_SERVERS)" ;;
            *) start_dovecot ;;
        esac
        echo "imap-servers: started"
        ;;
    stop)
        stop_greenmail
        stop_dovecot
        echo "imap-servers: stopped"
        ;;
    *)
        echo "usage: $0 {start|stop}" >&2
        exit 2
        ;;
esac
