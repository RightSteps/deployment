#!/bin/bash

# Database Restore Script
# Usage: ./restore-db.sh [environment] [backup_file]
# Example: ./restore-db.sh production /opt/rightsteps/backups/prod_backup_20241227_120000.sql.gz

set -e

# Configuration
ENVIRONMENT=${1:-production}
BACKUP_FILE=$2

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Database Restore - ${ENVIRONMENT}${NC}"
echo -e "${GREEN}========================================${NC}"

# Check if backup file provided
if [ -z "$BACKUP_FILE" ]; then
  echo -e "${RED}Error: Backup file not specified${NC}"
  echo "Usage: ./restore-db.sh [environment] [backup_file]"
  echo ""
  echo "Available backups:"
  ls -lht /opt/rightsteps/backups/${ENVIRONMENT}_backup_*.sql.gz 2>/dev/null || echo "No backups found"
  exit 1
fi

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
  echo -e "${RED}Error: Backup file '${BACKUP_FILE}' not found${NC}"
  exit 1
fi

# Determine container names
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
  *)
    echo -e "${RED}Error: Unknown environment '${ENVIRONMENT}'${NC}"
    exit 1
    ;;
esac

# Check if container is running
if ! docker ps | grep -q $POSTGRES_CONTAINER; then
  echo -e "${RED}Error: PostgreSQL container '${POSTGRES_CONTAINER}' is not running${NC}"
  exit 1
fi

# Get database credentials
DB_NAME=$(docker exec $POSTGRES_CONTAINER printenv POSTGRES_DB)
DB_USER=$(docker exec $POSTGRES_CONTAINER printenv POSTGRES_USER)

echo -e "${YELLOW}Restore Details:${NC}"
echo "Container: $POSTGRES_CONTAINER"
echo "Database: $DB_NAME"
echo "Backup file: $BACKUP_FILE"
echo ""

# Confirmation prompt
echo -e "${RED}WARNING: This will OVERWRITE the current database!${NC}"
read -p "Are you sure you want to continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
  echo "Restore cancelled."
  exit 0
fi

# Create a safety backup before restore
echo -e "${YELLOW}Creating safety backup before restore...${NC}"
SAFETY_BACKUP="/opt/rightsteps/backups/${ENVIRONMENT}_pre_restore_$(date +%Y%m%d_%H%M%S).sql"
docker exec $POSTGRES_CONTAINER pg_dump -U $DB_USER $DB_NAME > $SAFETY_BACKUP
gzip $SAFETY_BACKUP
echo -e "${GREEN}✓ Safety backup created: ${SAFETY_BACKUP}.gz${NC}"

# Decompress if needed
RESTORE_FILE=$BACKUP_FILE
if [[ $BACKUP_FILE == *.gz ]]; then
  echo -e "${YELLOW}Decompressing backup file...${NC}"
  RESTORE_FILE="/tmp/restore_$(basename $BACKUP_FILE .gz)"
  gunzip -c $BACKUP_FILE > $RESTORE_FILE
fi

# Drop and recreate database
echo -e "${YELLOW}Dropping and recreating database...${NC}"
docker exec $POSTGRES_CONTAINER psql -U $DB_USER -c "DROP DATABASE IF EXISTS ${DB_NAME};"
docker exec $POSTGRES_CONTAINER psql -U $DB_USER -c "CREATE DATABASE ${DB_NAME};"

# Restore database
echo -e "${YELLOW}Restoring database...${NC}"
cat $RESTORE_FILE | docker exec -i $POSTGRES_CONTAINER psql -U $DB_USER -d $DB_NAME

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Database restored successfully!${NC}"

  # Cleanup temp file if created
  if [[ $BACKUP_FILE == *.gz ]]; then
    rm -f $RESTORE_FILE
  fi

  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}Restore completed successfully!${NC}"
  echo -e "${GREEN}Safety backup: ${SAFETY_BACKUP}.gz${NC}"
  echo -e "${GREEN}========================================${NC}"
else
  echo -e "${RED}✗ Restore failed!${NC}"
  echo -e "${YELLOW}Safety backup available at: ${SAFETY_BACKUP}.gz${NC}"
  exit 1
fi

exit 0
