#!/usr/bin/env bash
# Rust handler for repo-maintain

# Handle Rust project updates
# Args: project_dir package_manager
handle_rust() {
    local project_dir="$1"
    local pkg_manager="$2"

    log_info "Processing Rust project: $project_dir"

    if ! check_dependency "cargo"; then
        log_error "cargo not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    cd "$project_dir" || return 1

    # Check if cargo-outdated is installed
    if ! cargo outdated --version &>/dev/null; then
        log_warn "cargo-outdated not installed. Install with: cargo install cargo-outdated"
        log_info "Falling back to cargo update --dry-run"
        handle_cargo_update_fallback
        return $?
    fi

    handle_cargo_outdated
}

# Handle updates using cargo-outdated
handle_cargo_outdated() {
    log_verbose "Checking for outdated cargo packages..."

    local outdated_json
    outdated_json=$(cargo outdated --format json 2>/dev/null) || true

    if [[ -z "$outdated_json" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    # Parse cargo-outdated JSON output
    local dependencies
    dependencies=$(echo "$outdated_json" | jq -r '.dependencies[]? | @json' 2>/dev/null) || true

    if [[ -z "$dependencies" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        local pkg current latest
        pkg=$(echo "$dep" | jq -r '.name')
        current=$(echo "$dep" | jq -r '.project')
        latest=$(echo "$dep" | jq -r '.latest')

        [[ -z "$pkg" || "$current" == "null" || "$latest" == "null" ]] && continue
        [[ "$current" == "---" ]] && continue

        if is_patch_update "$current" "$latest"; then
            log_info "Patch update available: $pkg $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $latest"
                track_update "$(pwd)" "$pkg" "$current" "$latest"
            else
                if cargo update -p "$pkg" --precise "$latest" 2>/dev/null; then
                    log_success "Updated $pkg: $current -> $latest"
                    track_update "$(pwd)" "$pkg" "$current" "$latest"
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$latest"
        fi
    done <<< "$dependencies"
}

# Fallback when cargo-outdated is not installed
handle_cargo_update_fallback() {
    log_verbose "Using cargo update --dry-run to check for updates..."

    local update_output
    update_output=$(cargo update --dry-run 2>&1) || true

    if [[ -z "$update_output" ]]; then
        log_info "No updates available"
        return 0
    fi

    # Parse cargo update --dry-run output
    # Format: Updating crate_name v1.2.3 -> v1.2.4
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" != *"Updating"* ]] && continue

        local pkg current latest
        if [[ "$line" =~ Updating[[:space:]]+([^[:space:]]+)[[:space:]]+v([0-9.]+)[[:space:]]*-\>[[:space:]]*v([0-9.]+) ]]; then
            pkg="${BASH_REMATCH[1]}"
            current="${BASH_REMATCH[2]}"
            latest="${BASH_REMATCH[3]}"
        else
            continue
        fi

        if is_patch_update "$current" "$latest"; then
            log_info "Patch update available: $pkg $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $latest"
                track_update "$(pwd)" "$pkg" "$current" "$latest"
            else
                if cargo update -p "$pkg" --precise "$latest" 2>/dev/null; then
                    log_success "Updated $pkg: $current -> $latest"
                    track_update "$(pwd)" "$pkg" "$current" "$latest"
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$latest"
        fi
    done <<< "$update_output"
}
