#!/bin/bash

# Health Check Script
# Usage: ./health-check.sh [environment]
# Example: ./health-check.sh production

set -e

# Configuration
ENVIRONMENT=${1:-production}

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Health Check - ${ENVIRONMENT}${NC}"
echo -e "${YELLOW}========================================${NC}"

# Determine port based on environment
case $ENVIRONMENT in
  production|prod)
    PORT=5000
    APP_CONTAINER="rightsteps-prod-app"
    POSTGRES_CONTAINER="rightsteps-prod-postgres"
    REDIS_CONTAINER="rightsteps-prod-redis"
    ;;
  staging)
    PORT=5001
    APP_CONTAINER="rightsteps-staging-app"
    POSTGRES_CONTAINER="rightsteps-staging-postgres"
    REDIS_CONTAINER="rightsteps-staging-redis"
    ;;
  dev|development)
    PORT=5002
    APP_CONTAINER="rightsteps-dev-app"
    POSTGRES_CONTAINER="rightsteps-dev-postgres"
    REDIS_CONTAINER="rightsteps-dev-redis"
    ;;
  *)
    echo -e "${RED}Error: Unknown environment '${ENVIRONMENT}'${NC}"
    exit 1
    ;;
esac

CHECKS_PASSED=0
CHECKS_FAILED=0

# Function to check container
check_container() {
  local container=$1
  local name=$2

  if docker ps | grep -q $container; then
    if docker ps | grep -q "healthy.*$container"; then
      echo -e "${GREEN}✓ $name is running and healthy${NC}"
      CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
      echo -e "${YELLOW}⚠ $name is running but not healthy${NC}"
      CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
  else
    echo -e "${RED}✗ $name is not running${NC}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
  fi
}

# Function to check HTTP endpoint
check_http() {
  local url=$1
  local name=$2

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $url)

  if [ "$HTTP_CODE" == "200" ]; then
    echo -e "${GREEN}✓ $name endpoint responding ($HTTP_CODE)${NC}"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
  else
    echo -e "${RED}✗ $name endpoint failed ($HTTP_CODE)${NC}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
  fi
}

# Check containers
echo "Checking containers..."
check_container $APP_CONTAINER "Application"
check_container $POSTGRES_CONTAINER "PostgreSQL"
check_container $REDIS_CONTAINER "Redis"

# Check HTTP endpoints
echo ""
echo "Checking HTTP endpoints..."
check_http "http://localhost:$PORT/v1/health" "Health"

# Check database connection
echo ""
echo "Checking database connection..."
if docker exec $POSTGRES_CONTAINER psql -U postgres -c "SELECT 1" > /dev/null 2>&1; then
  echo -e "${GREEN}✓ Database connection successful${NC}"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  echo -e "${RED}✗ Database connection failed${NC}"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check Redis connection
echo ""
echo "Checking Redis connection..."
if docker exec $REDIS_CONTAINER redis-cli ping > /dev/null 2>&1; then
  echo -e "${GREEN}✓ Redis connection successful${NC}"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  echo -e "${RED}✗ Redis connection failed${NC}"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check disk space
echo ""
echo "Checking disk space..."
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ $DISK_USAGE -lt 80 ]; then
  echo -e "${GREEN}✓ Disk usage is ${DISK_USAGE}% (OK)${NC}"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  echo -e "${YELLOW}⚠ Disk usage is ${DISK_USAGE}% (WARNING)${NC}"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check memory
echo ""
echo "Checking memory..."
MEM_USAGE=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
if [ $MEM_USAGE -lt 90 ]; then
  echo -e "${GREEN}✓ Memory usage is ${MEM_USAGE}% (OK)${NC}"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  echo -e "${YELLOW}⚠ Memory usage is ${MEM_USAGE}% (WARNING)${NC}"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Summary
echo ""
echo -e "${YELLOW}========================================${NC}"
echo "Health Check Summary:"
echo -e "${GREEN}Passed: $CHECKS_PASSED${NC}"
echo -e "${RED}Failed: $CHECKS_FAILED${NC}"

if [ $CHECKS_FAILED -eq 0 ]; then
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}All checks passed!${NC}"
  echo -e "${GREEN}========================================${NC}"
  exit 0
else
  echo -e "${RED}========================================${NC}"
  echo -e "${RED}Some checks failed!${NC}"
  echo -e "${RED}========================================${NC}"
  exit 1
fi
