#!/usr/bin/env bash

SSH_CONFIG_DIR="${HOME}/.ssh"
CONN_INFO_ENV_VAR_PATTERN='^(.+)_SSH_TUNNEL_BPG_CONNECTION_INFO$'
PG_URL_PATTERN='^postgres(ql)?://[^@]+@[^:]+:([[:digit:]]+)/.+$'

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
            # Retrieve the local port for the writer SSH tunnel from the "*_URL" env var value
            SSH_TUNNEL_WRITER_LOCAL_PORT="${BASH_REMATCH[2]}"

            # Retrieve the local port for the reader SSH tunnel from the "*_READONLY_URL" env var value, if it exists
            ADDON_READONLY_DB_CONN_STR=$(printenv "${ADDON_ENV_VAR_PREFIX}_READONLY_URL" || echo '')
            if [[ "$ADDON_READONLY_DB_CONN_STR" =~ $PG_URL_PATTERN ]]
            then
                SSH_TUNNEL_READER_LOCAL_PORT="${BASH_REMATCH[2]}"
            fi

            POSTGRES_INTERNAL_PORT="5432"

            # Retrieve the SSH tunnel connection details from the base64-encoded SSH connection info env var
            SSH_CONNECTION_INFO=$(printenv "$ENV_VAR")
            IFS=$'|' read -r -d '' -a CONN_INFO_ARRAY <<< "$SSH_CONNECTION_INFO"
            for CONN_ITEM in "${CONN_INFO_ARRAY[@]}"
            do
                if [[ "$CONN_ITEM" =~ ^POSTGRES_WRITER_HOST:=(.+)$ ]]
                then
                    POSTGRES_WRITER_HOST="${BASH_REMATCH[1]}"
                elif [[ "$CONN_ITEM" =~ ^POSTGRES_READER_HOST:=(.+)$ ]]
                then
                    POSTGRES_READER_HOST="${BASH_REMATCH[1]}"
                elif [[ "$CONN_ITEM" =~ ^POSTGRES_INTERNAL_PORT:=(.+)$ ]]
                then
                    POSTGRES_INTERNAL_PORT="${BASH_REMATCH[1]}"
                elif [[ "$CONN_ITEM" =~ ^SSH_HOST:=(.+)$ ]]
                then
                    SSH_HOST="${BASH_REMATCH[1]}"
                elif [[ "$CONN_ITEM" =~ ^SSH_PUBLIC_HOST_KEY:=(.+)$ ]]
                then
                    SSH_PUBLIC_HOST_KEY="${BASH_REMATCH[1]}"
                elif [[ "$CONN_ITEM" =~ ^SSH_USERNAME:=(.+)$ ]]
                then
                    SSH_USERNAME="${BASH_REMATCH[1]}"
                elif [[ "$CONN_ITEM" =~ ^SSH_USER_PRIVATE_KEY:=(.+)$ ]]
                then
                    SSH_USER_PRIVATE_KEY="${BASH_REMATCH[1]//\\n/$'\n'}"
                fi
            done

            # The same add-on can be attached to an app multiple times with different environment variables, so only set
            # up the port forwarding if the SSH private key file hasn't already been created by a previous iteration
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
                WRITER_PORT_FORWARD="localhost:${SSH_TUNNEL_WRITER_LOCAL_PORT}:${POSTGRES_WRITER_HOST}:${POSTGRES_INTERNAL_PORT}"
                if [[ -n "$POSTGRES_READER_HOST" ]] && [[ -n "$SSH_TUNNEL_READER_LOCAL_PORT" ]]
                then
                    READER_PORT_FORWARD="localhost:${SSH_TUNNEL_READER_LOCAL_PORT}:${POSTGRES_READER_HOST}:${POSTGRES_INTERNAL_PORT}"
                    PORT_FORWARD_ARGS=(-L "$WRITER_PORT_FORWARD" -L "$READER_PORT_FORWARD")
                else
                    PORT_FORWARD_ARGS=(-L "$WRITER_PORT_FORWARD")
                fi

                # Create the SSH tunnel
                "$HOME"/.borealis-pg/autossh/autossh \
                    -M 0 \
                    -f \
                    -N \
                    -o TCPKeepAlive=no \
                    -o ServerAliveCountMax=3 \
                    -o ServerAliveInterval=15 \
                    -i "$SSH_PRIVATE_KEY_PATH" \
                    "${PORT_FORWARD_ARGS[@]}" \
                    "${SSH_USERNAME}@${SSH_HOST}" \
                    || exit $?
            fi
        fi
    fi
done
