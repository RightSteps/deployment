#!/bin/bash

# Rollback Script
# Usage: ./rollback.sh [environment] [backup_file]
# Example: ./rollback.sh production
# Example: ./rollback.sh production /opt/rightsteps/backups/prod_backup_20241227_120000.sql.gz

set -e

# Configuration
ENVIRONMENT=${1:-production}
BACKUP_FILE=$2
DEPLOYMENT_DIR="/opt/rightsteps"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED}ROLLBACK - ${ENVIRONMENT}${NC}"
echo -e "${RED}========================================${NC}"

# Determine compose file and project name
case $ENVIRONMENT in
  production|prod)
    COMPOSE_FILE="docker-compose.prod.yml"
    PROJECT_NAME="rightsteps-production"
    ;;
  staging)
    COMPOSE_FILE="docker-compose.staging.yml"
    PROJECT_NAME="rightsteps-staging"
    ;;
  dev|development)
    COMPOSE_FILE="docker-compose.dev.yml"
    PROJECT_NAME="rightsteps-dev"
    ;;
  *)
    echo -e "${RED}Error: Unknown environment '${ENVIRONMENT}'${NC}"
    exit 1
    ;;
esac

cd $DEPLOYMENT_DIR

# Step 1: Find latest backup if not specified
if [ -z "$BACKUP_FILE" ]; then
  echo -e "${YELLOW}Finding latest backup...${NC}"
  BACKUP_FILE=$(ls -t ${DEPLOYMENT_DIR}/backups/${ENVIRONMENT}_backup_*.sql.gz 2>/dev/null | head -1)

  if [ -z "$BACKUP_FILE" ]; then
    echo -e "${RED}No backup found! Cannot rollback.${NC}"
    exit 1
  fi

  echo "Using backup: $BACKUP_FILE"
fi

# Step 2: Stop current container
echo -e "${YELLOW}[1/4] Stopping current container...${NC}"
docker compose -p $PROJECT_NAME -f $COMPOSE_FILE stop app
docker compose -p $PROJECT_NAME -f $COMPOSE_FILE rm -f app

# Step 3: Restore database
echo -e "${YELLOW}[2/4] Restoring database from backup...${NC}"
echo "Backup file: $BACKUP_FILE"

# Get database credentials
case $ENVIRONMENT in
  production|prod)
    POSTGRES_CONTAINER="rightsteps-prod-postgres"
    ;;
  staging)
    POSTGRES_CONTAINER="rightsteps-staging-postgres"
    ;;
  dev|development)
    POSTGRES_CONTAINER="rightsteps-dev-postgres"
    ;;
esac

DB_NAME=$(docker exec $POSTGRES_CONTAINER printenv POSTGRES_DB)
DB_USER=$(docker exec $POSTGRES_CONTAINER printenv POSTGRES_USER)

# Decompress and restore
RESTORE_FILE="/tmp/rollback_restore_$(date +%s).sql"
gunzip -c $BACKUP_FILE > $RESTORE_FILE

docker exec $POSTGRES_CONTAINER psql -U $DB_USER -c "DROP DATABASE IF EXISTS ${DB_NAME};"
docker exec $POSTGRES_CONTAINER psql -U $DB_USER -c "CREATE DATABASE ${DB_NAME};"
cat $RESTORE_FILE | docker exec -i $POSTGRES_CONTAINER psql -U $DB_USER -d $DB_NAME

rm -f $RESTORE_FILE

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Database restored${NC}"
else
  echo -e "${RED}✗ Database restore failed${NC}"
  exit 1
fi

# Step 4: Start previous version
echo -e "${YELLOW}[3/4] Starting previous version...${NC}"

# Try to use previous image tag
PREVIOUS_TAG=$(docker images --format "{{.Tag}}" | grep -v "latest" | sort -r | head -2 | tail -1)
if [ -z "$PREVIOUS_TAG" ]; then
  PREVIOUS_TAG="latest"
fi

export IMAGE_TAG=$PREVIOUS_TAG
docker compose -p $PROJECT_NAME -f $COMPOSE_FILE up -d app

# Step 5: Verify rollback
echo -e "${YELLOW}[4/4] Verifying rollback...${NC}"
sleep 10

MAX_ATTEMPTS=15
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  if docker ps | grep -q "healthy.*rightsteps-${ENVIRONMENT}-app"; then
    echo -e "${GREEN}✓ Rollback successful!${NC}"
    break
  fi

  ATTEMPT=$((ATTEMPT + 1))
  echo "Waiting... ($ATTEMPT/$MAX_ATTEMPTS)"
  sleep 2
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
  echo -e "${RED}Rollback verification failed!${NC}"
  exit 1
fi

# Log rollback
echo "$(date): Rolled back ${ENVIRONMENT} to backup ${BACKUP_FILE}" >> ${DEPLOYMENT_DIR}/logs/rollback.log

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Rollback completed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Environment: $ENVIRONMENT"
echo "Backup used: $BACKUP_FILE"
echo "Image tag: $PREVIOUS_TAG"
echo -e "${GREEN}========================================${NC}"

exit 0
