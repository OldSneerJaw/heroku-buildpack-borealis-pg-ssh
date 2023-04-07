#!/usr/bin/env bash


# MIT License

# Copyright (c) Boreal Information Systems Inc.

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


CONN_INFO_ENV_VAR_PATTERN='^(.+)_TUNNEL_BPG_CONN_INFO$'
LEGACY_CONN_INFO_ENV_VAR_PATTERN='^(.+)_SSH_TUNNEL_BPG_CONNECTION_INFO$'
PG_URL_PATTERN='^postgres(ql)?://[^@]+@([^:]+):([[:digit:]]+)/.+$'
BUILDPACK_DIR="${HOME}/.borealis-pg"
SSH_CONFIG_DIR="${HOME}/.ssh"
DEFAULT_AUTOSSH_DIR="${BUILDPACK_DIR}/autossh"
PROCESSED_ENTRIES=()

if [[ -d "$DEFAULT_AUTOSSH_DIR" ]]
then
    AUTOSSH_DIR="$DEFAULT_AUTOSSH_DIR"
else
    AUTOSSH_DIR="/usr/bin"
fi

function normalizeConnItemValue() {
    connItemValue="$1"

    echo "${connItemValue//\\n/$'\n'}"
}

ALL_ENV_VARS=$(awk 'BEGIN { for (name in ENVIRON) { print name } }')
for ENV_VAR in $ALL_ENV_VARS
do
    # Reset all tunnel connection variables
    POSTGRES_INTERNAL_PORT='5432'
    SSH_PORT='22'
    ADDON_ID=''
    API_BASE_URL=''
    CLIENT_APP_JWT=''
    POSTGRES_WRITER_HOST=''
    POSTGRES_READER_HOST=''
    SSH_HOST=''
    SSH_PUBLIC_HOST_KEY=''
    SSH_USERNAME=''
    SSH_USER_PRIVATE_KEY=''
    TUNNEL_WRITER_URL_HOST=''
    TUNNEL_WRITER_URL_PORT=''
    TUNNEL_READER_URL_HOST=''
    TUNNEL_READER_URL_PORT=''

    if [[ "$ENV_VAR" =~ $CONN_INFO_ENV_VAR_PATTERN ]] || [[ "$ENV_VAR" =~ $LEGACY_CONN_INFO_ENV_VAR_PATTERN ]]
    then
        ADDON_ENV_VAR_PREFIX="${BASH_REMATCH[1]}"

        # There should be a corresponding "*_URL" connection string environment variable
        ADDON_DB_CONN_STR=$(printenv "${ADDON_ENV_VAR_PREFIX}_URL" || echo '')
        if [[ "$ADDON_DB_CONN_STR" =~ $PG_URL_PATTERN ]]
        then
            # Retrieve the local host and port for the writer SSH tunnel from the "*_URL" env var
            # value
            TUNNEL_WRITER_URL_HOST="${BASH_REMATCH[2]}"
            TUNNEL_WRITER_URL_PORT="${BASH_REMATCH[3]}"

            # Retrieve the local host and port for the reader SSH tunnel from the "*_READONLY_URL"
            # env var value, if it exists
            ADDON_READONLY_DB_CONN_STR=$(printenv "${ADDON_ENV_VAR_PREFIX}_READONLY_URL" || echo '')
            if [[ "$ADDON_READONLY_DB_CONN_STR" =~ $PG_URL_PATTERN ]]
            then
                TUNNEL_READER_URL_HOST="${BASH_REMATCH[2]}"
                TUNNEL_READER_URL_PORT="${BASH_REMATCH[3]}"
            fi

            # Retrieve the secure tunnel connection details from the tunnel connection info env var
            TUNNEL_CONNECTION_INFO=$(printenv "$ENV_VAR")
            IFS=$'|' read -r -d '' -a CONN_INFO_ARRAY <<< "$TUNNEL_CONNECTION_INFO"
            for CONN_ITEM in "${CONN_INFO_ARRAY[@]}"
            do
                if [[ "$CONN_ITEM" =~ ^ADDON_ID:=(.+)$ ]]
                then
                    ADDON_ID=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^API_BASE_URL:=(.+)$ ]]
                then
                    API_BASE_URL=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^CLIENT_APP_JWT:=(.+)$ ]]
                then
                    CLIENT_APP_JWT=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^POSTGRES_WRITER_HOST:=(.+)$ ]]
                then
                    POSTGRES_WRITER_HOST=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^POSTGRES_READER_HOST:=(.+)$ ]]
                then
                    POSTGRES_READER_HOST=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^POSTGRES_PORT:=(.+)$ ]]
                then
                    POSTGRES_INTERNAL_PORT=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^SSH_HOST:=(.+)$ ]]
                then
                    SSH_HOST=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^SSH_PORT:=(.+)$ ]]
                then
                    SSH_PORT=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^SSH_PUBLIC_HOST_KEY:=(.+)$ ]]
                then
                    SSH_PUBLIC_HOST_KEY=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^SSH_USERNAME:=(.+)$ ]]
                then
                    SSH_USERNAME=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                elif [[ "$CONN_ITEM" =~ ^SSH_USER_PRIVATE_KEY:=(.+)$ ]]
                then
                    SSH_USER_PRIVATE_KEY=$(normalizeConnItemValue "${BASH_REMATCH[1]}")
                fi
            done

            # The same add-on can be attached to an app multiple times with different
            # config/environment variables, so only set up a secure tunnel if it hasn't already been
            # initialized in a previous iteration
            if [[ ! "${PROCESSED_ENTRIES[*]}" =~ $ADDON_DB_CONN_STR ]]
            then
                PROCESSED_ENTRIES+=("$ADDON_DB_CONN_STR")

                if [[ "$TUNNEL_WRITER_URL_HOST" != "pg-tunnel.borealis-data.com" ]]
                then
                    # The add-on expects the client to register its IP address to connect rather
                    # than use SSH port forwarding
                    BOOT_ID=$(echo -n "$(cat /proc/sys/kernel/random/boot_id)")
                    DYNO_CLIENT_ID="${DYNO}_${BOOT_ID}"
                    curl \
                        --request POST \
                        "${API_BASE_URL}/heroku/resources/${ADDON_ID}/private-app-tunnels" \
                        --header "Authorization: Bearer ${CLIENT_APP_JWT}" \
                        --header "Content-Type: application/json" \
                        --data-raw "{\"clientId\":\"${DYNO_CLIENT_ID}\"}" &>/dev/null || exit $?

                    # Start a process in the background that will wait for the server to shut down
                    # and then destroy the private app tunnel
                    CLIENT_APP_JWT="$CLIENT_APP_JWT" "$BUILDPACK_DIR"/shutdown-wait.sh \
                        "$ADDON_ID" \
                        "$DYNO_CLIENT_ID" \
                        "$API_BASE_URL" &
                else
                    SSH_PRIVATE_KEY_PATH="${SSH_CONFIG_DIR}/borealis-pg_${SSH_USERNAME}_${SSH_HOST}.pem"

                    # Create the SSH configuration directory if it doesn't already exist
                    mkdir -p "$SSH_CONFIG_DIR"
                    chmod 700 "$SSH_CONFIG_DIR"

                    # The SSH private key file doesn't yet exist, so create and populate it
                    echo "$SSH_USER_PRIVATE_KEY" > "$SSH_PRIVATE_KEY_PATH"
                    chmod 400 "$SSH_PRIVATE_KEY_PATH"

                    # Add the SSH server's public host key to known_hosts for server authentication
                    echo "${SSH_HOST} ${SSH_PUBLIC_HOST_KEY}" >> "${SSH_CONFIG_DIR}/known_hosts"

                    # Set up the port forwarding argument(s)
                    WRITER_PORT_FORWARD="${TUNNEL_WRITER_URL_HOST}:${TUNNEL_WRITER_URL_PORT}:${POSTGRES_WRITER_HOST}:${POSTGRES_INTERNAL_PORT}"
                    if [[ -n "$POSTGRES_READER_HOST" ]] && [[ -n "$TUNNEL_READER_URL_PORT" ]]
                    then
                        READER_PORT_FORWARD="${TUNNEL_READER_URL_HOST}:${TUNNEL_READER_URL_PORT}:${POSTGRES_READER_HOST}:${POSTGRES_INTERNAL_PORT}"
                        PORT_FORWARD_ARGS=(-L "$WRITER_PORT_FORWARD" -L "$READER_PORT_FORWARD")
                    else
                        PORT_FORWARD_ARGS=(-L "$WRITER_PORT_FORWARD")
                    fi

                    # Create the SSH tunnel
                    "$AUTOSSH_DIR"/autossh \
                        -M 0 \
                        -f \
                        -N \
                        -o TCPKeepAlive=no \
                        -o ServerAliveCountMax=3 \
                        -o ServerAliveInterval=15 \
                        -o ExitOnForwardFailure=yes \
                        -p "$SSH_PORT" \
                        -i "$SSH_PRIVATE_KEY_PATH" \
                        "${PORT_FORWARD_ARGS[@]}" \
                        "${SSH_USERNAME}@${SSH_HOST}" \
                        || exit $?
                fi
            fi
        fi
    fi
done
