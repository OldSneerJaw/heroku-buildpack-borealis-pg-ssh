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


ADDON_ID="$1"
DYNO_CLIENT_ID="$2"
API_BASE_URL="$3"

function _destroy_private_app_tunnel() {
    curl \
        --request DELETE \
        "${API_BASE_URL}/heroku/resources/${ADDON_ID}/private-app-tunnels/${DYNO_CLIENT_ID}" \
        --header "Authorization: Bearer ${CLIENT_APP_JWT}" \
        --header "Content-Type: application/json" &>/dev/null

    exit $?
}

# Clean up the private app tunnel when the server shuts down
trap _destroy_private_app_tunnel EXIT

while true
do
    # Dynos are supposed to be automatically restarted after 24 hours + between 0 and 216 minutes
    # (https://devcenter.heroku.com/articles/dynos#automatic-dyno-restarts), which works out to
    # 27h 36m at most. Wait a bit longer than that to keep the script from exiting while the dyno is
    # still online.
    sleep 27h 48m || exit

    # Under normal operating conditions the dyno should have automatically restarted by the time the
    # preceding sleep command finished. If we got here, Heroku may have been forced to globally
    # disable automatic dyno restarts while troubleshooting a systemic problem on their platform. To
    # ensure there is no interruption to the client app, prolong the private app tunnel registration
    # then sleep again.
    curl \
        --request POST \
        "${API_BASE_URL}/heroku/resources/${ADDON_ID}/private-app-tunnels" \
        --header "Authorization: Bearer ${CLIENT_APP_JWT}" \
        --header "Content-Type: application/json" \
        --data-raw "{\"clientId\":\"${DYNO_CLIENT_ID}\"}" &>/dev/null || exit $?
done
