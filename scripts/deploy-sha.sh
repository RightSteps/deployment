#!/bin/bash

# ============================================================================
# Deploy SHA-based Preview Environment
# ============================================================================
# Usage: ./deploy-sha.sh <sha> <docker-username>
# Example: ./deploy-sha.sh abc1234 myusername
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check arguments
if [ $# -lt 2 ]; then
    echo -e "${RED}Error: Missing arguments${NC}"
    echo "Usage: $0 <sha> <docker-username>"
    echo "Example: $0 abc1234 myusername"
    exit 1
fi

SHA=$1
DOCKER_USERNAME=$2
SHA_TAG="sha-${SHA}"

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Deploying SHA: ${SHA}${NC}"
echo -e "${GREEN}======================================${NC}"

# Set deployment directory
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEPLOY_DIR"

# Check if network exists
if ! docker network ls | grep -q app-network; then
    echo -e "${YELLOW}Creating app-network...${NC}"
    docker network create app-network
fi

# Pull latest image
echo -e "${YELLOW}Pulling image: ${DOCKER_USERNAME}/rightsteps-backend:${SHA_TAG}${NC}"
docker pull "${DOCKER_USERNAME}/rightsteps-backend:${SHA_TAG}"

# Check if deployment already exists
if docker ps -a --format '{{.Names}}' | grep -q "^backend-${SHA}$"; then
    echo -e "${YELLOW}Deployment backend-${SHA} already exists. Removing...${NC}"
    docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" down -v 2>/dev/null || true
    rm -f "docker-compose.sha-${SHA}.yml"
fi

# Generate docker compose file from template
echo -e "${YELLOW}Generating docker-compose.sha-${SHA}.yml...${NC}"
export SHA="${SHA}"
export SHA_TAG="${SHA_TAG}"
export DOCKER_USERNAME="${DOCKER_USERNAME}"

# Source environment variables
if [ -f .env.sha ]; then
    set -a
    source .env.sha
    set +a
else
    echo -e "${RED}Error: .env.sha not found${NC}"
    exit 1
fi

# Create docker compose file
envsubst < docker-compose.sha-template.yml > "docker-compose.sha-${SHA}.yml"

# Deploy with unique project name for this SHA
echo -e "${YELLOW}Starting deployment...${NC}"
docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" up -d

# Wait for health check
echo -e "${YELLOW}Waiting for deployment to be healthy...${NC}"
sleep 5

MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if docker inspect --format='{{.State.Health.Status}}' "backend-${SHA}" 2>/dev/null | grep -q "healthy"; then
        echo -e "${GREEN}✓ Deployment backend-${SHA} is healthy!${NC}"
        echo -e "${GREEN}✓ Accessible at: https://${SHA}.rightsteps.app${NC}"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo -n "."
    sleep 2
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo -e "${RED}✗ Deployment failed to become healthy${NC}"
    echo -e "${YELLOW}Check logs: docker logs backend-${SHA}${NC}"
    exit 1
fi

# Cleanup old deployments (keep last 3)
echo -e "${YELLOW}Checking for old deployments...${NC}"
./scripts/cleanup-sha.sh 3

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo -e "SHA: ${SHA}"
echo -e "URL: https://${SHA}.rightsteps.app"
echo -e "Container: backend-${SHA}"
echo -e ""
echo -e "View logs: docker logs -f backend-${SHA}"
echo -e "Stop: docker compose -p rightsteps-sha-${SHA} -f docker-compose.sha-${SHA}.yml down"
