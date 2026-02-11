#!/usr/bin/env bash
# Python handler for repo-maintain

# Handle Python project updates
# Args: project_dir package_manager
handle_python() {
    local project_dir="$1"
    local pkg_manager="$2"

    cd "$project_dir" || return 1

    case "$pkg_manager" in
        pip)
            handle_pip_updates
            ;;
        poetry)
            handle_poetry_updates
            ;;
        uv)
            handle_uv_updates
            ;;
        pipenv)
            handle_pipenv_updates
            ;;
        *)
            log_error "Unknown Python package manager: $pkg_manager"
            return 1
            ;;
    esac
}

# Handle pip updates
handle_pip_updates() {
    if ! check_dependency "pip"; then
        log_error "pip not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    log_verbose "Checking for outdated pip packages..."

    local outdated_json
    start_spinner "Checking for outdated packages"
    outdated_json=$(pip list --outdated --format=json 2>/dev/null) || true
    stop_spinner

    if [[ -z "$outdated_json" || "$outdated_json" == "[]" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    local count
    count=$(echo "$outdated_json" | jq 'length')

    for ((i=0; i<count; i++)); do
        local pkg current latest
        pkg=$(echo "$outdated_json" | jq -r ".[$i].name")
        current=$(echo "$outdated_json" | jq -r ".[$i].version")
        latest=$(echo "$outdated_json" | jq -r ".[$i].latest_version")

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $pkg $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $latest"
                track_update "$(pwd)" "$pkg" "$current" "$latest"
            else
                if pip install "${pkg}==${latest}" 2>/dev/null; then
                    log_success "Updated $pkg: $current -> $latest"
                    track_update "$(pwd)" "$pkg" "$current" "$latest"
                    # Update requirements.txt if it exists
                    update_requirements_txt "$pkg" "$latest"
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$latest"
        fi
    done
}

# Update requirements.txt with new version
update_requirements_txt() {
    local pkg="$1"
    local version="$2"

    if [[ -f "requirements.txt" ]]; then
        # Use sed to update the version in requirements.txt
        # Handle various formats: pkg==version, pkg>=version, pkg~=version
        if grep -qi "^${pkg}[=~><]" requirements.txt; then
            sed -i "s/^${pkg}[=~><][=]*[0-9.]*/${pkg}==${version}/i" requirements.txt
            log_verbose "Updated requirements.txt for $pkg"
        fi
    fi
}

# Handle poetry updates
handle_poetry_updates() {
    if ! check_dependency "poetry"; then
        log_error "poetry not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    # Ensure poetry.lock exists
    if [[ ! -f "poetry.lock" ]]; then
        log_verbose "No poetry.lock found, running poetry lock..."
        poetry lock --no-update 2>/dev/null || true
    fi

    log_verbose "Checking for outdated poetry packages..."

    local outdated_output
    start_spinner "Checking for outdated packages"
    outdated_output=$(poetry show --outdated 2>/dev/null) || true
    stop_spinner

    if [[ -z "$outdated_output" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    # Parse poetry show --outdated output
    # Format: package current latest description
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Skip header lines or non-package lines
        [[ "$line" == *"Updating"* ]] && continue
        [[ "$line" == *"---"* ]] && continue

        local pkg current latest
        pkg=$(echo "$line" | awk '{print $1}')
        current=$(echo "$line" | awk '{print $2}')
        latest=$(echo "$line" | awk '{print $3}')

        [[ -z "$pkg" || -z "$current" || -z "$latest" ]] && continue
        # Skip if versions look like headers
        [[ "$current" == "current" ]] && continue

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $pkg $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $latest"
                track_update "$(pwd)" "$pkg" "$current" "$latest"
            else
                # Use poetry update with version constraint for patch updates
                if poetry update "$pkg" 2>/dev/null; then
                    # Verify the update resulted in the expected version
                    local new_version
                    new_version=$(poetry show "$pkg" 2>/dev/null | grep 'version' | awk '{print $3}')
                    if [[ "$new_version" == "$latest" ]] || is_patch_update "$current" "$new_version"; then
                        log_success "Updated $pkg: $current -> ${new_version:-$latest}"
                        track_update "$(pwd)" "$pkg" "$current" "${new_version:-$latest}"
                    else
                        log_warn "Updated $pkg but version mismatch (got $new_version, expected $latest)"
                        track_update "$(pwd)" "$pkg" "$current" "${new_version:-$latest}"
                    fi
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$latest"
        fi
    done <<< "$outdated_output"
}

# Handle uv updates
handle_uv_updates() {
    if ! check_dependency "uv"; then
        log_error "uv not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    # Check if this is a uv project (has uv.lock or pyproject.toml with [project])
    local is_uv_project=false
    if [[ -f "uv.lock" ]]; then
        is_uv_project=true
    elif [[ -f "pyproject.toml" ]] && grep -q '^\[project\]' pyproject.toml 2>/dev/null; then
        is_uv_project=true
    fi

    if [[ "$is_uv_project" == "true" ]]; then
        handle_uv_project_updates
    else
        handle_uv_pip_updates
    fi
}

# Handle uv project updates (pyproject.toml-based projects)
handle_uv_project_updates() {
    log_verbose "Checking for outdated packages in uv project..."

    # Ensure uv.lock exists
    if [[ ! -f "uv.lock" ]]; then
        log_verbose "No uv.lock found, running uv lock..."
        uv lock 2>/dev/null || true
    fi

    # Get outdated packages using uv tree or by comparing lock file
    # uv doesn't have a direct --outdated command yet, so we check via pip
    local outdated_json
    start_spinner "Checking for outdated packages"
    outdated_json=$(uv pip list --outdated --format=json 2>/dev/null) || true
    stop_spinner

    if [[ -z "$outdated_json" || "$outdated_json" == "[]" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    local count
    count=$(echo "$outdated_json" | jq 'length')
    local packages_to_upgrade=()

    for ((i=0; i<count; i++)); do
        local pkg current latest
        pkg=$(echo "$outdated_json" | jq -r ".[$i].name")
        current=$(echo "$outdated_json" | jq -r ".[$i].version")
        latest=$(echo "$outdated_json" | jq -r ".[$i].latest_version")

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $pkg $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $latest"
                track_update "$(pwd)" "$pkg" "$current" "$latest"
            else
                packages_to_upgrade+=("$pkg")
            fi
        else
            track_skip_versioned "$pkg" "$current" "$latest"
        fi
    done

    # Apply updates using uv lock --upgrade-package
    if [[ "$DRY_RUN" != "true" && ${#packages_to_upgrade[@]} -gt 0 ]]; then
        for pkg in "${packages_to_upgrade[@]}"; do
            log_verbose "Upgrading $pkg..."
            if uv lock --upgrade-package "$pkg" 2>/dev/null; then
                log_success "Updated $pkg in uv.lock"
                track_update "$(pwd)" "$pkg" "" ""
            else
                log_error "Failed to update $pkg"
                track_failure "update_failed"
            fi
        done

        # Sync the environment
        log_verbose "Syncing uv environment..."
        uv sync 2>/dev/null || true
    fi
}

# Handle uv pip-style updates (for non-project usage)
handle_uv_pip_updates() {
    log_verbose "Checking for outdated packages (uv pip mode)..."

    local outdated_json
    start_spinner "Checking for outdated packages"
    outdated_json=$(uv pip list --outdated --format=json 2>/dev/null) || true
    stop_spinner

    if [[ -z "$outdated_json" || "$outdated_json" == "[]" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    local count
    count=$(echo "$outdated_json" | jq 'length')

    for ((i=0; i<count; i++)); do
        local pkg current latest
        pkg=$(echo "$outdated_json" | jq -r ".[$i].name")
        current=$(echo "$outdated_json" | jq -r ".[$i].version")
        latest=$(echo "$outdated_json" | jq -r ".[$i].latest_version")

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $pkg $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $latest"
                track_update "$(pwd)" "$pkg" "$current" "$latest"
            else
                if uv pip install "${pkg}==${latest}" 2>/dev/null; then
                    log_success "Updated $pkg: $current -> $latest"
                    track_update "$(pwd)" "$pkg" "$current" "$latest"
                    update_requirements_txt "$pkg" "$latest"
                else
                    log_error "Failed to update $pkg"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$pkg" "$current" "$latest"
        fi
    done
}

# Handle pipenv updates
handle_pipenv_updates() {
    if ! check_dependency "pipenv"; then
        log_error "pipenv not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    log_verbose "Checking for outdated pipenv packages..."

    local outdated_output
    start_spinner "Checking for outdated packages"
    outdated_output=$(pipenv update --outdated 2>/dev/null) || true
    stop_spinner

    if [[ -z "$outdated_output" ]]; then
        log_info "No outdated packages found"
        return 0
    fi

    # Parse pipenv update --outdated output
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" != *"=="* ]] && continue

        local pkg current latest
        # Format: Package 'name' has newer version X available (current: Y)
        if [[ "$line" =~ Package\ \'([^\']+)\'.*version\ ([0-9.]+).*current:\ ([0-9.]+) ]]; then
            pkg="${BASH_REMATCH[1]}"
            latest="${BASH_REMATCH[2]}"
            current="${BASH_REMATCH[3]}"
        else
            continue
        fi

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $pkg $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $pkg to $latest"
                track_update "$(pwd)" "$pkg" "$current" "$latest"
            else
                if pipenv install "${pkg}==${latest}" 2>/dev/null; then
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
    done <<< "$outdated_output"
}
