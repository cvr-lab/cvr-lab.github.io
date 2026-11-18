#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTHORS_DIR="$ROOT_DIR/data/authors"
PHOTOS_DIR="$ROOT_DIR/assets/media/authors"
PAGES_DIR="$ROOT_DIR/content/authors"
PEOPLE_PAGE="$ROOT_DIR/content/people/index.md"
TEMPLATE="$ROOT_DIR/contributing/templates/person-template.yaml"

info()    { echo ""; echo "==> $1"; }
success() { echo "    [OK] $1"; }
warn()    { echo "    [!!] $1"; }
error()   { echo ""; echo "ERROR: $1" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  create_new_person.sh "Full Name" [options]

Options:
  -g, --group GROUP     Group in /people/ (default: "Grad Students")
  -r, --role ROLE       Role shown on the card
  -e, --email EMAIL     Email
  -b, --bio TEXT        Short description (the card shows two lines)
  -w, --weight N        Order inside the group (default: 100)
  -p, --photo FILE      Photo to copy (jpg, jpeg, png or webp; square if possible)
      --given NAME      Given name (default: the name without the last word)
      --family NAME     Family name, for two surnames (default: the last word)
      --slug SLUG       Use this slug instead of the one derived from the name
      --from FILE       Use your own draft of the profile instead of the template
                        (it cannot be the profile of another person)
      --no-page         Do not create content/authors/<slug>/_index.md

Examples:
  create_new_person.sh "Jane Doe"
  create_new_person.sh "Jane Doe" -g "Grad Students" -e jane@ugr.es -p ~/photo.jpg
  create_new_person.sh "Ana Lopez Perez" --family "Lopez Perez"
EOF
    exit 1
}

# ── Arguments ────────────────────────────────────────────────────────────────
NAME=""
GROUP="Grad Students"
ROLE="TODO role"
EMAIL="TODO@ugr.es"
BIO="TODO short description"
WEIGHT="100"
PHOTO=""
SLUG=""
GIVEN=""
FAMILY=""
FROM_FILE=""
MAKE_PAGE=1

[[ $# -ge 1 ]] || usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--group)  GROUP="${2:?Missing value for $1}"; shift 2 ;;
        -r|--role)   ROLE="${2:?Missing value for $1}"; shift 2 ;;
        -e|--email)  EMAIL="${2:?Missing value for $1}"; shift 2 ;;
        -b|--bio)    BIO="${2:?Missing value for $1}"; shift 2 ;;
        -w|--weight) WEIGHT="${2:?Missing value for $1}"; shift 2 ;;
        -p|--photo)  PHOTO="${2:?Missing value for $1}"; shift 2 ;;
        --given)     GIVEN="${2:?Missing value for $1}"; shift 2 ;;
        --family)    FAMILY="${2:?Missing value for $1}"; shift 2 ;;
        --slug)      SLUG="${2:?Missing value for $1}"; shift 2 ;;
        --from)      FROM_FILE="${2:?Missing value for $1}"; shift 2 ;;
        --no-page)   MAKE_PAGE=0; shift ;;
        -h|--help)   usage ;;
        -*)          error "Unknown option: $1" ;;
        *)
            [[ -z "$NAME" ]] || error "Unexpected argument: $1 (put the full name between quotes)."
            NAME="$1"; shift ;;
    esac
done

[[ -n "$NAME" ]] || usage
[[ "$WEIGHT" =~ ^[0-9]+$ ]] || error "The weight must be a number."

# ── Helpers ──────────────────────────────────────────────────────────────────
# Escape a value so it can be written inside a double-quoted YAML string.
yaml_escape() {
    local v="${1//\\/\\\\}"
    printf '%s' "${v//\"/\\\"}"
}

# Name in lowercase, with dashes instead of spaces. Accents are kept (that is how the
# site computes it when it looks for the profile of an author).
make_slug() {
    printf '%s' "$1" | perl -CSDA -Mutf8 -pe '$_ = lc; s/[^\p{L}\p{N}_ -]//g; s/\s+/-/g; s/-+/-/g; s/^-|-$//g'
}

top_keys() { grep -oE '^[A-Za-z_]+:' "$1" | sort -u; }

command -v perl >/dev/null 2>&1 || error "perl is required."

[[ -n "$SLUG" ]] || SLUG="$(make_slug "$NAME")"

# Given and family name: by default the family name is the last word. With two surnames,
# pass --family "Lopez Perez" and the given name is whatever comes before it.
if [[ -z "$FAMILY" ]]; then
    FAMILY="$(printf '%s' "$NAME" | awk '{print $NF}')"
fi
if [[ -z "$GIVEN" ]]; then
    if [[ "$NAME" == *" $FAMILY" ]]; then
        GIVEN="${NAME% "$FAMILY"}"
    else
        GIVEN="${NAME%% *}"
    fi
fi
[[ -n "$SLUG" ]] || error "Could not derive a slug from '$NAME'."

PROFILE="$AUTHORS_DIR/$SLUG.yaml"
PAGE_DIR="$PAGES_DIR/$SLUG"

# ── Checks ───────────────────────────────────────────────────────────────────
info "Checking..."

if [[ -f "$PROFILE" ]]; then
    error "This person already exists: $PROFILE"
fi

if [[ -n "$FROM_FILE" ]]; then
    [[ -f "$FROM_FILE" ]] || error "Source file not found: $FROM_FILE"
    FROM_REAL="$(cd "$(dirname "$FROM_FILE")" && pwd -P)/$(basename "$FROM_FILE")"
    case "$FROM_REAL" in
        "$(cd "$AUTHORS_DIR" 2>/dev/null && pwd -P)"/*)
            error "--from cannot be the profile of another person ($FROM_FILE): its role, links, group and email would be copied. Use the template, or a draft outside data/authors/." ;;
    esac
    SOURCE="$FROM_FILE"
else
    [[ -f "$TEMPLATE" ]] || error "Template not found: $TEMPLATE"
    SOURCE="$TEMPLATE"
fi

if [[ -n "$PHOTO" ]]; then
    [[ -f "$PHOTO" ]] || error "Photo not found: $PHOTO"
    EXT="${PHOTO##*.}"
    EXT="$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')"
    [[ "$EXT" =~ ^(jpg|jpeg|png|webp)$ ]] || error "The photo must be jpg, jpeg, png or webp."
    compgen -G "$PHOTOS_DIR/$SLUG.*" >/dev/null && error "A photo for '$SLUG' already exists in $PHOTOS_DIR"
fi

if [[ -d "$PAGE_DIR" ]]; then
    warn "$PAGE_DIR already exists: it will not be touched."
    MAKE_PAGE=0
fi

if [[ -f "$PEOPLE_PAGE" ]]; then
    if awk -v g="$GROUP" '
        { s = $0; sub(/^[ \t]*-[ \t]+/, "", s); sub(/[ \t]+$/, "", s); if (s == g) found = 1 }
        END { exit !found }' "$PEOPLE_PAGE"; then
        success "Group '$GROUP' found in content/people/index.md."
    else
        warn "Group '$GROUP' is NOT listed in content/people/index.md: the card will not appear in /people/."
    fi
fi

if [[ -n "$(printf '%s' "$NAME" | LC_ALL=C tr -d '\000-\177')" ]]; then
    warn "The name has accents or special characters. The profile will be '$SLUG.yaml'."
    warn "Write the name EXACTLY like this in 'authors:' and check the link in the preview."
fi

success "Slug: $SLUG"

# ── Create the profile ───────────────────────────────────────────────────────
info "Creating the profile..."

mkdir -p "$AUTHORS_DIR"

P_NAME="$(yaml_escape "$NAME")"
P_GIVEN="$(yaml_escape "$GIVEN")"
P_FAMILY="$(yaml_escape "$FAMILY")"
P_ROLE="$(yaml_escape "$ROLE")"
P_BIO="$(yaml_escape "$BIO")"
P_EMAIL="$EMAIL"
P_GROUP="$GROUP"
P_WEIGHT="$WEIGHT"
P_SLUG="$SLUG"
export P_NAME P_GIVEN P_FAMILY P_ROLE P_BIO P_EMAIL P_GROUP P_WEIGHT P_SLUG

if [[ -n "$FROM_FILE" ]]; then
    # Your own draft: only the identity is rewritten (slug, name) and the owner flag removed.
    perl -0pe '
        s/^slug:.*$/slug: $ENV{P_SLUG}/m;
        s/^(\s+display:).*$/$1 "$ENV{P_NAME}"/m;
        s/^(\s+given:).*$/$1 "$ENV{P_GIVEN}"/m;
        s/^(\s+family:).*$/$1 "$ENV{P_FAMILY}"/m;
        s/^is_owner:.*\n//m;
    ' "$SOURCE" > "$PROFILE"
    warn "Created from your draft $(basename "$SOURCE"): slug and name were updated, the rest is as you wrote it."
else
    perl -0pe '
        s/__SLUG__/$ENV{P_SLUG}/g;
        s/__NAME__/$ENV{P_NAME}/g;
        s/__GIVEN__/$ENV{P_GIVEN}/g;
        s/__FAMILY__/$ENV{P_FAMILY}/g;
        s/__ROLE__/$ENV{P_ROLE}/g;
        s/__BIO__/$ENV{P_BIO}/g;
        s/__EMAIL__/$ENV{P_EMAIL}/g;
        s/__GROUP__/$ENV{P_GROUP}/g;
        s/__WEIGHT__/$ENV{P_WEIGHT}/g;
    ' "$SOURCE" > "$PROFILE"
fi

success "Profile created: data/authors/$SLUG.yaml"

# Compare the structure with an existing profile, to catch a template that no longer fits.
# (preferably one that is already in the repository, not one created a moment ago)
REFERENCE="$(git -C "$ROOT_DIR" ls-files 'data/authors/*.yaml' 2>/dev/null | head -n 1 || true)"
[[ -z "$REFERENCE" ]] || REFERENCE="$ROOT_DIR/$REFERENCE"
[[ -n "$REFERENCE" && -f "$REFERENCE" ]] \
    || REFERENCE="$(find "$AUTHORS_DIR" -maxdepth 1 -name '*.yaml' ! -name "$SLUG.yaml" | sort | head -n 1)"
if [[ -n "$REFERENCE" ]]; then
    # Optional fields (interests, education, is_owner...) are not reported when they are
    # only in the existing profile.
    OPTIONAL_KEYS="interests: education: is_owner: pronouns: status:"
    ONLY_NEW="$(comm -23 <(top_keys "$PROFILE") <(top_keys "$REFERENCE") | sed 's/^/  only in the new profile: /')"
    ONLY_OLD="$(comm -13 <(top_keys "$PROFILE") <(top_keys "$REFERENCE") | grep -vxF -f <(printf '%s\n' $OPTIONAL_KEYS) | sed 's/^/  only in the existing profile: /' || true)"
    DIFF="$(printf '%s\n%s' "$ONLY_NEW" "$ONLY_OLD" | sed '/^$/d')"
    if [[ -n "$DIFF" ]]; then
        warn "Fields differ from $(basename "$REFERENCE"). Check that nothing is missing:"
        echo "$DIFF"
    else
        success "Same fields as $(basename "$REFERENCE")."
    fi
fi

# ── Photo ────────────────────────────────────────────────────────────────────
if [[ -n "$PHOTO" ]]; then
    info "Copying the photo..."
    mkdir -p "$PHOTOS_DIR"
    cp "$PHOTO" "$PHOTOS_DIR/$SLUG.$EXT"
    success "Photo copied: assets/media/authors/$SLUG.$EXT"
fi

# ── Personal page ────────────────────────────────────────────────────────────
if [[ "$MAKE_PAGE" -eq 1 ]]; then
    info "Creating the personal page (needed while the person is not cited anywhere)..."
    mkdir -p "$PAGE_DIR"
    cat > "$PAGE_DIR/_index.md" <<EOF
---
title: "$P_NAME"
---
EOF
    success "Created: content/authors/$SLUG/_index.md"
fi

# ── Next steps ───────────────────────────────────────────────────────────────
info "Person created."
echo "    Profile: $PROFILE"
[[ -n "$PHOTO" ]] && echo "    Photo:   $PHOTOS_DIR/$SLUG.$EXT"
echo ""
echo "Next steps:"
echo "  1. Edit the profile and replace every line marked TODO."
[[ -n "$PHOTO" ]] || echo "  2. Add a photo: assets/media/authors/$SLUG.jpg (square, at least 460 x 460 px)."
echo "  3. Preview with 'hugo server': http://localhost:1313/people/ and http://localhost:1313/authors/$SLUG/"
echo "  4. Submit it: contributing/submit_person.sh $SLUG"