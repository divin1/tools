#!/usr/bin/env bash
# Go handler for repo-maintain

# Handle Go project updates
# Args: project_dir package_manager
handle_go() {
    local project_dir="$1"
    local pkg_manager="$2"

    if ! check_dependency "go"; then
        log_error "go not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    cd "$project_dir" || return 1

    handle_go_modules
}

# Handle Go module updates
handle_go_modules() {
    log_verbose "Checking for outdated Go modules..."

    local updates_json
    start_spinner "Checking for outdated modules"
    updates_json=$(go list -m -u -json all 2>/dev/null) || true
    stop_spinner

    if [[ -z "$updates_json" ]]; then
        log_info "No modules found or error checking updates"
        return 0
    fi

    # Parse JSON objects (one per line from go list -m -u -json)
    local found_updates=false

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Accumulate JSON objects
        local json_obj=""
        local brace_count=0
        local in_object=false

        # Read complete JSON object
        while IFS= read -r char || [[ -n "$char" ]]; do
            json_obj+="$char"

            if [[ "$char" == "{" ]]; then
                ((brace_count++))
                in_object=true
            elif [[ "$char" == "}" ]]; then
                ((brace_count--))
                if [[ $brace_count -eq 0 && "$in_object" == "true" ]]; then
                    break
                fi
            fi
        done < <(echo "$line" | fold -w1)

        # This approach doesn't work well, let's use a different method
        break
    done <<< "$updates_json"

    # Better approach: use jq to parse the stream of JSON objects
    # go list -m -u -json outputs one JSON object per module
    local modules
    modules=$(echo "$updates_json" | jq -s '.' 2>/dev/null) || true

    if [[ -z "$modules" || "$modules" == "[]" ]]; then
        log_info "No modules found"
        return 0
    fi

    local count
    count=$(echo "$modules" | jq 'length')

    for ((i=0; i<count; i++)); do
        local module
        module=$(echo "$modules" | jq ".[$i]")

        local path current update_info
        path=$(echo "$module" | jq -r '.Path')
        current=$(echo "$module" | jq -r '.Version // empty')
        update_info=$(echo "$module" | jq -r '.Update.Version // empty')

        # Skip if no update available or no current version
        [[ -z "$current" || -z "$update_info" ]] && continue

        # Skip the main module
        local is_main
        is_main=$(echo "$module" | jq -r '.Main // false')
        [[ "$is_main" == "true" ]] && continue

        found_updates=true

        if is_patch_update "$current" "$update_info"; then
            log_info "$(update_type_label "$current" "$update_info") update: $path $current -> $update_info"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $path to $update_info"
                track_update "$(pwd)" "$path" "$current" "$update_info"
            else
                if go get "${path}@${update_info}" 2>/dev/null; then
                    log_success "Updated $path: $current -> $update_info"
                    track_update "$(pwd)" "$path" "$current" "$update_info"
                else
                    log_error "Failed to update $path"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$path" "$current" "$update_info"
        fi
    done

    if [[ "$found_updates" == "false" ]]; then
        log_info "No outdated modules found"
    fi

    # Tidy up go.mod and go.sum
    if [[ "$DRY_RUN" != "true" && "$TOTAL_UPDATES" -gt 0 ]]; then
        log_verbose "Running go mod tidy..."
        go mod tidy 2>/dev/null || true
    fi
}
