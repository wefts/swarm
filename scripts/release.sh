#!/usr/bin/env bash

# Release script for the Swarm kernel.
# Uses git-cliff to generate the changelog and determine the next version, then
# keeps mix.exs in step. Mirrors scripts/release.sh in infra-core; the swarm
# specifics are the mix.exs bump and the image-tag reminder.
#
# It does NOT commit, tag, or push. Those are deliberate human acts here
# (workspace guardrails: nothing leaves the machine without being asked).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" &> /dev/null && pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
cd "$PROJECT_ROOT"

MIX_EXS="kernel/mix.exs"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

if ! command -v git-cliff &> /dev/null; then
    log_error "git-cliff is not installed. Install it first:"
    echo "   cargo install git-cliff"
    echo "   or"
    echo "   brew install git-cliff"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    log_error "Working tree is dirty. Commit or stash first — a release must describe committed work."
    git status --short
    exit 1
fi

current_mix_version=$(grep -m1 -oE 'version: "[0-9]+\.[0-9]+\.[0-9]+"' "$MIX_EXS" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
log_info "mix.exs version: ${current_mix_version}"

if ! git describe --tags --abbrev=0 &>/dev/null; then
    log_warning "No tags found in this repository."
    echo "This is the first release. Tag the currently-released commit, then re-run:"
    echo ""
    echo "   git tag -a v${current_mix_version} -m 'Release v${current_mix_version}' <released-commit>"
    echo "   scripts/release.sh"
    exit 0
fi

current_tag=$(git describe --tags --abbrev=0)
log_info "Current tag: ${current_tag}"

log_info "Using git-cliff to determine the next version..."

if ! git cliff --bump --output CHANGELOG.md; then
    log_warning "git-cliff could not generate a changelog."
    echo "Usually this means no releasable commits since ${current_tag}."
    echo "To force a patch release:"
    next_patch=$(echo "$current_tag" | sed 's/^v//' | awk -F. '{print $1"."$2"."$3+1}')
    echo "   git cliff --tag v${next_patch} --output CHANGELOG.md"
    exit 1
fi

log_success "CHANGELOG.md updated."

next_version=$(head -10 CHANGELOG.md | grep -oE '\[([0-9]+\.[0-9]+\.[0-9]+)\]' | head -1 | tr -d '[]')

if [ -z "$next_version" ]; then
    log_warning "Could not determine the next version from CHANGELOG.md — check it by hand."
    exit 1
fi

log_info "Next version: v${next_version}"

# Keep mix.exs in step: the kernel version is what the container image is tagged with.
if [ "$current_mix_version" != "$next_version" ]; then
    sed -i.bak -E "0,/version: \"[0-9]+\.[0-9]+\.[0-9]+\"/s//version: \"${next_version}\"/" "$MIX_EXS"
    rm -f "${MIX_EXS}.bak"
    log_success "Bumped ${MIX_EXS} ${current_mix_version} -> ${next_version}"
else
    log_info "${MIX_EXS} already at ${next_version}"
fi

echo ""
log_info "Changelog preview:"
echo "----------------------------------------"
head -20 CHANGELOG.md
echo "----------------------------------------"
echo ""

log_success "Ready for release."
echo ""
log_info "Next steps (run them yourself — this script never commits, tags, or pushes):"
echo "   git add CHANGELOG.md ${MIX_EXS}"
echo "   git commit -m 'chore(release): prepare for v${next_version}'"
echo "   git tag -a v${next_version} -m 'Release v${next_version}'"
echo ""
log_info "Then, in the hive deployment:"
echo "   set SWARM_KERNEL_VERSION=${next_version} in hive/env/base.env"
echo "   keep a rollback handle:  docker tag swarm-kernel:${current_mix_version} swarm-kernel:${current_mix_version}-rollback"
echo "   build + deploy:          SWARM_ENV=staging scripts/compose build kernel && task deploy SERVICE=kernel"
