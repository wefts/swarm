# Shared config for the Spark sync/run scripts. Override via real env vars.
# Source me: `. scripts/env.sh`

# SSH target. Leave SSH_USER empty to let ssh config resolve the user/identity
# (the `dgx_spark` host alias authenticates without user@).
export SPARK_HOST="${SPARK_HOST:-dgx_spark}"
export SSH_USER="${SSH_USER:-}"
export SPARK="${SSH_USER:+${SSH_USER}@}${SPARK_HOST}"

# Canonical repo location on Spark (system architecture §13).
export REPO_REMOTE="${REPO_REMOTE:-\$HOME/Swarm/swarm}"

# Excluded from sync (regenerated on each side; never transferred).
RSYNC_EXCLUDES=(
  --exclude '.venv'
  --exclude '__pycache__'
  --exclude '*.pyc'
  --exclude '.ruff_cache'
  --exclude '.mypy_cache'
  --exclude '.pytest_cache'
  --exclude '_build'
  --exclude 'deps'
  --exclude '.elixir_ls'
  --exclude 'node_modules'
)
export RSYNC_EXCLUDES
