#!/usr/bin/env bash
# Project detection logic for repo-maintain

# Directories to skip during scanning
SKIP_DIRS=(
    "node_modules"
    "vendor"
    ".git"
    "target"
    "build"
    "dist"
    "venv"
    ".venv"
    "__pycache__"
    ".tox"
    ".nox"
    ".mypy_cache"
    ".pytest_cache"
    "egg-info"
    ".eggs"
)

# Build find exclusion pattern
build_find_excludes() {
    local excludes=""
    for dir in "${SKIP_DIRS[@]}"; do
        excludes="$excludes -name $dir -prune -o"
    done
    echo "$excludes"
}

# Find all projects in a directory
# Outputs: ecosystem|package_manager|project_path (one per line)
find_projects() {
    local root_dir="$1"
    local found_projects=()

    # Build exclusion pattern for find
    local exclude_pattern=""
    for dir in "${SKIP_DIRS[@]}"; do
        exclude_pattern="$exclude_pattern -path '*/$dir' -prune -o -path '*/$dir/*' -prune -o"
    done

    # Node.js projects
    while IFS= read -r -d '' file; do
        local project_dir
        project_dir=$(dirname "$file")
        local pkg_manager
        pkg_manager=$(detect_node_package_manager "$project_dir")
        found_projects+=("nodejs|$pkg_manager|$project_dir")
    done < <(eval "find \"$root_dir\" $exclude_pattern -name 'package.json' -type f -print0")

    # Python projects (pyproject.toml)
    while IFS= read -r -d '' file; do
        local project_dir
        project_dir=$(dirname "$file")
        # Skip if already detected via package.json (hybrid projects)
        if ! project_already_found "$project_dir" "python"; then
            local pkg_manager
            pkg_manager=$(detect_python_package_manager "$project_dir")
            found_projects+=("python|$pkg_manager|$project_dir")
        fi
    done < <(eval "find \"$root_dir\" $exclude_pattern -name 'pyproject.toml' -type f -print0")

    # Python projects (requirements.txt only, no pyproject.toml)
    while IFS= read -r -d '' file; do
        local project_dir
        project_dir=$(dirname "$file")
        # Skip if pyproject.toml exists in same dir
        if [[ ! -f "$project_dir/pyproject.toml" ]]; then
            if ! project_already_found "$project_dir" "python"; then
                found_projects+=("python|pip|$project_dir")
            fi
        fi
    done < <(eval "find \"$root_dir\" $exclude_pattern -name 'requirements.txt' -type f -print0")

    # Rust projects
    while IFS= read -r -d '' file; do
        local project_dir
        project_dir=$(dirname "$file")
        found_projects+=("rust|cargo|$project_dir")
    done < <(eval "find \"$root_dir\" $exclude_pattern -name 'Cargo.toml' -type f -print0")

    # Java/Maven projects
    while IFS= read -r -d '' file; do
        local project_dir
        project_dir=$(dirname "$file")
        found_projects+=("java|maven|$project_dir")
    done < <(eval "find \"$root_dir\" $exclude_pattern -name 'pom.xml' -type f -print0")

    # Java/Gradle projects (build.gradle or build.gradle.kts)
    while IFS= read -r -d '' file; do
        local project_dir
        project_dir=$(dirname "$file")
        # Skip if pom.xml exists (Maven takes precedence)
        if [[ ! -f "$project_dir/pom.xml" ]]; then
            found_projects+=("java|gradle|$project_dir")
        fi
    done < <(eval "find \"$root_dir\" $exclude_pattern \\( -name 'build.gradle' -o -name 'build.gradle.kts' \\) -type f -print0")

    # Go projects
    while IFS= read -r -d '' file; do
        local project_dir
        project_dir=$(dirname "$file")
        found_projects+=("go|go|$project_dir")
    done < <(eval "find \"$root_dir\" $exclude_pattern -name 'go.mod' -type f -print0")

    # Output unique projects
    printf '%s\n' "${found_projects[@]}" | sort -u
}

# Check if a project directory was already found for a given ecosystem
project_already_found() {
    local dir="$1"
    local ecosystem="$2"
    # This is a placeholder - actual implementation would track found projects
    return 1
}

# Detect Node.js package manager
detect_node_package_manager() {
    local project_dir="$1"

    if [[ -f "$project_dir/yarn.lock" ]]; then
        echo "yarn"
    elif [[ -f "$project_dir/pnpm-lock.yaml" ]]; then
        echo "pnpm"
    elif [[ -f "$project_dir/bun.lockb" ]]; then
        echo "bun"
    else
        echo "npm"
    fi
}

# Detect Python package manager
detect_python_package_manager() {
    local project_dir="$1"

    # Check for lock files first (most reliable)
    if [[ -f "$project_dir/poetry.lock" ]]; then
        echo "poetry"
        return
    elif [[ -f "$project_dir/uv.lock" ]]; then
        echo "uv"
        return
    elif [[ -f "$project_dir/Pipfile.lock" ]]; then
        echo "pipenv"
        return
    fi

    # Check pyproject.toml for tool-specific sections
    if [[ -f "$project_dir/pyproject.toml" ]]; then
        # Check for [tool.poetry] section
        if grep -q '^\[tool\.poetry\]' "$project_dir/pyproject.toml" 2>/dev/null; then
            echo "poetry"
            return
        fi

        # Check for [tool.uv] section or uv-specific markers
        if grep -q '^\[tool\.uv\]' "$project_dir/pyproject.toml" 2>/dev/null; then
            echo "uv"
            return
        fi

        # Check for [project] section (PEP 621) - prefer uv if available, else pip
        if grep -q '^\[project\]' "$project_dir/pyproject.toml" 2>/dev/null; then
            if command -v uv &>/dev/null; then
                echo "uv"
                return
            fi
        fi
    fi

    echo "pip"
}
