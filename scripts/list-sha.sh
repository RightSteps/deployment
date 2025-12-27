#!/bin/bash

# ============================================================================
# List All SHA Deployments
# ============================================================================
# Usage: ./list-sha.sh
# ============================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Active SHA Deployments${NC}"
echo -e "${BLUE}======================================${NC}"

# Get all SHA backend containers
SHA_CONTAINERS=$(docker ps --filter "name=^backend-[a-f0-9]{7}$" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}" | tail -n +2)

if [ -z "$SHA_CONTAINERS" ]; then
    echo -e "${YELLOW}No active SHA deployments found.${NC}"
    exit 0
fi

echo -e "${GREEN}Container Name\t\tStatus\t\t\tCreated${NC}"
echo "$SHA_CONTAINERS"

echo -e ""
echo -e "${BLUE}======================================${NC}"

# Count
COUNT=$(echo "$SHA_CONTAINERS" | wc -l | tr -d ' ')
echo -e "Total: ${GREEN}${COUNT}${NC} deployment(s)"

# Show URLs
echo -e ""
echo -e "${YELLOW}Deployment URLs:${NC}"
while IFS= read -r line; do
    CONTAINER=$(echo "$line" | awk '{print $1}')
    SHA=$(echo "$CONTAINER" | sed 's/backend-//')
    echo -e "  • https://${SHA}.rightsteps.app"
done <<< "$SHA_CONTAINERS"
