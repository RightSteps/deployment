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

# Calculate unique port for this SHA (50000-59999 range)
# Use SHA hash to generate deterministic port number
SHA_HASH=$(echo -n "${SHA}" | md5sum | cut -c1-8)
SHA_PORT=$((50000 + 0x${SHA_HASH:0:4} % 10000))

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Deploying SHA: ${SHA}${NC}"
echo -e "${GREEN}Port: ${SHA_PORT}${NC}"
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
export SHA_PORT="${SHA_PORT}"
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

# Deploy database and redis first (without app)
echo -e "${YELLOW}Starting database and redis...${NC}"
docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" up -d postgres redis

# Wait for database to be ready
echo -e "${YELLOW}Waiting for database to be ready...${NC}"
sleep 10

# Run database migrations using one-off container
echo -e "${YELLOW}Running database migrations...${NC}"
docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" run --rm --no-deps app npx prisma migrate deploy || {
    echo -e "${RED}✗ Migration failed${NC}"
    docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" down
    exit 1
}
echo -e "${GREEN}✓ Migrations completed successfully${NC}"

# Run database seed
echo -e "${YELLOW}Seeding database...${NC}"
docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" run --rm --no-deps app npm run db:seed || {
    echo -e "${YELLOW}⚠ Seed failed (may already be seeded)${NC}"
}
echo -e "${GREEN}✓ Database seed completed${NC}"

# Now start the app container
echo -e "${YELLOW}Starting application...${NC}"
docker compose -p "rightsteps-sha-${SHA}" -f "docker-compose.sha-${SHA}.yml" up -d app

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

# Update nginx configuration for SHA routing
echo -e "${YELLOW}Updating nginx configuration...${NC}"
NGINX_MAP_FILE="/etc/nginx/conf.d/sha-routing-map.conf"

# Create/update the map file with SHA → Port mapping
sudo bash -c "cat > ${NGINX_MAP_FILE}" <<EOF
# Auto-generated SHA preview routing map
# This file maps SHA subdomains to their respective backend ports
map \$http_host \$sha_backend_port {
    default 3000;  # Fallback to production
EOF

# Add all existing SHA deployments to the map
for container in $(docker ps --format '{{.Names}}' | grep '^backend-[a-f0-9]\{7\}$'); do
    CONTAINER_SHA=$(echo ${container} | sed 's/backend-//')
    CONTAINER_PORT=$(docker port ${container} 5000 | cut -d':' -f2)
    sudo bash -c "echo '    ${CONTAINER_SHA}.rightsteps.app ${CONTAINER_PORT};' >> ${NGINX_MAP_FILE}"
done

sudo bash -c "echo '}' >> ${NGINX_MAP_FILE}"

# Update the SHA deployments nginx config to use the map
sudo sed -i 's|proxy_pass http://localhost:3000;|proxy_pass http://localhost:$sha_backend_port;|' /etc/nginx/sites-available/sha-deployments.rightsteps.app

# Reload nginx
sudo nginx -s reload
echo -e "${GREEN}✓ Nginx configuration updated and reloaded${NC}"

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
