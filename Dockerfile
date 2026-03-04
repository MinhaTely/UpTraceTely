FROM uptrace/uptrace:latest

# Copy custom entrypoint script
COPY uptrace-entrypoint.sh /entrypoint-custom.sh
RUN chmod +x /entrypoint-custom.sh

# Copy config template
COPY uptrace.yml.template /etc/uptrace/config.yml.template

# Install dependencies (works for both Alpine and Debian-based images)
RUN \
  if [ -f /etc/alpine-release ]; then \
    apk add --no-cache gettext wget || true; \
  else \
    apt-get update && apt-get install -y --no-install-recommends gettext-base wget && rm -rf /var/lib/apt/lists/* || true; \
  fi

# Use custom entrypoint
ENTRYPOINT ["/bin/sh", "/entrypoint-custom.sh"]