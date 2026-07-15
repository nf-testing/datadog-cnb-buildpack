#!/usr/bin/env bash
# CNB exec.d binary — runs before the app starts (per CNB platform spec).
#
# Sets up the Datadog Agent (paths, datadog.yaml, hostname, tags) and starts it
# in the background. Emits DD_HOSTNAME to fd 3 so the app can confirm via /env
# that this script ran.
#
# Per CNB spec:
#   - Exit 0 = success; non-zero blocks app launch (so we always exit 0).
#   - Output to fd 3 = TOML key="value" pairs added to the app's runtime env.
#   - PWD is the app dir (/workspace on Northflank).
#   - Inherits runtime env (DD_API_KEY etc. from Northflank config vars).

# Wrap all setup in a function so any failure is caught and doesn't block app.
run() {
  local APT_DIR="${PWD}/.apt"
  local DD_DIR="$APT_DIR/opt/datadog-agent"
  local DD_BIN_DIR="$DD_DIR/bin/agent"
  local DD_CONF_DIR="$APT_DIR/etc/datadog-agent"
  local DD_LOG_DIR="$APT_DIR/var/log/datadog"
  local DD_RUN_DIR="$DD_DIR/run"
  local DATADOG_CONF="$DD_CONF_DIR/datadog.yaml"

  mkdir -p "$DD_LOG_DIR" "$DD_RUN_DIR"

  # Generate datadog.yaml from the shipped example, patched with our paths.
  cp "$DATADOG_CONF.example" "$DATADOG_CONF"
  sed -i -e "s|^.*confd_path:.*$|confd_path: $DD_CONF_DIR/conf.d|" "$DATADOG_CONF"
  sed -i -e "s|^.*additional_checksd:.*$|additional_checksd: $DD_CONF_DIR/checks.d\nrun_path: $DD_RUN_DIR|" "$DATADOG_CONF"
  sed -i -e "s|^.*cloud_provider_metadata:.*$|cloud_provider_metadata: []|" "$DATADOG_CONF"

  # The agent binary needs its embedded Python and shared libs at runtime.
  local PYTHON_DIR
  PYTHON_DIR=$(find "$DD_DIR/embedded/lib/" -maxdepth 1 -type d -regex ".*/python[2-3]\.[0-9]+" -printf "%f")
  export PYTHONPATH="$DD_DIR/embedded/lib:$DD_DIR/embedded/lib/$PYTHON_DIR:$DD_DIR/embedded/lib/$PYTHON_DIR/site-packages:$DD_DIR/embedded/lib/$PYTHON_DIR/plat-linux2:$DD_DIR/embedded/lib/$PYTHON_DIR/lib-tk:$DD_DIR/embedded/lib/$PYTHON_DIR/lib-dynload:$DD_DIR/bin/agent/dist"
  export LD_LIBRARY_PATH="$DD_DIR/embedded/lib:$APT_DIR/usr/lib/x86_64-linux-gnu:$APT_DIR/usr/lib"

  # Hostname: use the container hostname (unique per replica on Northflank).
  if [ -z "${DD_HOSTNAME:-}" ]; then
    export DD_HOSTNAME="$(hostname | sed -e 's/[^a-zA-Z0-9-]/-/g' -e 's/^-//g')"
  fi

  # Tags: merge buildpack default tags with user-provided DD_TAGS.
  DD_TAGS="buildpackversion:northflank-cnb-0.1.0 ${DD_TAGS:-}"
  # datadog.yaml expects space-separated; normalize commas from env var.
  DD_TAGS="$(echo "$DD_TAGS" | sed "s/,[ ]\?/ /g")"
  export DD_TAGS

  # Mark install provenance.
  echo -e "install_method:\n  tool: heroku\n  tool_version: heroku\n  installer_version: heroku-northflank-cnb-0.1.0" > "$DD_CONF_DIR/install_info"

  # Disable host-level /proc checks if requested (step 3 of checklist may want this).
  if [ "${DD_DISABLE_HOST_METRICS:-}" = "true" ]; then
    find "$DD_CONF_DIR"/conf.d -name "conf.yaml.default" -exec mv {} {}_disabled \;
  fi

  # Emit DD_HOSTNAME to fd 3 so the app's /env endpoint can confirm exec.d ran.
  # (TOML key="value" format per CNB spec.)
  printf 'DD_HOSTNAME="%s"\n' "$DD_HOSTNAME" >&3

  # --- start the agent (or don't) -------------------------------------------
  # PID file guards against duplicate agent starts: exec.d runs in every shell
  # session the launcher creates (app start, Northflank SSH sessions, etc.).
  # Without this guard, every SSH session would spawn another agent.
  local PID_FILE="$DD_RUN_DIR/agent.pid"

  if [ -z "${DD_API_KEY:-}" ]; then
    echo "[datadog-execd] DD_API_KEY not set - agent will not start"
  elif [ -n "${DISABLE_DATADOG_AGENT:-}" ]; then
    echo "[datadog-execd] Datadog Agent disabled via DISABLE_DATADOG_AGENT"
  elif [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "[datadog-execd] Agent already running (pid $(cat "$PID_FILE")), not starting another"
  else
    export DD_LOG_FILE="$DD_LOG_DIR/datadog.log"
    echo "[datadog-execd] Starting Datadog Agent on $DD_HOSTNAME"
    # CRITICAL: close fd 3 in the backgrounded agent. The launcher reads fd 3
    # until EOF before exec'ing the app; if the agent keeps fd 3 open, the
    # launcher blocks forever and the app never starts. Also redirect stdin
    # from /dev/null so the agent doesn't hold the launcher's stdin either.
    # --pidfile is passed to the agent AND we echo $! to our own pid file so
    # the guard above can detect a live agent on subsequent exec.d runs.
    bash -c "PYTHONPATH=\"$PYTHONPATH\" LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\" $DD_BIN_DIR/agent run --pidfile=\"$PID_FILE\" -c \"$DATADOG_CONF\" < /dev/null > \"$DD_LOG_FILE\" 2>&1 3>&- &"
  fi
}

run || echo "[datadog-execd] setup failed (non-fatal), agent may not have started" >&2
exit 0
