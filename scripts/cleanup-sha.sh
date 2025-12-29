#!/bin/bash

# ============================================================================
# Cleanup Old SHA Deployments
# ============================================================================
# Usage: ./cleanup-sha.sh [keep_count]
# Example: ./cleanup-sha.sh 3  (keeps last 3 deployments)
# Default: keeps last 3 deployments
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

KEEP_COUNT=${1:-3}

echo -e "${YELLOW}Cleaning up SHA deployments (keeping last ${KEEP_COUNT})...${NC}"

# Set deployment directory
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

# Get all RUNNING SHA deployments sorted by creation time (oldest first)
# Using 'docker ps' (not 'docker ps -a') to only consider running containers
SHA_CONTAINERS=$(docker ps --filter "name=^backend-[a-f0-9]{7}$" --format "{{.CreatedAt}}\t{{.Names}}" | sort | awk '{print $NF}')

# Count total deployments
TOTAL=$(echo "$SHA_CONTAINERS" | grep -c "backend-" || true)

if [ "$TOTAL" -le "$KEEP_COUNT" ]; then
    echo -e "${GREEN}✓ Only ${TOTAL} SHA deployment(s) found. No cleanup needed.${NC}"
    exit 0
fi

# Calculate how many to remove
REMOVE_COUNT=$((TOTAL - KEEP_COUNT))

echo -e "${YELLOW}Found ${TOTAL} SHA deployment(s), removing oldest ${REMOVE_COUNT}...${NC}"

# Get containers to remove (oldest ones)
TO_REMOVE=$(echo "$SHA_CONTAINERS" | head -n "$REMOVE_COUNT")

# Remove each old deployment
for CONTAINER in $TO_REMOVE; do
    SHA=$(echo "$CONTAINER" | sed 's/backend-//')
    echo -e "${YELLOW}Removing deployment: ${SHA}${NC}"

    # Stop and remove containers
    if [ -f "docker-compose.sha-${SHA}.yml" ]; then
        docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" down -v 2>/dev/null || true
        rm -f "docker-compose.sha-${SHA}.yml"
    else
        # Fallback: remove containers directly
        docker stop "backend-${SHA}" "postgres-${SHA}" "redis-${SHA}" 2>/dev/null || true
        docker rm "backend-${SHA}" "postgres-${SHA}" "redis-${SHA}" 2>/dev/null || true
        docker volume rm "deployment_postgres_sha_${SHA}_data" "deployment_redis_sha_${SHA}_data" 2>/dev/null || true
    fi

    # Remove Nginx routing entry
    NGINX_MAP_FILE="/etc/nginx/conf.d/sha-routing-map.conf"
    if [ -f "$NGINX_MAP_FILE" ]; then
        if grep -q "${SHA}.rightsteps.app" "$NGINX_MAP_FILE" 2>/dev/null; then
            echo -e "${YELLOW}Removing Nginx routing for ${SHA}...${NC}"
            sudo sed -i "/${SHA}.rightsteps.app/d" "$NGINX_MAP_FILE"
            sudo nginx -s reload 2>/dev/null || echo -e "${YELLOW}⚠ Could not reload Nginx${NC}"
        fi
    fi

    echo -e "${GREEN}✓ Removed deployment: ${SHA}${NC}"
done

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Cleanup Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo -e "Removed: ${REMOVE_COUNT} deployment(s)"
echo -e "Keeping: ${KEEP_COUNT} deployment(s)"

# Show remaining deployments
echo -e ""
echo -e "${YELLOW}Remaining SHA deployments:${NC}"
./scripts/list-sha.sh
