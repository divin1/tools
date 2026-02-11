#!/usr/bin/env bash
# Java handler for repo-maintain

# Handle Java project updates
# Args: project_dir package_manager
handle_java() {
    local project_dir="$1"
    local pkg_manager="$2"

    cd "$project_dir" || return 1

    case "$pkg_manager" in
        maven)
            handle_maven_updates
            ;;
        gradle)
            handle_gradle_updates
            ;;
        *)
            log_error "Unknown Java package manager: $pkg_manager"
            return 1
            ;;
    esac
}

# Handle Maven updates
handle_maven_updates() {
    if ! check_dependency "mvn" "Maven"; then
        log_error "Maven not found, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    log_verbose "Checking for outdated Maven dependencies..."

    local updates_output
    start_spinner "Checking for outdated dependencies"
    updates_output=$(mvn versions:display-dependency-updates -DprocessDependencyManagement=false 2>/dev/null) || true
    stop_spinner

    if [[ -z "$updates_output" ]]; then
        log_info "No outdated dependencies found"
        return 0
    fi

    # Parse Maven output
    # Format: [INFO]   groupId:artifactId .................. currentVersion -> latestVersion
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" != *" -> "* ]] && continue

        local artifact current latest
        # Extract artifact and versions from Maven output
        if [[ "$line" =~ ([a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+)[[:space:]]+\.+[[:space:]]+([0-9][0-9.a-zA-Z-]*)[[:space:]]+-\>[[:space:]]+([0-9][0-9.a-zA-Z-]*) ]]; then
            artifact="${BASH_REMATCH[1]}"
            current="${BASH_REMATCH[2]}"
            latest="${BASH_REMATCH[3]}"
        else
            continue
        fi

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $artifact $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $artifact to $latest"
                track_update "$(pwd)" "$artifact" "$current" "$latest"
            else
                # Update pom.xml using Maven versions plugin
                local groupId artifactId
                groupId=$(echo "$artifact" | cut -d: -f1)
                artifactId=$(echo "$artifact" | cut -d: -f2)

                if mvn versions:use-dep-version -Dincludes="${groupId}:${artifactId}" -DdepVersion="$latest" -DgenerateBackupPoms=false 2>/dev/null; then
                    log_success "Updated $artifact: $current -> $latest"
                    track_update "$(pwd)" "$artifact" "$current" "$latest"
                else
                    log_error "Failed to update $artifact"
                    track_failure "update_failed"
                fi
            fi
        else
            track_skip_versioned "$artifact" "$current" "$latest"
        fi
    done <<< "$updates_output"
}

# Handle Gradle updates
handle_gradle_updates() {
    local gradle_cmd="gradle"

    # Check for Gradle wrapper
    if [[ -f "./gradlew" ]]; then
        gradle_cmd="./gradlew"
        log_verbose "Using Gradle wrapper"
    elif ! check_dependency "gradle" "Gradle"; then
        log_error "Gradle not found and no wrapper present, skipping project"
        track_failure "missing_package_manager"
        return 1
    fi

    log_verbose "Checking for outdated Gradle dependencies..."

    # Check if gradle-versions-plugin is available
    local updates_output
    start_spinner "Checking for outdated dependencies"
    updates_output=$($gradle_cmd dependencyUpdates -Drevision=release --no-daemon 2>/dev/null) || true
    stop_spinner

    if [[ -z "$updates_output" ]]; then
        log_warn "Could not check for updates. Ensure gradle-versions-plugin is configured."
        log_info "Add to build.gradle: plugins { id 'com.github.ben-manes.versions' version 'X.X.X' }"
        return 0
    fi

    # Parse Gradle dependency updates output
    # Look for the JSON report or parse text output
    local report_file="build/dependencyUpdates/report.json"
    if [[ -f "$report_file" ]]; then
        parse_gradle_json_report "$report_file"
    else
        parse_gradle_text_output "$updates_output"
    fi
}

# Parse Gradle JSON report
parse_gradle_json_report() {
    local report_file="$1"

    local outdated
    outdated=$(jq -r '.outdated.dependencies[]? | @json' "$report_file" 2>/dev/null) || true

    if [[ -z "$outdated" ]]; then
        log_info "No outdated dependencies found"
        return 0
    fi

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        local group name current latest
        group=$(echo "$dep" | jq -r '.group')
        name=$(echo "$dep" | jq -r '.name')
        current=$(echo "$dep" | jq -r '.version')
        latest=$(echo "$dep" | jq -r '.available.release // .available.milestone // empty')

        [[ -z "$group" || -z "$name" || -z "$current" || -z "$latest" ]] && continue

        local artifact="${group}:${name}"

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $artifact $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $artifact to $latest"
                track_update "$(pwd)" "$artifact" "$current" "$latest"
            else
                update_gradle_dependency "$group" "$name" "$current" "$latest"
            fi
        else
            track_skip_versioned "$artifact" "$current" "$latest"
        fi
    done <<< "$outdated"
}

# Parse Gradle text output
parse_gradle_text_output() {
    local output="$1"

    # Look for lines like: - group:artifact [current -> latest]
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" != *" -> "* ]] && continue

        local artifact current latest
        if [[ "$line" =~ -[[:space:]]+([a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+)[[:space:]]+\[([0-9][0-9.a-zA-Z-]*)[[:space:]]+-\>[[:space:]]+([0-9][0-9.a-zA-Z-]*)\] ]]; then
            artifact="${BASH_REMATCH[1]}"
            current="${BASH_REMATCH[2]}"
            latest="${BASH_REMATCH[3]}"
        else
            continue
        fi

        if is_patch_update "$current" "$latest"; then
            log_info "$(update_type_label "$current" "$latest") update: $artifact $current -> $latest"

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would update $artifact to $latest"
                track_update "$(pwd)" "$artifact" "$current" "$latest"
            else
                local group name
                group=$(echo "$artifact" | cut -d: -f1)
                name=$(echo "$artifact" | cut -d: -f2)
                update_gradle_dependency "$group" "$name" "$current" "$latest"
            fi
        else
            track_skip_versioned "$artifact" "$current" "$latest"
        fi
    done <<< "$output"
}

# Update a Gradle dependency in build.gradle or build.gradle.kts
update_gradle_dependency() {
    local group="$1"
    local name="$2"
    local current="$3"
    local latest="$4"
    local artifact="${group}:${name}"

    local build_file=""
    if [[ -f "build.gradle.kts" ]]; then
        build_file="build.gradle.kts"
    elif [[ -f "build.gradle" ]]; then
        build_file="build.gradle"
    else
        log_error "No build.gradle file found"
        track_failure "missing_build_file"
        return 1
    fi

    # Try to update the version in the build file
    # Handle various formats:
    # - implementation("group:name:version")
    # - implementation 'group:name:version'
    # - implementation group: 'group', name: 'name', version: 'version'

    if sed -i "s/${group}:${name}:${current}/${group}:${name}:${latest}/g" "$build_file" 2>/dev/null; then
        log_success "Updated $artifact: $current -> $latest"
        track_update "$(pwd)" "$artifact" "$current" "$latest"
    else
        log_error "Failed to update $artifact in $build_file"
        track_failure "update_failed"
    fi
}
