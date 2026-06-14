#!/usr/bin/env bash
# Run a task remotely on Spark: bring up infra, then invoke `task` (default:
# the full gates). Usage: scripts/run_on_spark.sh [task-args...]
#   scripts/run_on_spark.sh setup     # deps + proto + DB create/migrate
#   scripts/run_on_spark.sh check     # lint + test, both stacks (default)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/env.sh"

args="${*:-check}"

# shellcheck disable=SC2087
ssh -t "${SPARK}" bash -s <<EOF
set -euo pipefail
export PATH="\$HOME/.local/bin:\$PATH"
cd ${REPO_REMOTE}
echo ">> bringing up infra (Postgres+pgvector)"
docker compose -f infra/docker-compose.yml up -d
echo ">> waiting for health"
sleep 8
echo ">> task ${args}"
task ${args}
EOF
