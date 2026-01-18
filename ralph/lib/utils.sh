#!/usr/bin/env bash
# Shared utilities for repo-maintain

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Global flags
DRY_RUN=false
VERBOSE=false

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${GRAY}[DEBUG]${NC} $*"
    fi
}

# Parse semver version string
# Returns: major minor patch (space-separated)
parse_semver() {
    local version="$1"
    # Remove leading 'v' if present
    version="${version#v}"
    # Remove any pre-release or build metadata
    version="${version%%-*}"
    version="${version%%+*}"

    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"

    # Default to 0 if empty
    major="${major:-0}"
    minor="${minor:-0}"
    patch="${patch:-0}"

    # Extract only numeric parts
    major="${major//[^0-9]/}"
    minor="${minor//[^0-9]/}"
    patch="${patch//[^0-9]/}"

    echo "$major $minor $patch"
}

# Classify update type: "patch", "minor", "major", or "none"
classify_update() {
    local current="$1"
    local available="$2"

    read -r cur_major cur_minor cur_patch <<< "$(parse_semver "$current")"
    read -r avail_major avail_minor avail_patch <<< "$(parse_semver "$available")"

    if [[ "$cur_major" != "$avail_major" ]]; then
        echo "major"
    elif [[ "$cur_minor" != "$avail_minor" ]]; then
        echo "minor"
    elif [[ "$avail_patch" -gt "$cur_patch" ]]; then
        echo "patch"
    else
        echo "none"
    fi
}

# Check if update is patch-only
# Returns 0 if patch-only, 1 otherwise
is_patch_update() {
    local current="$1"
    local available="$2"

    local update_type
    update_type=$(classify_update "$current" "$available")

    log_verbose "Comparing $current -> $available (${update_type} update)"

    if [[ "$update_type" == "patch" ]]; then
        return 0
    fi

    return 1
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check required dependencies
check_dependency() {
    local cmd="$1"
    local name="${2:-$1}"

    if ! command_exists "$cmd"; then
        log_error "$name is required but not installed"
        return 1
    fi
    return 0
}

# Summary tracking
TOTAL_UPDATES=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

# Arrays to track details
declare -a APPLIED_UPDATES=()
declare -a SKIPPED_MAJOR=()
declare -a SKIPPED_MINOR=()

track_update() {
    local project="$1"
    local pkg="$2"
    local from="$3"
    local to="$4"
    TOTAL_UPDATES=$((TOTAL_UPDATES + 1))
    APPLIED_UPDATES+=("${pkg}|${from}|${to}")
}

# Track skipped update with classification
track_skip_versioned() {
    local pkg="$1"
    local current="$2"
    local available="$3"
    local update_type
    update_type=$(classify_update "$current" "$available")

    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))

    if [[ "$update_type" == "major" ]]; then
        SKIPPED_MAJOR+=("${pkg}|${current}|${available}")
    elif [[ "$update_type" == "minor" ]]; then
        SKIPPED_MINOR+=("${pkg}|${current}|${available}")
    fi
}

track_skip() {
    local reason="$1"
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
}

track_failure() {
    local reason="$1"
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
}

print_summary() {
    echo ""
    echo "========================================"
    echo "           Update Summary"
    echo "========================================"

    # Applied updates
    if [[ $TOTAL_UPDATES -gt 0 ]]; then
        echo -e "${GREEN}Patch updates applied: $TOTAL_UPDATES${NC}"
        for entry in "${APPLIED_UPDATES[@]}"; do
            IFS='|' read -r pkg from to <<< "$entry"
            echo -e "  ${GREEN}✓${NC} $pkg: $from -> $to"
        done
    else
        echo -e "Patch updates applied: 0"
    fi

    echo ""

    # Skipped minor updates
    if [[ ${#SKIPPED_MINOR[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Minor updates available: ${#SKIPPED_MINOR[@]}${NC} (use --include-minor to apply)"
        for entry in "${SKIPPED_MINOR[@]}"; do
            IFS='|' read -r pkg from to <<< "$entry"
            echo -e "  ${YELLOW}○${NC} $pkg: $from -> $to"
        done
        echo ""
    fi

    # Skipped major updates
    if [[ ${#SKIPPED_MAJOR[@]} -gt 0 ]]; then
        echo -e "${CYAN}Major updates available: ${#SKIPPED_MAJOR[@]}${NC} (manual update recommended)"
        for entry in "${SKIPPED_MAJOR[@]}"; do
            IFS='|' read -r pkg from to <<< "$entry"
            echo -e "  ${CYAN}○${NC} $pkg: $from -> $to"
        done
        echo ""
    fi

    # Failures
    if [[ $TOTAL_FAILED -gt 0 ]]; then
        echo -e "${RED}Failed updates: $TOTAL_FAILED${NC}"
    fi

    echo "========================================"
}
