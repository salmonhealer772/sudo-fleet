#!/bin/bash

# ClawHub Skill Download Tool (corrected 2026-09-28)
# Usage:
#   clawhub-download.sh <slug>            # unambiguous slug
#   clawhub-download.sh @<owner>/<slug>   # ambiguous slug (owner required)
#   clawhub-download.sh <owner>/<slug>
#   clawhub-download.sh https://clawhub.ai/owner/slug

set -e

API_BASE="https://clawhub.ai/api/v1"
MEMFS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"   # <memory>/skills sits under <memory>
SKILLS_DIR="${MEMFS_DIR}/skills"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

input="$1"
if [ -z "$input" ]; then
    echo -e "${RED}Usage: $0 <slug> | @<owner>/<slug> | https://clawhub.ai/<owner>/<slug>${NC}"
    exit 1
fi

# Parse owner + slug
owner=""
slug="$input"
case "$input" in
    https://clawhub.ai/*|http://clawhub.ai/*)
        # /owner/skills/slug -> owner + slug
        owner=$(echo "$input" | sed -E 's#https?://clawhub.ai/##; s#/.*##')
        slug=$(echo "$input" | sed -E 's#https?://clawhub.ai/([^/]+)/([^/]+/)?##; s#/.*##')
        ;;
    @*/*)
        owner="${input#@}"; owner="${owner%%/*}"; slug="${input#*/}"
        ;;
    */*)
        owner="${input%%/*}"; slug="${input#*/}"
        ;;
esac

if ! command -v curl >&/dev/null || ! command -v unzip >&/dev/null || ! command -v jq >&/dev/null; then
    echo -e "${RED}Requires curl, unzip, jq.${NC}"
    exit 1
fi

# Resolve version via detail endpoint. Ambiguous slug needs ownerHandle, else bare works.
if [ -n "$owner" ]; then
    detail=$(curl -s "$API_BASE/skills/$slug?ownerHandle=$owner")
else
    detail=$(curl -s "$API_BASE/skills/$slug")
fi

# If bare slug resolves to an AMBIGUOUS error, surface the owners.
if echo "$detail" | jq -e '.code == "AMBIGUOUS_SKILL_SLUG"' >/dev/null 2>&1; then
    echo -e "${RED}Ambiguous slug \"$slug\". Available owners:${NC}"
    echo "$detail" | jq -r '.matches[] | "  @\(.ownerHandle)/\(.slug)"'
    echo -e "${YELLOW}Re-run with: $0 @<owner>/$slug${NC}"
    exit 1
fi

version=$(echo "$detail" | jq -r '.latestVersion.version // .skill.tags.latest // empty')
if [ -z "$version" ] || [ "$version" = "null" ]; then
    version=$(echo "$detail" | jq -r '.tags.latest // empty')
fi
if [ -z "$version" ] || [ "$version" = "null" ]; then
    echo -e "${RED}Could not resolve version for $slug.${NC}"
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dl_url="$API_BASE/download?slug=$slug&version=$version"
[ -n "$owner" ] && dl_url="$dl_url&ownerHandle=$owner"

echo -e "${YELLOW}Downloading $slug@$version${NC} ${BLUE}(owner: ${owner:-<optional>})${NC}..."
code=$(curl -s -w "%{http_code}" -o "$tmp/skill.zip" "$dl_url")
if [ "$code" != "200" ]; then
    echo -e "${RED}Download failed (HTTP $code): $dl_url${NC}"
    exit 1
fi

unzip -o -q "$tmp/skill.zip" -d "$tmp/extracted"

if [ ! -f "$tmp/extracted/SKILL.md" ]; then
    echo -e "${RED}Package has no SKILL.md. Contents:${NC}"
    ls -la "$tmp/extracted"
    exit 1
fi

name=$(grep -m1 '^name:' "$tmp/extracted/SKILL.md" | sed 's/^name: *//; s/"//g')
[ -z "$name" ] && name="$slug"

dest="$SKILLS_DIR/$name"
mkdir -p "$dest"
cp -r "$tmp/extracted/." "$dest/"
chmod +x "$dest"/*.sh 2>/dev/null || true

echo -e "${GREEN}✓ Installed to $dest${NC}"
echo -e "${YELLOW}Commit it so the harness picks it up:${NC}"
echo -e "  cd \$(dirname \"$dest\")/.. && git add skills/$name && git commit -m 'add skill: $name'"
ls -la "$dest"
