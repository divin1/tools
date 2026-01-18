#!/usr/bin/env bash
# Node.js handler for repo-maintain

# Handle Node.js project updates
# Args: project_dir package_manager
handle_nodejs() {
    local project_dir="$1"
    local pkg_manager="$2"

    log_info "Processing Node.js project: $project_dir (using $pkg_manager)"

    # Check if package manager is available
    if ! check_dependency "$pkg_manager"; then
        log_error "Package manager '$pkg_manager' not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    cd "$project_dir" || return 1

    case "$pkg_manager" in
        npm)
            handle_npm_updates
            ;;
        yarn)
            handle_yarn_updates
            ;;
        pnpm)
            handle_pnpm_updates
            ;;
        bun)
            handle_bun_updates
            ;;
        *)
            log_error "Unknown Node.js package manager: $pkg_manager"
            return 1
            ;;
    esac
}

# Handle npm updates
handle_npm_updates() {
    log_verbose "Checking for outdated npm packages..."

    local outdated_json
    outdated_json=$(npm outdated --json 2>/dev/null) || true

    if [[ -z "$outdated_json" || "$outdated_json" == "{}" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    # Parse JSON and check each package
    local packages
    packages=$(echo "$outdated_json" | jq -r 'keys[]')

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        local current wanted latest
        current=$(echo "$outdated_json" | jq -r --arg pkg "$pkg" '.[$pkg].current // empty')
        wanted=$(echo "$outdated_json" | jq -r --arg pkg "$pkg" '.[$pkg].wanted // empty')
        latest=$(echo "$outdated_json" | jq -r --arg pkg "$pkg" '.[$pkg].latest // empty')

        [[ -z "$current" ]] && continue

        # Check if wanted version is a patch update
        if is_patch_update "$current" "$wanted"; then
            log_info "Patch update available: $pkg $current -> $wanted"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $wanted"
                track_update "$(pwd)" "$pkg" "$current" "$wanted"
            else
                if npm install "${pkg}@${wanted}" --save-exact 2>/dev/null; then
                    log_success "Updated $pkg: $current -> $wanted"
                    track_update "$(pwd)" "$pkg" "$current" "$wanted"
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$wanted"
        fi
    done <<< "$packages"
}

# Handle yarn updates
handle_yarn_updates() {
    log_verbose "Checking for outdated yarn packages..."

    local outdated_json
    outdated_json=$(yarn outdated --json 2>/dev/null | grep '"type":"table"' | head -1) || true

    if [[ -z "$outdated_json" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    # Yarn outputs JSON lines, we need the table data
    local data
    data=$(echo "$outdated_json" | jq -r '.data.body[]? | @json' 2>/dev/null) || true

    if [[ -z "$data" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    while IFS= read -r row; do
        [[ -z "$row" ]] && continue

        local pkg current wanted latest
        pkg=$(echo "$row" | jq -r '.[0]')
        current=$(echo "$row" | jq -r '.[1]')
        wanted=$(echo "$row" | jq -r '.[2]')
        latest=$(echo "$row" | jq -r '.[3]')

        if is_patch_update "$current" "$wanted"; then
            log_info "Patch update available: $pkg $current -> $wanted"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $wanted"
                track_update "$(pwd)" "$pkg" "$current" "$wanted"
            else
                if yarn add "${pkg}@${wanted}" --exact 2>/dev/null; then
                    log_success "Updated $pkg: $current -> $wanted"
                    track_update "$(pwd)" "$pkg" "$current" "$wanted"
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$wanted"
        fi
    done <<< "$data"
}

# Handle pnpm updates
handle_pnpm_updates() {
    log_verbose "Checking for outdated pnpm packages..."

    local outdated_json
    outdated_json=$(pnpm outdated --json 2>/dev/null) || true

    if [[ -z "$outdated_json" || "$outdated_json" == "{}" || "$outdated_json" == "[]" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    # pnpm outdated --json returns an object with package names as keys
    local packages
    packages=$(echo "$outdated_json" | jq -r 'keys[]' 2>/dev/null) || true

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        local current wanted latest
        current=$(echo "$outdated_json" | jq -r --arg pkg "$pkg" '.[$pkg].current // empty')
        wanted=$(echo "$outdated_json" | jq -r --arg pkg "$pkg" '.[$pkg].wanted // empty')
        latest=$(echo "$outdated_json" | jq -r --arg pkg "$pkg" '.[$pkg].latest // empty')

        [[ -z "$current" ]] && continue

        if is_patch_update "$current" "$wanted"; then
            log_info "Patch update available: $pkg $current -> $wanted"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $wanted"
                track_update "$(pwd)" "$pkg" "$current" "$wanted"
            else
                if pnpm add "${pkg}@${wanted}" 2>/dev/null; then
                    log_success "Updated $pkg: $current -> $wanted"
                    track_update "$(pwd)" "$pkg" "$current" "$wanted"
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$wanted"
        fi
    done <<< "$packages"
}

# Handle bun updates
handle_bun_updates() {
    log_verbose "Checking for outdated bun packages..."

    # Bun doesn't have a native outdated command yet, use npm compatibility
    local outdated_json
    outdated_json=$(bun pm ls --json 2>/dev/null) || true

    if [[ -z "$outdated_json" ]]; then
        log_warn "Could not check outdated packages with bun"
        return 0
    fi

    # For now, use npm outdated as bun is npm-compatible
    log_info "Using npm outdated for bun project (bun is npm-compatible)"
    handle_npm_updates
}
