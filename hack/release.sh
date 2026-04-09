#!/bin/bash

# Release Script for Kube-OVN Documentation
#
# Performs the 3-step release process:
#   Step 1: Demote the previous stable branch (remove "current stable" alias)
#   Step 2: Create a new release branch from master and set as stable
#   Step 3: Prepare master for the next development version
#
# Usage:
#   ./hack/release.sh <new_version>
#   ./hack/release.sh --dry-run <new_version>
#
# Examples:
#   ./hack/release.sh 1.16
#   ./hack/release.sh --dry-run 1.16

set -euo pipefail

CI_FILE=".github/workflows/ci.yml"
MKDOCS_FILE="mkdocs.yml"
CONTACT_FILE="overrides/contact.md"
NEXT_FILE="docs/reference/next.md"

usage() {
    echo "Usage: $0 [--dry-run] <new_version>"
    echo ""
    echo "Arguments:"
    echo "  new_version   Version to release, e.g., 1.16"
    echo ""
    echo "Options:"
    echo "  --dry-run     Show what would be changed without making any modifications"
    echo ""
    echo "Examples:"
    echo "  $0 1.16"
    echo "  $0 --dry-run 1.16"
}

DRY_RUN=false
NEW_VER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -n "$NEW_VER" ]; then
                echo "ERROR: unexpected argument '$1'"
                usage
                exit 1
            fi
            NEW_VER="$1"
            shift
            ;;
    esac
done

if [ -z "$NEW_VER" ]; then
    echo "ERROR: new_version is required"
    usage
    exit 1
fi

if ! [[ "$NEW_VER" =~ ^1\.[0-9]+$ ]]; then
    echo "ERROR: Version must be in format '1.XX' (e.g., 1.16)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Derive version numbers
# ---------------------------------------------------------------------------
NEW_MINOR="${NEW_VER#1.}"
PREV_MINOR=$((NEW_MINOR - 1))
NEXT_MINOR=$((NEW_MINOR + 1))
PREV_VER="1.${PREV_MINOR}"
NEXT_VER="1.${NEXT_MINOR}"

echo "========================================"
echo "  Kube-OVN Docs Release"
echo "========================================"
echo ""
echo "  Previous stable : v${PREV_VER}  (will be demoted)"
echo "  New stable      : v${NEW_VER}  (new branch from master)"
echo "  Next dev        : v${NEXT_VER}  (master will target this)"
echo ""
if $DRY_RUN; then
    echo "  Mode: DRY RUN (no changes will be made)"
    echo ""
fi

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
preflight_check() {
    local errors=0

    # Must be on master
    local current_branch
    current_branch=$(git branch --show-current)
    if [ "$current_branch" != "master" ]; then
        echo "ERROR: Must be on master branch (currently on: $current_branch)"
        errors=$((errors + 1))
    fi

    # Working directory must be clean
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        echo "ERROR: Working directory is not clean. Please commit or stash changes first."
        errors=$((errors + 1))
    fi

    # Fetch latest
    git fetch origin

    # Master must be up to date
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ]; then
        echo "ERROR: Local master is not up to date with origin/master. Run 'git pull' first."
        errors=$((errors + 1))
    fi

    # Previous stable branch must exist
    if ! git ls-remote --exit-code --heads origin "v${PREV_VER}" >/dev/null 2>&1; then
        echo "ERROR: Previous stable branch v${PREV_VER} does not exist on remote."
        errors=$((errors + 1))
    fi

    # New branch must not exist yet
    if git ls-remote --exit-code --heads origin "v${NEW_VER}" >/dev/null 2>&1; then
        echo "ERROR: Branch v${NEW_VER} already exists on remote. Release may have been partially done."
        errors=$((errors + 1))
    fi

    # Master CI must have the expected dev deployment
    if ! grep -q "mike deploy --push -u v${NEW_VER}\.x dev" "$CI_FILE"; then
        echo "ERROR: Master CI does not deploy v${NEW_VER}.x dev. Is master correctly configured?"
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        echo ""
        echo "Pre-flight check failed with $errors error(s). Aborting."
        exit 1
    fi

    echo "Pre-flight checks passed."
}

# ---------------------------------------------------------------------------
# Verify that a file contains expected content after modification
# ---------------------------------------------------------------------------
verify_content() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if ! grep -q -- "$pattern" "$file"; then
        echo "VERIFY FAILED: expected '$description' in $file"
        echo "  pattern: $pattern"
        echo ""
        echo "The file may have an unexpected format. Please check manually."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Demote previous stable branch
# ---------------------------------------------------------------------------
step1_demote_previous() {
    echo ""
    echo "========================================"
    echo "  Step 1/3: Demote v${PREV_VER} from stable"
    echo "========================================"
    echo ""
    echo "  Branch  : v${PREV_VER}"
    echo "  Changes : ${CI_FILE}"
    echo "    - Remove 'current stable' alias from mike deploy"
    echo "    - Remove 'mike set-default stable' line"
    echo "    - Remove '(stable)' from title"
    echo ""

    if $DRY_RUN; then
        echo "  [DRY RUN] Skipping actual changes."
        return
    fi

    git checkout -B "v${PREV_VER}" "origin/v${PREV_VER}"

    # Verify the expected content exists before modifying
    verify_content "$CI_FILE" \
        "mike deploy --push -u v${PREV_VER}\.x current stable" \
        "v${PREV_VER} stable deployment"

    # Remove "current stable" alias and "(stable)" from title
    #   Before: mike deploy --push -u v1.15.x current stable -t "v1.15.x (stable)"
    #   After:  mike deploy --push -u v1.15.x -t "v1.15.x"
    sed -i \
        "s|mike deploy --push -u v${PREV_VER}\.x current stable -t \"v${PREV_VER}\.x (stable)\"|mike deploy --push -u v${PREV_VER}.x -t \"v${PREV_VER}.x\"|" \
        "$CI_FILE"

    # Remove mike set-default line
    sed -i "/mike set-default stable --push/d" "$CI_FILE"

    # Verify the result
    verify_content "$CI_FILE" \
        "mike deploy --push -u v${PREV_VER}\.x -t \"v${PREV_VER}\.x\"" \
        "v${PREV_VER} non-stable deployment"

    # There should be no more "current stable" or "set-default" in the file
    if grep -q "current stable" "$CI_FILE"; then
        echo "VERIFY FAILED: 'current stable' still present in ${CI_FILE}"
        exit 1
    fi
    if grep -q "set-default" "$CI_FILE"; then
        echo "VERIFY FAILED: 'set-default' still present in ${CI_FILE}"
        exit 1
    fi

    git add "$CI_FILE"
    git commit -s -m "release: demote v${PREV_VER} from stable"
    git push origin "v${PREV_VER}"

    echo ""
    echo "  Done: v${PREV_VER} demoted from stable."
}

# ---------------------------------------------------------------------------
# Step 2: Create new release branch, set as stable
# ---------------------------------------------------------------------------
step2_create_stable() {
    echo ""
    echo "========================================"
    echo "  Step 2/3: Create v${NEW_VER} as stable"
    echo "========================================"
    echo ""
    echo "  Branch  : v${NEW_VER} (new, from master)"
    echo "  Changes :"
    echo "    ${CI_FILE}:"
    echo "      - Add v${NEW_VER} to trigger branches"
    echo "      - Change mike deploy from 'dev' to 'current stable'"
    echo "      - Add 'mike set-default stable'"
    echo "    ${MKDOCS_FILE}:"
    echo "      - branch: release-${PREV_VER} -> release-${NEW_VER}"
    echo "      - cover_subtitle: v${NEW_VER}.0"
    echo "    ${CONTACT_FILE}:"
    echo "      - PDF link: v${PREV_VER}.x -> v${NEW_VER}.x"
    echo ""

    if $DRY_RUN; then
        echo "  [DRY RUN] Skipping actual changes."
        return
    fi

    git checkout master
    git checkout -b "v${NEW_VER}"

    # --- ci.yml ---

    # Verify master CI has the expected dev deployment
    verify_content "$CI_FILE" \
        "mike deploy --push -u v${NEW_VER}\.x dev -t \"v${NEW_VER}\.x (dev)\"" \
        "v${NEW_VER} dev deployment"

    # Add branch trigger: insert "      - v{NEW_VER}" after "      - master"
    sed -i "/^      - master$/a\\      - v${NEW_VER}" "$CI_FILE"

    # Change mike deploy from dev to current stable
    #   Before: mike deploy --push -u v1.16.x dev -t "v1.16.x (dev)"
    #   After:  mike deploy --push -u v1.16.x current stable -t "v1.16.x (stable)"
    sed -i \
        "s|mike deploy --push -u v${NEW_VER}\.x dev -t \"v${NEW_VER}\.x (dev)\"|mike deploy --push -u v${NEW_VER}.x current stable -t \"v${NEW_VER}.x (stable)\"|" \
        "$CI_FILE"

    # Add "mike set-default stable --push" after the mike deploy line
    sed -i "/mike deploy --push -u v${NEW_VER}\.x current stable/a\\          mike set-default stable --push" "$CI_FILE"

    # Verify
    verify_content "$CI_FILE" "- v${NEW_VER}$" "v${NEW_VER} branch trigger"
    verify_content "$CI_FILE" \
        "mike deploy --push -u v${NEW_VER}\.x current stable -t \"v${NEW_VER}\.x (stable)\"" \
        "v${NEW_VER} stable deployment"
    verify_content "$CI_FILE" "mike set-default stable --push" "mike set-default"

    # Verify no leftover "dev" alias in the mike deploy line
    if grep "mike deploy" "$CI_FILE" | grep -q " dev "; then
        echo "VERIFY FAILED: 'dev' alias still present in mike deploy command"
        exit 1
    fi

    # --- mkdocs.yml ---

    # Update branch variable
    sed -i "s|branch: release-${PREV_VER}|branch: release-${NEW_VER}|" "$MKDOCS_FILE"

    # Update cover_subtitle to new version
    sed -i "s|cover_subtitle: v.*|cover_subtitle: v${NEW_VER}.0|" "$MKDOCS_FILE"

    verify_content "$MKDOCS_FILE" "branch: release-${NEW_VER}" "branch variable"
    verify_content "$MKDOCS_FILE" "cover_subtitle: v${NEW_VER}\.0" "cover_subtitle"

    # --- contact.md ---

    # Update PDF link version
    sed -i "s|/docs/v[0-9]*\.[0-9]*\.x/|/docs/v${NEW_VER}.x/|g" "$CONTACT_FILE"

    verify_content "$CONTACT_FILE" "/docs/v${NEW_VER}\.x/" "PDF link version"

    # --- Commit and push ---
    git add "$CI_FILE" "$MKDOCS_FILE" "$CONTACT_FILE"
    git commit -s -m "release: set v${NEW_VER} as stable"
    git push origin "v${NEW_VER}"

    echo ""
    echo "  Done: v${NEW_VER} branch created and set as stable."
}

# ---------------------------------------------------------------------------
# Step 3: Prepare master for the next development version
# ---------------------------------------------------------------------------
step3_prepare_next() {
    echo ""
    echo "========================================"
    echo "  Step 3/3: Prepare master for v${NEXT_VER}"
    echo "========================================"
    echo ""
    echo "  Branch  : master"
    echo "  Changes :"
    echo "    ${CI_FILE}:"
    echo "      - mike deploy: v${NEW_VER}.x dev -> v${NEXT_VER}.x dev"
    echo "    ${MKDOCS_FILE}:"
    echo "      - version: v${NEW_VER}.0 -> v${NEXT_VER}.0"
    echo "      - branch: release-${PREV_VER} -> release-${NEW_VER}"
    echo "      - cover_subtitle: v${NEXT_VER}.0"
    echo "    ${CONTACT_FILE}:"
    echo "      - PDF link: -> v${NEW_VER}.x (points to new stable)"
    echo "    ${NEXT_FILE}:"
    echo "      - Add 'Post-v${NEW_VER}.0' section heading"
    echo ""

    if $DRY_RUN; then
        echo "  [DRY RUN] Skipping actual changes."
        return
    fi

    git checkout master

    # --- ci.yml ---

    # Change mike deploy version
    #   Before: mike deploy --push -u v1.16.x dev -t "v1.16.x (dev)"
    #   After:  mike deploy --push -u v1.17.x dev -t "v1.17.x (dev)"
    sed -i \
        "s|mike deploy --push -u v${NEW_VER}\.x dev -t \"v${NEW_VER}\.x (dev)\"|mike deploy --push -u v${NEXT_VER}.x dev -t \"v${NEXT_VER}.x (dev)\"|" \
        "$CI_FILE"

    verify_content "$CI_FILE" \
        "mike deploy --push -u v${NEXT_VER}\.x dev -t \"v${NEXT_VER}\.x (dev)\"" \
        "v${NEXT_VER} dev deployment"

    # --- mkdocs.yml ---

    # Update version
    sed -i "s|version: v${NEW_VER}\.0|version: v${NEXT_VER}.0|" "$MKDOCS_FILE"

    # Update branch
    sed -i "s|branch: release-${PREV_VER}|branch: release-${NEW_VER}|" "$MKDOCS_FILE"

    # Update cover_subtitle
    sed -i "s|cover_subtitle: v.*|cover_subtitle: v${NEXT_VER}.0|" "$MKDOCS_FILE"

    verify_content "$MKDOCS_FILE" "version: v${NEXT_VER}\.0" "version variable"
    verify_content "$MKDOCS_FILE" "branch: release-${NEW_VER}" "branch variable"
    verify_content "$MKDOCS_FILE" "cover_subtitle: v${NEXT_VER}\.0" "cover_subtitle"

    # --- contact.md ---

    # Update PDF link to point to the new stable version
    sed -i "s|/docs/v[0-9]*\.[0-9]*\.x/|/docs/v${NEW_VER}.x/|g" "$CONTACT_FILE"

    verify_content "$CONTACT_FILE" "/docs/v${NEW_VER}\.x/" "PDF link version"

    # --- next.md ---

    # Insert new "Post-v{NEW_VER}.0" section heading after the description line
    sed -i "/^This document lists the features/a\\\n## Post-v${NEW_VER}.0" "$NEXT_FILE"

    verify_content "$NEXT_FILE" "## Post-v${NEW_VER}\.0" "new Post section heading"

    # --- Commit and push ---
    git add "$CI_FILE" "$MKDOCS_FILE" "$CONTACT_FILE" "$NEXT_FILE"
    git commit -s -m "release: prepare for v${NEXT_VER} development"
    git push origin master

    echo ""
    echo "  Done: master prepared for v${NEXT_VER} development."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
preflight_check

echo ""
if ! $DRY_RUN; then
    read -p "Proceed with release? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

step1_demote_previous
step2_create_stable
step3_prepare_next

echo ""
echo "========================================"
echo "  Release complete!"
echo "========================================"
echo ""
echo "Summary:"
echo "  v${PREV_VER} branch  : demoted (no longer stable)"
echo "  v${NEW_VER} branch  : created and set as stable"
echo "  master branch : prepared for v${NEXT_VER} development"
echo ""
echo "CI will now:"
echo "  - Deploy v${PREV_VER} docs as 'v${PREV_VER}.x'"
echo "  - Deploy v${NEW_VER} docs as 'v${NEW_VER}.x (stable)' [default]"
echo "  - Deploy master docs as 'v${NEXT_VER}.x (dev)'"
echo ""

# Return to master
git checkout master
