#!/bin/sh
# Don't use set -e here because we want to continue even if user creation fails

# SECURITY: Substitute environment variables in uptrace.yml.template
# This ensures sensitive values are never hardcoded in the repository
echo "🔧 Generating uptrace.yml from template with environment variables..."

# Check if template exists
if [ ! -f /etc/uptrace/config.yml.template ]; then
  echo "❌ Error: Template file not found at /etc/uptrace/config.yml.template"
  exit 1
fi

# Export all variables that might be used in the template
# SECURITY: All sensitive values must be provided via environment variables
export UPTRACE_SECRET
export UPTRACE_SITE_URL
export UPTRACE_PG_ADDR
export UPTRACE_PG_USER
export UPTRACE_PG_PASSWORD
export UPTRACE_PG_DATABASE
export UPTRACE_CH_ADDR
export UPTRACE_CH_USER
export UPTRACE_CH_PASSWORD
export UPTRACE_CH_DATABASE
export REDIS_ADDR
export REDIS_PASSWORD

# Validate required variables (these are critical, so exit on failure)
if [ -z "$UPTRACE_SECRET" ]; then
  echo "❌ Error: UPTRACE_SECRET environment variable is required"
  exit 1
fi

if [ -z "$UPTRACE_PG_PASSWORD" ]; then
  echo "❌ Error: UPTRACE_PG_PASSWORD environment variable is required"
  exit 1
fi

# FIXED: Check UPTRACE_CH_PASSWORD (the actual env var name in container)
if [ -z "$UPTRACE_CH_PASSWORD" ]; then
  echo "❌ Error: UPTRACE_CH_PASSWORD environment variable is required (set via UPTRACE_CLICKHOUSE_PASSWORD in .env)"
  exit 1
fi

# Generate config.yml from template using envsubst
envsubst < /etc/uptrace/config.yml.template > /etc/uptrace/config.yml

echo "✅ Configuration generated successfully"

# Execute the original Uptrace entrypoint in background
/entrypoint.sh "$@" &
UPTRACE_PID=$!

# Wait for Uptrace to be ready (check health endpoint)
echo "⏳ Waiting for Uptrace to be ready..."
MAX_RETRIES=60
RETRY_COUNT=0
UPTRACE_READY=0

# Function to check if Uptrace is responding
check_uptrace_health() {
  # Check if process is still running
  if ! kill -0 $UPTRACE_PID 2>/dev/null; then
    return 1
  fi
  
  # Check if port 443 is listening (Uptrace is serving)
  if command -v nc >/dev/null 2>&1; then
    if nc -z localhost 443 2>/dev/null; then
      return 0
    fi
  fi
  
  # Try root endpoint (most reliable)
  if wget --no-verbose --tries=1 --spider --timeout=3 http://localhost:443/ 2>/dev/null; then
    return 0
  fi
  
  # Try API health endpoint
  if wget --no-verbose --tries=1 --spider --timeout=3 http://localhost:443/api/health 2>/dev/null; then
    return 0
  fi
  
  # Try using curl as fallback
  if command -v curl >/dev/null 2>&1; then
    if curl -f -s --max-time 3 http://localhost:443/ >/dev/null 2>&1; then
      return 0
    fi
  fi
  
  return 1
}

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if check_uptrace_health; then
    echo "✅ Uptrace is ready"
    UPTRACE_READY=1
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $((RETRY_COUNT % 5)) -eq 0 ]; then
    echo "  Attempt $RETRY_COUNT/$MAX_RETRIES... (process still running)"
  fi
  sleep 2
done

if [ $UPTRACE_READY -eq 0 ]; then
  echo "⚠️  Warning: Uptrace health check did not pass after $MAX_RETRIES attempts, but continuing anyway..."
  echo "   The service may still be starting up. User creation will be retried."
fi

# Create admin user if environment variables are provided
# This is non-critical, so we continue even if it fails
if [ -n "$UPTRACE_ADMIN_EMAIL" ] && [ -n "$UPTRACE_ADMIN_PASSWORD" ]; then
  echo "👤 Checking if admin user exists..."
  
  # Wait a bit more for Uptrace API to be fully ready
  sleep 3
  
  # Try to check if user exists (with retries in case API isn't ready)
  USER_EXISTS=0
  for i in 1 2 3; do
    if /uptrace users list 2>/dev/null | grep -q "$UPTRACE_ADMIN_EMAIL"; then
      echo "✅ Admin user already exists: $UPTRACE_ADMIN_EMAIL"
      USER_EXISTS=1
      break
    fi
    sleep 2
  done
  
  # Create user if it doesn't exist
  if [ $USER_EXISTS -eq 0 ]; then
    echo "🔨 Creating admin user: $UPTRACE_ADMIN_EMAIL"
    # Try creating user with retries
    for i in 1 2 3; do
      if /uptrace users create --email "$UPTRACE_ADMIN_EMAIL" --password "$UPTRACE_ADMIN_PASSWORD" 2>/dev/null; then
        echo "✅ Admin user created successfully"
        break
      else
        if [ $i -lt 3 ]; then
          echo "  Retry $i/3..."
          sleep 3
        else
          echo "⚠️  Warning: Failed to create admin user after retries (may already exist or service not fully ready)"
        fi
      fi
    done
  fi
else
  echo "ℹ️  Skipping admin user creation (UPTRACE_ADMIN_EMAIL and UPTRACE_ADMIN_PASSWORD not set)"
fi

# Wait for the Uptrace process
wait $UPTRACE_PID