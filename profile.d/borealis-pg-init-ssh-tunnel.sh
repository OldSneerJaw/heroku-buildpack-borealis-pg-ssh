#!/usr/bin/env bash


# MIT License

# Copyright Borealis Data Solutions

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


CONN_INFO_ENV_VAR_PATTERN='^(.+)_SSH_TUNNEL_BPG_CONNECTION_INFO$'
PG_URL_PATTERN='^postgres(ql)?://[^@]+@([^:]+):([[:digit:]]+)/.+$'
SSH_CONFIG_DIR="${HOME}/.ssh"
DEFAULT_AUTOSSH_DIR="${HOME}/.borealis-pg/autossh"

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
    if [[ "$ENV_VAR" =~ $CONN_INFO_ENV_VAR_PATTERN ]]
    then
        ADDON_ENV_VAR_PREFIX="${BASH_REMATCH[1]}"

        # There should be a corresponding "*_URL" connection string environment variable
        ADDON_DB_CONN_STR=$(printenv "${ADDON_ENV_VAR_PREFIX}_URL" || echo '')
        if [[ "$ADDON_DB_CONN_STR" =~ $PG_URL_PATTERN ]]
        then
            # Retrieve the local host and port for the writer SSH tunnel from the "*_URL" env var
            # value
            TUNNEL_WRITER_LOCAL_HOST="${BASH_REMATCH[2]}"
            TUNNEL_WRITER_LOCAL_PORT="${BASH_REMATCH[3]}"

            # Retrieve the local host and port for the reader SSH tunnel from the "*_READONLY_URL"
            # env var value, if it exists
            ADDON_READONLY_DB_CONN_STR=$(printenv "${ADDON_ENV_VAR_PREFIX}_READONLY_URL" || echo '')
            if [[ "$ADDON_READONLY_DB_CONN_STR" =~ $PG_URL_PATTERN ]]
            then
                TUNNEL_READER_LOCAL_HOST="${BASH_REMATCH[2]}"
                TUNNEL_READER_LOCAL_PORT="${BASH_REMATCH[3]}"
            fi

            POSTGRES_INTERNAL_PORT="5432"
            SSH_PORT="22"

            # Retrieve the SSH tunnel connection details from the SSH connection info env var
            SSH_CONNECTION_INFO=$(printenv "$ENV_VAR")
            IFS=$'|' read -r -d '' -a CONN_INFO_ARRAY <<< "$SSH_CONNECTION_INFO"
            for CONN_ITEM in "${CONN_INFO_ARRAY[@]}"
            do
                if [[ "$CONN_ITEM" =~ ^POSTGRES_WRITER_HOST:=(.+)$ ]]
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

            # The same add-on can be attached to an app multiple times with different environment
            # variables, so only set up port forwarding if the SSH private key file hasn't already
            # been created by a previous iteration
            SSH_PRIVATE_KEY_PATH="${SSH_CONFIG_DIR}/borealis-pg_${SSH_USERNAME}_${SSH_HOST}.pem"
            if [[ ! -e "$SSH_PRIVATE_KEY_PATH" ]]
            then
                # Create the SSH configuration directory if it doesn't already exist
                mkdir -p "$SSH_CONFIG_DIR"
                chmod 700 "$SSH_CONFIG_DIR"

                # The SSH private key file doesn't yet exist, so create and populate it
                echo "$SSH_USER_PRIVATE_KEY" > "$SSH_PRIVATE_KEY_PATH"
                chmod 400 "$SSH_PRIVATE_KEY_PATH"

                # Add the SSH server's public host key to known_hosts for server authentication
                echo "${SSH_HOST} ${SSH_PUBLIC_HOST_KEY}" >> "${SSH_CONFIG_DIR}/known_hosts"

                # Set up the port forwarding argument(s)
                WRITER_PORT_FORWARD="${TUNNEL_WRITER_LOCAL_HOST}:${TUNNEL_WRITER_LOCAL_PORT}:${POSTGRES_WRITER_HOST}:${POSTGRES_INTERNAL_PORT}"
                if [[ -n "$POSTGRES_READER_HOST" ]] && [[ -n "$TUNNEL_READER_LOCAL_PORT" ]]
                then
                    READER_PORT_FORWARD="${TUNNEL_READER_LOCAL_HOST}:${TUNNEL_READER_LOCAL_PORT}:${POSTGRES_READER_HOST}:${POSTGRES_INTERNAL_PORT}"
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
done
