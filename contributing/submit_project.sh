#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${1:-}"
BASE_BRANCH="main"
REMOTE="origin"
REPO_URL="https://github.com/cvr-lab/cvr-lab-website"
PROJECT_DIR="content/projects/$PROJECT_NAME"
BRANCH="add-project-$PROJECT_NAME"

info() {
    echo ""
    echo "==> $1"
}

success() {
    echo "    [OK] $1"
}

error() {
    echo ""
    echo "ERROR: $1" >&2
    exit 1
}

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Usage: $0 <project-name>"
    exit 1
fi

if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "Invalid project name."
fi

# Check repository
info "Checking Git repository..."

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || error "Run this script from inside the repository."

CURRENT_BRANCH=$(git branch --show-current)

[[ "$CURRENT_BRANCH" == "$BASE_BRANCH" ]] \
    || error "Please switch to '$BASE_BRANCH' before submitting."

# Check project
info "Checking project files..."

[[ -f "$PROJECT_DIR/index.md" ]] \
    || error "Project file not found: $PROJECT_DIR/index.md"

# Check pending changes
CHANGES=$(git status --porcelain --untracked-files=all)

[[ -n "$CHANGES" ]] \
    || error "No pending changes found."

UNRELATED=$(printf '%s\n' "$CHANGES" | grep -vF "$PROJECT_DIR/" || true)

[[ -z "$UNRELATED" ]] \
    || error "There are changes outside $PROJECT_DIR. Please commit or discard them first."

# Update main
info "Updating local main branch..."

git fetch "$REMOTE"
git pull --ff-only "$REMOTE" "$BASE_BRANCH"

success "Main branch updated."

# Check remote branch
info "Checking whether the submission branch already exists..."

if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    error "Remote branch '$BRANCH' already exists. Please resolve the previous submission first."
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    error "Local branch '$BRANCH' already exists."
fi

# Create branch
info "Creating branch '$BRANCH'..."

git switch -c "$BRANCH"

success "Branch created."

# Stage files
info "Adding project files..."

git add -- "$PROJECT_DIR"

if git diff --cached --quiet; then
    error "No new changes to commit."
fi

git commit -m "Add project: $PROJECT_NAME"

success "Project committed."

# Push
info "Uploading project to GitHub..."

git push -u "$REMOTE" "$BRANCH"

success "Project uploaded."

# Pull Request
PR_URL="$REPO_URL/compare/$BASE_BRANCH...$BRANCH?expand=1"

info "Creating Pull Request..."

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI detected and authenticated."

    gh pr create \
        --repo cvr-lab/cvr-lab-website \
        --base "$BASE_BRANCH" \
        --head "$BRANCH" \
        --title "Add project: $PROJECT_NAME" \
        --body "This PR adds the project '$PROJECT_NAME' to the CVR Lab website.

Please review the project description, metadata, links and images."

    success "Pull Request created successfully."
else
    echo ""
    echo "GitHub CLI is not installed or not authenticated."
    echo "The project has been uploaded, but the Pull Request must be created manually."
    echo ""
    echo "Open this link to create the Pull Request:"
    echo "$PR_URL"
    echo ""
fi

info "Submission process finished."
