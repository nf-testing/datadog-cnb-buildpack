#!/usr/bin/env bash
# Runtime profile.d script — sourced before the app starts.
# Sets up paths, generates datadog.yaml, and starts the core agent only
# (no trace-agent, no process-agent). System checks: cpu, memory, disk.
set -euo pipefail

APT_DIR="$HOME/.apt"
DD_DIR="$APT_DIR/opt/datadog-agent"
DD_BIN_DIR="$DD_DIR/bin/agent"
DD_CONF_DIR="$APT_DIR/etc/datadog-agent"
DD_LOG_DIR="$APT_DIR/var/log/datadog"
DD_RUN_DIR="$DD_DIR/run"
DATADOG_CONF="$DD_CONF_DIR/datadog.yaml"

mkdir -p "$DD_LOG_DIR" "$DD_RUN_DIR"

# Generate datadog.yaml from the shipped example, patched with our paths.
cp "$DATADOG_CONF.example" "$DATADOG_CONF"
sed -i -e "s|^.*confd_path:.*$|confd_path: $DD_CONF_DIR/conf.d|" "$DATADOG_CONF"
sed -i -e "s|^.*additional_checksd:.*$|additional_checksd: $DD_CONF_DIR/checks.d\nrun_path: $DD_RUN_DIR|" "$DATADOG_CONF"
sed -i -e "s|^.*cloud_provider_metadata:.*$|cloud_provider_metadata: []|" "$DATADOG_CONF"

# The agent binary needs its embedded Python and shared libs at runtime.
PYTHON_DIR=$(find "$DD_DIR/embedded/lib/" -maxdepth 1 -type d -regex ".*/python[2-3]\.[0-9]+" -printf "%f")
export PYTHONPATH="$DD_DIR/embedded/lib:$DD_DIR/embedded/lib/$PYTHON_DIR:$DD_DIR/embedded/lib/$PYTHON_DIR/site-packages:$DD_DIR/embedded/lib/$PYTHON_DIR/plat-linux2:$DD_DIR/embedded/lib/$PYTHON_DIR/lib-tk:$DD_DIR/embedded/lib/$PYTHON_DIR/lib-dynload:$DD_DIR/bin/agent/dist"
export LD_LIBRARY_PATH="$DD_DIR/embedded/lib:$APT_DIR/usr/lib/x86_64-linux-gnu:$APT_DIR/usr/lib"

# Hostname: use the container hostname (unique per replica on Northflank).
# Do NOT use DD_DYNO_HOST — it depends on Heroku's $DYNO/$HEROKU_APP_NAME.
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

# --- start the agent (or don't) -------------------------------------------
if [ -z "${DD_API_KEY:-}" ]; then
  echo "DD_API_KEY not set — Datadog Agent will not start."
elif [ -n "${DISABLE_DATADOG_AGENT:-}" ]; then
  echo "Datadog Agent disabled via DISABLE_DATADOG_AGENT."
else
  export DD_LOG_FILE="$DD_LOG_DIR/datadog.log"
  echo "Starting Datadog Agent on $DD_HOSTNAME"
  bash -c "PYTHONPATH=\"$PYTHONPATH\" LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\" $DD_BIN_DIR/agent run -c \"$DATADOG_CONF\" > \"$DD_LOG_FILE\" 2>&1 &"
fi
