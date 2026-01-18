#!/usr/bin/env bash
#
# repo-maintain.sh - Repository Maintenance Tool
#
# Automatically detects project types in a repository (including monorepos),
# checks for dependency updates, and applies patch-version-only updates.
#
# Usage: ./repo-maintain.sh <directory> [options]
#
# Options:
#   --dry-run       Show what would be updated without applying
#   --verbose       Enable verbose output
#   --help          Show this help message
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library files
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/handlers/nodejs.sh"
source "$SCRIPT_DIR/lib/handlers/python.sh"
source "$SCRIPT_DIR/lib/handlers/rust.sh"
source "$SCRIPT_DIR/lib/handlers/java.sh"
source "$SCRIPT_DIR/lib/handlers/go.sh"

# Print usage information
usage() {
    cat << EOF
Repository Maintenance Tool

Automatically detects project types in a repository (including monorepos),
checks for dependency updates, and applies patch-version-only updates.

Usage: $(basename "$0") <directory> [options]

Arguments:
  <directory>      Path to the repository to maintain

Options:
  --dry-run        Show what would be updated without applying changes
  --verbose        Enable verbose output for debugging
  --help           Show this help message and exit

Examples:
  $(basename "$0") /path/to/repo                 # Update all projects
  $(basename "$0") /path/to/repo --dry-run       # Preview updates only
  $(basename "$0") /path/to/repo --verbose       # Verbose output

Supported Ecosystems:
  - Node.js (npm, yarn, pnpm, bun)
  - Python (pip, poetry, uv, pipenv)
  - Rust (cargo)
  - Java (Maven, Gradle)
  - Go (go modules)

EOF
}

# Parse command line arguments
parse_args() {
    local positional_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                positional_args+=("$1")
                shift
                ;;
        esac
    done

    # Set positional arguments
    if [[ ${#positional_args[@]} -eq 0 ]]; then
        log_error "No directory specified"
        usage
        exit 1
    fi

    TARGET_DIR="${positional_args[0]}"
}

# Check required dependencies
check_requirements() {
    if ! check_dependency "jq"; then
        log_error "jq is required for JSON parsing. Install it with your package manager."
        exit 1
    fi
}

# Process a single project
process_project() {
    local ecosystem="$1"
    local pkg_manager="$2"
    local project_dir="$3"

    log_verbose "Processing: ecosystem=$ecosystem, manager=$pkg_manager, dir=$project_dir"

    # Save current directory
    local original_dir
    original_dir=$(pwd)

    case "$ecosystem" in
        nodejs)
            handle_nodejs "$project_dir" "$pkg_manager"
            ;;
        python)
            handle_python "$project_dir" "$pkg_manager"
            ;;
        rust)
            handle_rust "$project_dir" "$pkg_manager"
            ;;
        java)
            handle_java "$project_dir" "$pkg_manager"
            ;;
        go)
            handle_go "$project_dir" "$pkg_manager"
            ;;
        *)
            log_warn "Unknown ecosystem: $ecosystem"
            ;;
    esac

    # Return to original directory
    cd "$original_dir" || true
}

# Main function
main() {
    parse_args "$@"

    # Validate target directory
    if [[ ! -d "$TARGET_DIR" ]]; then
        log_error "Directory does not exist: $TARGET_DIR"
        exit 1
    fi

    # Convert to absolute path
    TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

    log_info "Repository Maintenance Tool"
    log_info "Target directory: $TARGET_DIR"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode: DRY-RUN (no changes will be made)"
    fi

    echo ""

    # Check requirements
    check_requirements

    # Find all projects
    log_info "Scanning for projects..."
    local projects
    projects=$(find_projects "$TARGET_DIR")

    if [[ -z "$projects" ]]; then
        log_info "No projects found in $TARGET_DIR"
        exit 0
    fi

    # Count projects
    local project_count
    project_count=$(echo "$projects" | wc -l)
    log_info "Found $project_count project(s)"
    echo ""

    # Process each project
    while IFS='|' read -r ecosystem pkg_manager project_dir; do
        [[ -z "$ecosystem" ]] && continue

        echo "----------------------------------------"
        process_project "$ecosystem" "$pkg_manager" "$project_dir"
        echo ""
    done <<< "$projects"

    # Print summary
    print_summary
}

# Run main function
main "$@"
