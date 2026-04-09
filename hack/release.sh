#!/bin/bash

# Release Script for Kube-OVN Documentation
#
# Performs the 3-step release process:
#   Step 1: Demote the previous stable branch (remove "current stable" alias)
#   Step 2: Create a new release branch from master and set as stable
#   Step 3: Prepare master for the next development version
#
# The script is idempotent: already-completed steps are detected and skipped
# automatically, so it is safe to re-run after a partial failure.

set -euo pipefail

CI_FILE=".github/workflows/ci.yml"
MKDOCS_FILE="mkdocs.yml"
CONTACT_FILE="overrides/contact.md"
NEXT_FILE="docs/reference/next.md"
VERSIONS_URL="https://kubeovn.github.io/docs/versions.json"
ORIGINAL_BRANCH=""

usage() {
    cat <<EOF
Usage: $0 [options] <new_version>

Release a new documentation version for Kube-OVN.

Arguments:
  new_version       Version to release, e.g., 1.16

Options:
  --dry-run         Show what would be changed without making any modifications
  --from-step N     Start from step N (1, 2, or 3), skipping earlier steps
  --verify          Check deployed site versions.json instead of releasing
  -h, --help        Show this help message

Examples:
  $0 1.16                  # Full release
  $0 --dry-run 1.16        # Preview changes
  $0 --from-step 2 1.16    # Resume from step 2 after a partial failure
  $0 --verify 1.16         # Verify deployment after release
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DRY_RUN=false
VERIFY_ONLY=false
FROM_STEP=0
NEW_VER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --from-step)
            FROM_STEP="$2"
            if ! [[ "$FROM_STEP" =~ ^[123]$ ]]; then
                echo "ERROR: --from-step must be 1, 2, or 3"
                exit 1
            fi
            shift 2
            ;;
        --verify)
            VERIFY_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option '$1'"
            usage
            exit 1
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

# ---------------------------------------------------------------------------
# Verify deployment (--verify mode)
# ---------------------------------------------------------------------------
if $VERIFY_ONLY; then
    echo "Checking deployed versions at ${VERSIONS_URL} ..."
    echo ""

    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl is required for --verify"
        exit 1
    fi

    versions_json=$(curl -sf "$VERSIONS_URL") || {
        echo "ERROR: failed to fetch ${VERSIONS_URL}"
        exit 1
    }

    errors=0

    # Check v{NEW_VER}.x has stable+current aliases
    if echo "$versions_json" | grep -q "\"v${NEW_VER}.x\"" &&
       echo "$versions_json" | grep -q '"stable"' &&
       echo "$versions_json" | grep -q "v${NEW_VER}.x (stable)"; then
        echo "  v${NEW_VER}.x  stable, current  OK"
    else
        echo "  v${NEW_VER}.x  MISSING or not stable"
        errors=$((errors + 1))
    fi

    # Check v{NEXT_VER}.x has dev alias
    if echo "$versions_json" | grep -q "v${NEXT_VER}.x (dev)"; then
        echo "  v${NEXT_VER}.x  dev              OK"
    else
        echo "  v${NEXT_VER}.x  MISSING or not dev"
        errors=$((errors + 1))
    fi

    # Check v{PREV_VER}.x has no aliases
    # Extract the entry for PREV_VER and check it doesn't have "stable" in its aliases
    if echo "$versions_json" | grep -q "\"v${PREV_VER}.x\""; then
        echo "  v${PREV_VER}.x  present          OK"
    else
        echo "  v${PREV_VER}.x  MISSING"
        errors=$((errors + 1))
    fi

    echo ""
    if [ $errors -eq 0 ]; then
        echo "Verification passed."
    else
        echo "Verification failed with $errors error(s)."
        echo "CI may still be running — wait a few minutes and retry."
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
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
# Helpers
# ---------------------------------------------------------------------------

# grep wrapper: always use -- to prevent patterns starting with - from being
# interpreted as flags.
grep_safe() {
    grep -q -- "$@"
}

verify_content() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if ! grep_safe "$pattern" "$file"; then
        echo "VERIFY FAILED: expected '$description' in $file"
        echo "  pattern: $pattern"
        echo ""
        echo "The file may have an unexpected format. Please check manually."
        exit 1
    fi
}

# Return to the original branch on exit (success or failure)
cleanup() {
    if [ -n "$ORIGINAL_BRANCH" ]; then
        git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Show recovery hint on error
on_error() {
    local step="$1"
    echo ""
    echo "========================================"
    echo "  Step $step FAILED"
    echo "========================================"
    echo ""
    case $step in
        1)
            echo "Recovery: the v${PREV_VER} branch may have partial changes."
            echo "  git checkout v${PREV_VER} && git reset --hard origin/v${PREV_VER}"
            echo ""
            echo "Then re-run:  $0 ${NEW_VER}"
            ;;
        2)
            echo "Recovery: delete the local v${NEW_VER} branch and re-run."
            echo "  git checkout master && git branch -D v${NEW_VER}"
            echo ""
            echo "Then re-run:  $0 ${NEW_VER}"
            echo "(Step 1 will be detected as complete and skipped automatically.)"
            ;;
        3)
            echo "Recovery: reset master to match remote."
            echo "  git checkout master && git reset --hard origin/master"
            echo ""
            echo "Then re-run:  $0 ${NEW_VER}"
            echo "(Steps 1-2 will be detected as complete and skipped automatically.)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Detect which steps are already completed
# ---------------------------------------------------------------------------
detect_completed_steps() {
    STEP1_DONE=false
    STEP2_DONE=false
    STEP3_DONE=false

    git fetch origin

    # Step 1: Is v{PREV_VER} already demoted? (no "current stable" in its CI)
    if git ls-remote --exit-code --heads origin "v${PREV_VER}" >/dev/null 2>&1; then
        local prev_ci
        prev_ci=$(git show "origin/v${PREV_VER}:${CI_FILE}" 2>/dev/null) || true
        if [ -n "$prev_ci" ] && ! echo "$prev_ci" | grep_safe "current stable"; then
            STEP1_DONE=true
        fi
    fi

    # Step 2: Does v{NEW_VER} branch already exist on remote?
    if git ls-remote --exit-code --heads origin "v${NEW_VER}" >/dev/null 2>&1; then
        STEP2_DONE=true
    fi

    # Step 3: Does master CI already deploy v{NEXT_VER}.x dev?
    if grep_safe "mike deploy --push -u v${NEXT_VER}\.x dev" "$CI_FILE"; then
        STEP3_DONE=true
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_check() {
    local errors=0

    # Must be on master
    ORIGINAL_BRANCH=$(git branch --show-current)
    if [ "$ORIGINAL_BRANCH" != "master" ]; then
        echo "ERROR: Must be on master branch (currently on: $ORIGINAL_BRANCH)"
        errors=$((errors + 1))
    fi

    # Working directory must be clean (skip check for dry-run)
    if ! $DRY_RUN; then
        if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
            echo "ERROR: Working directory is not clean. Please commit or stash changes first."
            errors=$((errors + 1))
        fi
    fi

    # Master must be up to date (skip check for dry-run)
    if ! $DRY_RUN; then
        if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ]; then
            echo "ERROR: Local master is not up to date with origin/master. Run 'git pull' first."
            errors=$((errors + 1))
        fi
    fi

    # Previous stable branch must exist
    if ! git ls-remote --exit-code --heads origin "v${PREV_VER}" >/dev/null 2>&1; then
        echo "ERROR: Previous stable branch v${PREV_VER} does not exist on remote."
        errors=$((errors + 1))
    fi

    if [ $errors -gt 0 ]; then
        echo ""
        echo "Pre-flight check failed with $errors error(s). Aborting."
        exit 1
    fi

    # Detect completed steps
    detect_completed_steps

    if $STEP1_DONE || $STEP2_DONE || $STEP3_DONE; then
        echo "Detected completed steps:"
        $STEP1_DONE && echo "  Step 1: v${PREV_VER} already demoted"
        $STEP2_DONE && echo "  Step 2: v${NEW_VER} branch already exists"
        $STEP3_DONE && echo "  Step 3: master already targets v${NEXT_VER}"
        echo ""
    fi

    # Apply --from-step override
    if [ "$FROM_STEP" -gt 1 ]; then
        STEP1_DONE=true
    fi
    if [ "$FROM_STEP" -gt 2 ]; then
        STEP2_DONE=true
    fi

    # Validate that remaining steps can proceed
    if ! $STEP1_DONE; then
        # Step 1 needs "current stable" in prev branch CI
        local prev_ci
        prev_ci=$(git show "origin/v${PREV_VER}:${CI_FILE}" 2>/dev/null) || true
        if [ -n "$prev_ci" ] && ! echo "$prev_ci" | grep_safe "current stable"; then
            echo "WARNING: v${PREV_VER} CI has no 'current stable' to remove. Step 1 will be skipped."
            STEP1_DONE=true
        fi
    fi

    if ! $STEP2_DONE && ! $STEP3_DONE; then
        # Step 2 needs master CI to have v{NEW_VER}.x dev
        if ! grep_safe "mike deploy --push -u v${NEW_VER}\.x dev" "$CI_FILE"; then
            echo "ERROR: Master CI does not deploy v${NEW_VER}.x dev. Is master correctly configured?"
            exit 1
        fi
    fi

    # Check if everything is already done
    if $STEP1_DONE && $STEP2_DONE && $STEP3_DONE; then
        echo "All steps are already complete. Nothing to do."
        echo ""
        echo "Run '$0 --verify ${NEW_VER}' to check the deployed site."
        exit 0
    fi

    echo "Pre-flight checks passed."
}

# ---------------------------------------------------------------------------
# Step 1: Demote previous stable branch
# ---------------------------------------------------------------------------
step1_demote_previous() {
    if $STEP1_DONE; then
        echo ""
        echo "  Step 1/3: SKIP (v${PREV_VER} already demoted)"
        return
    fi

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
        echo "  [DRY RUN] Skipping."
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
    echo "  Done: v${PREV_VER} demoted."
}

# ---------------------------------------------------------------------------
# Step 2: Create new release branch, set as stable
# ---------------------------------------------------------------------------
step2_create_stable() {
    if $STEP2_DONE; then
        echo ""
        echo "  Step 2/3: SKIP (v${NEW_VER} branch already exists)"
        return
    fi

    echo ""
    echo "========================================"
    echo "  Step 2/3: Create v${NEW_VER} as stable"
    echo "========================================"
    echo ""
    echo "  Branch  : v${NEW_VER} (new, from master)"
    echo "  Changes :"
    echo "    ${CI_FILE}:"
    echo "      - Add v${NEW_VER} to trigger branches"
    echo "      - Change mike deploy: dev -> current stable"
    echo "      - Add mike set-default stable"
    echo "    ${MKDOCS_FILE}:"
    echo "      - branch -> release-${NEW_VER}"
    echo "      - cover_subtitle -> v${NEW_VER}.0"
    echo "    ${CONTACT_FILE}:"
    echo "      - PDF link -> v${NEW_VER}.x"
    echo ""

    if $DRY_RUN; then
        echo "  [DRY RUN] Skipping."
        return
    fi

    git checkout master
    git checkout -b "v${NEW_VER}"

    # --- ci.yml ---

    verify_content "$CI_FILE" \
        "mike deploy --push -u v${NEW_VER}\.x dev -t \"v${NEW_VER}\.x (dev)\"" \
        "v${NEW_VER} dev deployment"

    # Add branch trigger after "      - master"
    sed -i "/^      - master$/a\\      - v${NEW_VER}" "$CI_FILE"

    # Change mike deploy: dev -> current stable
    sed -i \
        "s|mike deploy --push -u v${NEW_VER}\.x dev -t \"v${NEW_VER}\.x (dev)\"|mike deploy --push -u v${NEW_VER}.x current stable -t \"v${NEW_VER}.x (stable)\"|" \
        "$CI_FILE"

    # Add mike set-default after deploy line
    sed -i "/mike deploy --push -u v${NEW_VER}\.x current stable/a\\          mike set-default stable --push" "$CI_FILE"

    # Verify
    verify_content "$CI_FILE" \
        "mike deploy --push -u v${NEW_VER}\.x current stable -t \"v${NEW_VER}\.x (stable)\"" \
        "v${NEW_VER} stable deployment"
    verify_content "$CI_FILE" "mike set-default stable --push" "mike set-default"

    if grep "mike deploy" "$CI_FILE" | grep -q " dev "; then
        echo "VERIFY FAILED: 'dev' alias still present in mike deploy command"
        exit 1
    fi

    # --- mkdocs.yml ---

    sed -i "s|branch: release-${PREV_VER}|branch: release-${NEW_VER}|" "$MKDOCS_FILE"
    sed -i "s|cover_subtitle: v.*|cover_subtitle: v${NEW_VER}.0|" "$MKDOCS_FILE"

    verify_content "$MKDOCS_FILE" "branch: release-${NEW_VER}" "branch variable"
    verify_content "$MKDOCS_FILE" "cover_subtitle: v${NEW_VER}\.0" "cover_subtitle"

    # --- contact.md ---

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
    if $STEP3_DONE; then
        echo ""
        echo "  Step 3/3: SKIP (master already targets v${NEXT_VER})"
        return
    fi

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
    echo "      - version -> v${NEXT_VER}.0"
    echo "      - branch -> release-${NEW_VER}"
    echo "      - cover_subtitle -> v${NEXT_VER}.0"
    echo "    ${CONTACT_FILE}:"
    echo "      - PDF link -> v${NEW_VER}.x (points to new stable)"
    echo "    ${NEXT_FILE}:"
    echo "      - Add 'Post-v${NEW_VER}.0' section heading"
    echo ""

    if $DRY_RUN; then
        echo "  [DRY RUN] Skipping."
        return
    fi

    git checkout master

    # --- ci.yml ---

    sed -i \
        "s|mike deploy --push -u v${NEW_VER}\.x dev -t \"v${NEW_VER}\.x (dev)\"|mike deploy --push -u v${NEXT_VER}.x dev -t \"v${NEXT_VER}.x (dev)\"|" \
        "$CI_FILE"

    verify_content "$CI_FILE" \
        "mike deploy --push -u v${NEXT_VER}\.x dev -t \"v${NEXT_VER}\.x (dev)\"" \
        "v${NEXT_VER} dev deployment"

    # --- mkdocs.yml ---

    sed -i "s|version: v${NEW_VER}\.0|version: v${NEXT_VER}.0|" "$MKDOCS_FILE"
    sed -i "s|branch: release-${PREV_VER}|branch: release-${NEW_VER}|" "$MKDOCS_FILE"
    sed -i "s|cover_subtitle: v.*|cover_subtitle: v${NEXT_VER}.0|" "$MKDOCS_FILE"

    verify_content "$MKDOCS_FILE" "version: v${NEXT_VER}\.0" "version variable"
    verify_content "$MKDOCS_FILE" "branch: release-${NEW_VER}" "branch variable"
    verify_content "$MKDOCS_FILE" "cover_subtitle: v${NEXT_VER}\.0" "cover_subtitle"

    # --- contact.md ---

    sed -i "s|/docs/v[0-9]*\.[0-9]*\.x/|/docs/v${NEW_VER}.x/|g" "$CONTACT_FILE"

    verify_content "$CONTACT_FILE" "/docs/v${NEW_VER}\.x/" "PDF link version"

    # --- next.md ---

    if ! grep_safe "## Post-v${NEW_VER}\.0" "$NEXT_FILE"; then
        sed -i "/^This document lists the features/a\\\n## Post-v${NEW_VER}.0" "$NEXT_FILE"
        verify_content "$NEXT_FILE" "## Post-v${NEW_VER}\.0" "new Post section heading"
    fi

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

# Run step 1 with error trap
if ! $STEP1_DONE && ! $DRY_RUN; then
    trap 'on_error 1' ERR
fi
step1_demote_previous

# Run step 2 with error trap
if ! $STEP2_DONE && ! $DRY_RUN; then
    trap 'on_error 2' ERR
fi
step2_create_stable

# Run step 3 with error trap
if ! $STEP3_DONE && ! $DRY_RUN; then
    trap 'on_error 3' ERR
fi
step3_prepare_next

# Clear the error trap
trap cleanup EXIT

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
echo "NOTE: Each push triggers a CI job that deploys to gh-pages."
echo "These jobs may conflict if they run concurrently."
echo "If a CI job fails with a push conflict, re-run it from"
echo "GitHub Actions — the retry will succeed once the other"
echo "jobs finish."
echo ""
echo "Verify the deployment (after CI completes):"
echo "  $0 --verify ${NEW_VER}"
echo ""
