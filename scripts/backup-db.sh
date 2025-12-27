#!/bin/bash

# Database Backup Script
# Usage: ./backup-db.sh [environment]
# Example: ./backup-db.sh production

set -e

# Configuration
ENVIRONMENT=${1:-production}
BACKUP_DIR="/opt/rightsteps/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RETENTION_DAYS=7

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Database Backup - ${ENVIRONMENT}${NC}"
echo -e "${GREEN}========================================${NC}"

# Determine container names based on environment
case $ENVIRONMENT in
  production|prod)
    POSTGRES_CONTAINER="rightsteps-prod-postgres"
    BACKUP_FILE="${BACKUP_DIR}/prod_backup_${TIMESTAMP}.sql"
    ;;
  staging)
    POSTGRES_CONTAINER="rightsteps-staging-postgres"
    BACKUP_FILE="${BACKUP_DIR}/staging_backup_${TIMESTAMP}.sql"
    ;;
  dev|development)
    POSTGRES_CONTAINER="rightsteps-dev-postgres"
    BACKUP_FILE="${BACKUP_DIR}/dev_backup_${TIMESTAMP}.sql"
    ;;
  *)
    echo -e "${RED}Error: Unknown environment '${ENVIRONMENT}'${NC}"
    echo "Usage: ./backup-db.sh [production|staging|dev]"
    exit 1
    ;;
esac

# Check if container is running
if ! docker ps | grep -q $POSTGRES_CONTAINER; then
  echo -e "${RED}Error: PostgreSQL container '${POSTGRES_CONTAINER}' is not running${NC}"
  exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p $BACKUP_DIR

# Get database credentials from container
DB_NAME=$(docker exec $POSTGRES_CONTAINER printenv POSTGRES_DB)
DB_USER=$(docker exec $POSTGRES_CONTAINER printenv POSTGRES_USER)

echo -e "${YELLOW}Starting backup...${NC}"
echo "Container: $POSTGRES_CONTAINER"
echo "Database: $DB_NAME"
echo "Backup file: $BACKUP_FILE"

# Create backup
docker exec $POSTGRES_CONTAINER pg_dump -U $DB_USER $DB_NAME > $BACKUP_FILE

# Check if backup was successful
if [ $? -eq 0 ]; then
  # Compress the backup
  gzip $BACKUP_FILE
  BACKUP_FILE="${BACKUP_FILE}.gz"

  # Get file size
  FILE_SIZE=$(du -h $BACKUP_FILE | cut -f1)

  echo -e "${GREEN}✓ Backup successful!${NC}"
  echo "File: $BACKUP_FILE"
  echo "Size: $FILE_SIZE"

  # Create latest symlink
  LATEST_LINK="${BACKUP_DIR}/${ENVIRONMENT}_latest.sql.gz"
  ln -sf $BACKUP_FILE $LATEST_LINK
  echo "Latest backup linked to: $LATEST_LINK"
else
  echo -e "${RED}✗ Backup failed!${NC}"
  exit 1
fi

# Cleanup old backups (keep last 7 days)
echo -e "${YELLOW}Cleaning up old backups (keeping last ${RETENTION_DAYS} days)...${NC}"
find $BACKUP_DIR -name "${ENVIRONMENT}_backup_*.sql.gz" -type f -mtime +$RETENTION_DAYS -delete
DELETED_COUNT=$(find $BACKUP_DIR -name "${ENVIRONMENT}_backup_*.sql.gz" -type f -mtime +$RETENTION_DAYS | wc -l)
echo "Deleted $DELETED_COUNT old backup(s)"

# List recent backups
echo -e "${GREEN}Recent backups:${NC}"
ls -lht $BACKUP_DIR/${ENVIRONMENT}_backup_*.sql.gz | head -5

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Backup completed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"

exit 0
