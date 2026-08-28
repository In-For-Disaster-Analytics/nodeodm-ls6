#!/bin/bash
#
# lib/tap_auth.sh - TAP certificate, token, port forwarding, webhook
# Source SECOND - no dependencies on other modules
#

[[ -n "${_LIB_TAP_AUTH_SH:-}" ]] && return 0
readonly _LIB_TAP_AUTH_SH=1

# =============================================================================
# TAP FUNCTIONS
# =============================================================================
get_tap_certificate() {
    mkdir -p ${HOME}/.tap # this should exist at this point, but just in case...
    export TAP_CERTFILE=${HOME}/.tap/.${SLURM_JOB_ID}
    # bail if we cannot create a secure session
    if [ ! -f ${TAP_CERTFILE} ]; then
        echo "TACC: ERROR - could not find TLS cert for secure session"
        echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
        exit 1
    fi
}

get_tap_token() {
    # bail if we cannot create a token for the session
    TAP_TOKEN=$(tap_get_token)
    if [ -z "${TAP_TOKEN}" ]; then
        echo "TACC: ERROR - could not generate token for odm session"
        echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
        exit 1
    fi
    echo "TACC: using token ${TAP_TOKEN}"
    export TAP_TOKEN
    LOGIN_PORT=$(tap_get_port)
    export LOGIN_PORT
}

load_tap_functions() {
    TAP_FUNCTIONS="/share/doc/slurm/tap_functions"
    if [ -f ${TAP_FUNCTIONS} ]; then
        . ${TAP_FUNCTIONS}
    else
        echo "TACC:"
        echo "TACC: ERROR - could not find TAP functions file: ${TAP_FUNCTIONS}"
        echo "TACC: ERROR - Please submit a consulting ticket at the TACC user portal"
        echo "TACC: ERROR - https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
        echo "TACC:"
        echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
        exit 1
    fi
}

# =============================================================================
# PORT FORWARDING (TAP TUNNEL)
# =============================================================================
port_forwarding_tap() {
    LOCAL_PORT=$NODEODM_PORT
    echo "[TAP] (${NODEODM_CHILD_INDEX:-primary}) attempting TAP tunnel on LOGIN_PORT=${LOGIN_PORT:-n/a} for local port $LOCAL_PORT"
    # Disable exit on error so we can check the ssh tunnel status.
    set +e
    for i in $(seq 2); do
        ssh -o StrictHostKeyChecking=no -q -f -g -N -R ${LOGIN_PORT}:${HOSTNAME}:${LOCAL_PORT} login${i}
    done
    if [ $(ps -fu ${USER} | grep ssh | grep login | grep -vc grep) != 2 ]; then
        echo "TACC: ERROR - ssh tunnels failed to launch"
        echo "TACC: ERROR - this is often due to an issue with your ssh keys"
        echo "TACC: ERROR - undo any recent mods in ${HOME}/.ssh"
        echo "TACC: ERROR - or submit a TACC consulting ticket with this error"
        echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
        return 1
    fi
    # Re-enable exit on error.
    set -e
    NODEODM_URL="http://ls6.tacc.utexas.edu:${LOGIN_PORT}/?token=${TAP_TOKEN}"
    echo "TACC: NodeODM should be available at: ${NODEODM_URL}"
    return 0
}

# =============================================================================
# WEBHOOK NOTIFICATIONS
# =============================================================================
send_url_to_webhook() {
    # Session-ready webhook back to the interactive service so users know the tunnel URL.
    if [ -z "${_webhook_base_url:-}" ]; then
        echo "Skipping session_ready webhook: _webhook_base_url is not set"
        return
    fi

    local host="ls6.tacc.utexas.edu"
    local scheme="https"
    if [ -n "${_webhook_use_http:-}" ]; then
        scheme="http"
    fi
    NODEODM_URL="${scheme}://${host}:${LOGIN_PORT}/?token=${TAP_TOKEN}"
    INTERACTIVE_WEBHOOK_URL="${_webhook_base_url%/}"

    echo "Sending session_ready webhook to ${INTERACTIVE_WEBHOOK_URL} with address=${NODEODM_URL}"
    (
        sleep 5
        pkill -0 $$ || exit 0
        local resp
        resp=$(curl -k -s -w " HTTP_CODE:%{http_code}" \
            --data "event_type=nodeodm_session_ready&address=${NODEODM_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}&service_type=nodeodm&clusterodm_url=${CLUSTERODM_URL}" \
            "${INTERACTIVE_WEBHOOK_URL}" 2>&1)
        echo "session_ready webhook response: ${resp}"
    ) &
}

# =============================================================================
# PTDATAX STATUS WEBHOOK
# =============================================================================
send_nodeodm_status_to_ptdatax() {
    # PTDATAX webhook disabled for local/idev testing
    return 0
}

# =============================================================================
# COMPLETION SERVER
# =============================================================================
start_completion_server() {
    if [[ "${NODEODM_COMPLETE_ENABLE:-0}" != "1" ]]; then
        echo "Completion server disabled (NODEODM_COMPLETE_ENABLE=${NODEODM_COMPLETE_ENABLE})"
        return 0
    fi
    if [[ "${NODEODM_CHILD:-0}" == "1" ]]; then
        echo "Skipping completion server on child instance (NODEODM_CHILD=1)"
        return 0
    fi
    if [[ "${NODEODM_ROLE:-admin}" != "admin" ]]; then
        echo "Skipping completion server on non-admin role (${NODEODM_ROLE})"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not available; cannot start completion server"
        return 0
    fi

    export NODEODM_COMPLETE_FLAG="$COMPLETE_FLAG"
    export NODEODM_COMPLETE_TOKEN="${NODEODM_COMPLETE_TOKEN:-$TAP_TOKEN}"
    export NODEODM_COMPLETE_PORT

    echo "Starting completion server on port ${NODEODM_COMPLETE_PORT} (flag: ${COMPLETE_FLAG})"
    python3 - <<'PY' &
import http.server
import os
import urllib.parse

flag = os.environ.get("NODEODM_COMPLETE_FLAG", "/tmp/nodeodm_complete.flag")
token = os.environ.get("NODEODM_COMPLETE_TOKEN", "")
port = int(os.environ.get("NODEODM_COMPLETE_PORT", "3010"))

class Handler(http.server.BaseHTTPRequestHandler):
    def _ok(self, msg):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode("utf-8"))

    def _forbidden(self):
        self.send_response(403)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"forbidden")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/complete":
            self.send_response(404)
            self.end_headers()
            return
        qs = urllib.parse.parse_qs(parsed.query)
        req_token = qs.get("token", [""])[0]
        if token and req_token != token:
            return self._forbidden()
        os.makedirs(os.path.dirname(flag), exist_ok=True)
        with open(flag, "w") as f:
            f.write("complete\n")
        return self._ok("ok")

    def do_POST(self):
        return self.do_GET()

    def log_message(self, fmt, *args):
        pass

http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
    COMPLETION_SERVER_PID=$!
    echo "Completion server PID: $COMPLETION_SERVER_PID"
}

wait_for_completion_signal() {
    local wait_sec=${NODEODM_COMPLETE_WAIT_SEC:-1800}
    local waited=0
    if [[ "${NODEODM_COMPLETE_ENABLE:-0}" != "1" ]]; then
        return 0
    fi
    if [ -f "$COMPLETE_FLAG" ]; then
        echo "Completion flag already present: $COMPLETE_FLAG"
        return 0
    fi
    echo "Waiting for completion signal (up to ${wait_sec}s)..."
    while [ "$waited" -lt "$wait_sec" ]; do
        if [ -f "$COMPLETE_FLAG" ]; then
            echo "Completion signal received."
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    echo "Completion signal not received within ${wait_sec}s; continuing."
    return 0
}