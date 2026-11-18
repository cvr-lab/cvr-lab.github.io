#!/usr/bin/env bash
set -euo pipefail

SLUG=""
MODE="add"
ALLOW_NO_PHOTO=0
BASE_BRANCH="main"
REMOTE="origin"
REPO_URL="https://github.com/cvr-lab/cvr-lab-website"
REPO_SLUG="cvr-lab/cvr-lab-website"

info()    { echo ""; echo "==> $1"; }
success() { echo "    [OK] $1"; }
warn()    { echo "    [!!] $1"; }
error()   { echo ""; echo "ERROR: $1" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  submit_person.sh <slug> [options]

Options:
  --update          The person already exists (for example, to hide them or change
                    their data). Uses the branch 'update-person-<slug>'.
  --no-photo        Submit even if there is no photo in assets/media/authors/

Examples:
  submit_person.sh jane-doe
  submit_person.sh jane-doe --update
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)   MODE="update"; shift ;;
        --no-photo) ALLOW_NO_PHOTO=1; shift ;;
        -h|--help)  usage ;;
        -*)         error "Unknown option: $1" ;;
        *)
            [[ -z "$SLUG" ]] || error "Unexpected argument: $1"
            SLUG="$1"; shift ;;
    esac
done

[[ -n "$SLUG" ]] || usage

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || error "Run this script from inside the repository."

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PROFILE_REL="data/authors/$SLUG.yaml"
PHOTO_PREFIX="assets/media/authors/$SLUG."
PAGE_REL="content/authors/$SLUG/"
BRANCH="$MODE-person-$SLUG"

if [[ ! "$SLUG" =~ ^[^/[:space:]]+$ ]]; then
    error "Invalid slug."
fi

# ── Check project files ──────────────────────────────────────────────────────
info "Checking the person's files..."

[[ -f "$PROFILE_REL" ]] \
    || error "Profile not found: $PROFILE_REL"

if [[ "$MODE" == "update" ]]; then
    git ls-files --error-unmatch "$PROFILE_REL" >/dev/null 2>&1 \
        || error "'$SLUG' is not in the repository yet. Submit it without --update."
else
    if git ls-files --error-unmatch "$PROFILE_REL" >/dev/null 2>&1; then
        error "'$SLUG' already exists in the repository. Use --update to change it."
    fi
fi

# Lines that still say TODO (comments are ignored)
TODO_LINES="$(grep -nE '^[[:space:]]*[^#[:space:]].*TODO' "$PROFILE_REL" || true)"
if [[ -n "$TODO_LINES" ]]; then
    echo "" >&2
    echo "$TODO_LINES" >&2
    error "The profile still has TODO lines. Replace them before submitting."
fi

PHOTOS=()
for f in "$PHOTO_PREFIX"*; do
    [[ -e "$f" ]] && PHOTOS+=("$f")
done

if [[ ${#PHOTOS[@]} -eq 0 ]]; then
    if [[ "$ALLOW_NO_PHOTO" -eq 1 ]]; then
        warn "No photo found: a generic icon will be shown."
    else
        error "No photo found in assets/media/authors/ named '$SLUG.*'. Add it, or use --no-photo."
    fi
else
    success "Photo: ${PHOTOS[0]}"
fi

# Name of the person, for the commit and the PR (falls back to the slug)
DISPLAY_NAME="$(grep -m1 -E '^[[:space:]]+display:' "$PROFILE_REL" \
    | sed -E 's/^[[:space:]]+display:[[:space:]]*//; s/^"//; s/"[[:space:]]*$//' || true)"
[[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$SLUG"

# ── Repository state ─────────────────────────────────────────────────────────
info "Checking Git repository..."

CURRENT_BRANCH="$(git branch --show-current)"

[[ "$CURRENT_BRANCH" == "$BASE_BRANCH" ]] \
    || error "Please switch to '$BASE_BRANCH' before submitting."

CHANGES="$(git -c core.quotepath=false status --porcelain --untracked-files=all)"

[[ -n "$CHANGES" ]] \
    || error "No pending changes found."

UNRELATED="$(printf '%s\n' "$CHANGES" |
    awk -v p1="$PROFILE_REL" -v p2="$PHOTO_PREFIX" -v p3="$PAGE_REL" '
    {
        path = substr($0, 4)
        gsub(/^"|"$/, "", path)
        if (path == p1 || index(path, p2) == 1 || index(path, p3) == 1) next
        print
    }')"

[[ -z "$UNRELATED" ]] || {
    echo "$UNRELATED" >&2
    error "There are changes outside this person's files. Please commit or discard them first."
}

# ── Update main ──────────────────────────────────────────────────────────────
info "Updating local main branch..."

git fetch "$REMOTE"
git pull --ff-only "$REMOTE" "$BASE_BRANCH"

success "Main branch updated."

# ── Branch ───────────────────────────────────────────────────────────────────
info "Checking whether the submission branch already exists..."

if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    error "Remote branch '$BRANCH' already exists. Please resolve the previous submission first."
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    error "Local branch '$BRANCH' already exists."
fi

info "Creating branch '$BRANCH'..."

git switch -c "$BRANCH"

success "Branch created."

# ── Commit ───────────────────────────────────────────────────────────────────
info "Adding the person's files..."

TO_ADD=("$PROFILE_REL")
[[ ${#PHOTOS[@]} -eq 0 ]] || TO_ADD+=("${PHOTOS[@]}")
[[ -d "$PAGE_REL" ]] && TO_ADD+=("$PAGE_REL")

git add -- "${TO_ADD[@]}"

if git diff --cached --quiet; then
    error "No new changes to commit."
fi

if [[ "$MODE" == "update" ]]; then
    MESSAGE="Update person: $DISPLAY_NAME"
else
    MESSAGE="Add person: $DISPLAY_NAME"
fi

git commit -m "$MESSAGE"

success "Changes committed."

# ── Push ─────────────────────────────────────────────────────────────────────
info "Uploading to GitHub..."

git push -u "$REMOTE" "$BRANCH"

success "Branch uploaded."

# ── Pull Request ─────────────────────────────────────────────────────────────
PR_URL="$REPO_URL/compare/$BASE_BRANCH...$BRANCH?expand=1"

info "Creating Pull Request..."

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI detected and authenticated."

    gh pr create \
        --repo "$REPO_SLUG" \
        --base "$BASE_BRANCH" \
        --head "$BRANCH" \
        --title "$MESSAGE" \
        --body "This PR ${MODE}s the person '$DISPLAY_NAME' ($SLUG) on the CVR Lab website.

Please review the profile data, the group, the photo and that the personal page loads."

    success "Pull Request created successfully."
else
    echo ""
    echo "GitHub CLI is not installed or not authenticated."
    echo "The changes have been uploaded, but the Pull Request must be created manually."
    echo ""
    echo "Open this link to create the Pull Request:"
    echo "$PR_URL"
    echo ""
fi

info "Submission process finished."