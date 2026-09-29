#!/bin/bash

# ClawHub Skill Search Tool (corrected 2026-09-28)
# Usage: clawhub-search.sh [keyword]
#   No keyword -> top skills by downloads
#   Keyword    -> keyword search via /api/v1/search

set -e

API_BASE="https://clawhub.ai/api/v1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

search_keyword="$1"

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Install with: sudo apt-get install jq"
    exit 1
fi

if [ -n "$search_keyword" ]; then
    echo -e "${BLUE}Searching ClawHub for: ${YELLOW}$search_keyword${NC}..."
    json=$(curl -s "$API_BASE/search?q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$search_keyword")")
    # /api/v1/search returns { results: [...] }
    skills_json=$(echo "$json" | jq '[ .results[] | { slug, displayName, canonicalUrl, downloads, summary } ] | sort_by(.downloads) | reverse | .[0:20]')
else
    echo -e "${BLUE}Fetching top ClawHub skills by downloads...${NC}"
    json=$(curl -s "$API_BASE/skills?sort=downloads")
    # /api/v1/skills returns { items: [...] } with stats.downloads
    skills_json=$(echo "$json" | jq '[ .items[] | { slug, displayName, canonicalUrl: ("/" + (.ownerHandle // "?") + "/skills/" + .slug), downloads: .stats.downloads, summary } ] | sort_by(.downloads) | reverse | .[0:20]')
fi

count=$(echo "$skills_json" | jq 'length')
if [ "$count" -eq 0 ]; then
    echo -e "${YELLOW}No results.${NC}"
    exit 0
fi

echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  ClawHub Skills (${count} shown)${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"

echo "$skills_json" | jq -r '.[] | @base64' | while read -r encoded; do
    skill=$(echo "$encoded" | base64 -d)
    slug=$(echo "$skill" | jq -r '.slug // "N/A"')
    displayName=$(echo "$skill" | jq -r '.displayName // "N/A"')
    summary=$(echo "$skill" | jq -r '.summary // ""')
    downloads=$(echo "$skill" | jq -r '.downloads // 0')
    owner=$(echo "$skill" | jq -r '(.canonicalUrl // "/?/skills/x") | split("/")[1]')

    if [ ${#summary} -gt 90 ]; then summary="${summary:0:87}..."; fi

    echo -e "${GREEN}$slug${NC} ${BLUE}(@$owner)${NC}"
    echo -e "  ${BLUE}Name:${NC} $displayName"
    [ -n "$summary" ] && echo -e "  ${BLUE}Summary:${NC} $summary"
    echo -e "  ${BLUE}Downloads:${NC} $downloads"
    echo ""
done

echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
echo -e "Install (unambiguous slug): ${YELLOW}letta skills install clawhub:<slug> --agent \$AGENT_ID${NC}"
echo -e "Install (ambiguous slug, use owner): ${YELLOW}clawhub-download.sh @<owner>/<slug>${NC}"
echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
