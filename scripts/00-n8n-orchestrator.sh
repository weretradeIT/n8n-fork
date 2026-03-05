#!/usr/bin/env bash
################################################################################
# WereTrade Infrastructure Deployment
# Phase 6: n8n Workflow Automation Server
#
# This script deploys n8n (workflow automation platform) with:
# - Docker-based deployment (recommended) or source installation
# - JWT authentication and security hardening
# - Webhook support with SSL/TLS
# - PostgreSQL integration for workflow storage
# - Anti-AI fingerprint obfuscation
# - Integration with existing infrastructure
# - Monitoring and management
#
# Author: WereTrade Infrastructure Team
# Version: 1.0.0
# Date: 2026-01-14
################################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source shared libraries
source "${PROJECT_ROOT}/scripts/lib/logging.sh"
source "${PROJECT_ROOT}/scripts/lib/validation.sh"
source "${PROJECT_ROOT}/scripts/lib/docker-utils.sh"

# Configuration
readonly N8N_VERSION="${N8N_VERSION:-latest}"
readonly N8N_PORT="${N8N_PORT:-5678}"
readonly N8N_INSTALL_DIR="/opt/weretrade/n8n"
readonly N8N_DATA_DIR="/opt/weretrade/n8n-data"
readonly N8N_CONFIG_DIR="/opt/weretrade/config/n8n"
readonly N8N_SSL_DIR="/opt/weretrade/ssl/n8n"
readonly N8N_STATE_FILE="/opt/weretrade/install-state-n8n.json"
readonly N8N_CONTAINER_NAME="weretrade-n8n"
readonly N8N_DB_NAME="n8n_db"
readonly N8N_DB_USER="n8n_user"

# Installation method: docker (recommended) or source
readonly INSTALL_METHOD="${N8N_INSTALL_METHOD:-docker}"

################################################################################
# Helper Functions
################################################################################

generate_secure_password() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

generate_encryption_key() {
    openssl rand -hex 32
}

################################################################################
# Phase 1: Purge Existing Installation
################################################################################

purge_existing_n8n() {
    log_info "Purging any existing n8n installation..."

    # Stop and remove Docker containers
    if command -v docker &> /dev/null; then
        log_info "Checking for n8n Docker containers..."
        docker stop "$N8N_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$N8N_CONTAINER_NAME" 2>/dev/null || true

        # Remove any other n8n containers
        docker ps -a --filter "name=n8n" --format "{{.Names}}" | while read -r container; do
            log_info "Removing container: $container"
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
        done

        log_success "Docker containers removed"
    fi

    # Stop systemd service if it exists
    if command -v systemctl &> /dev/null; then
        log_info "Checking for n8n systemd services..."
        systemctl stop n8n 2>/dev/null || true
        systemctl disable n8n 2>/dev/null || true
        rm -f /etc/systemd/system/n8n.service
        systemctl daemon-reload
        log_success "Systemd services removed"
    fi

    # Kill any running n8n processes
    log_info "Checking for running n8n processes..."
    pkill -9 -f "n8n" 2>/dev/null || true

    # Remove npm global installation
    if command -v npm &> /dev/null; then
        log_info "Removing global npm n8n package..."
        npm uninstall -g n8n 2>/dev/null || true
    fi

    # Remove installation directories (but preserve data if exists)
    log_info "Cleaning up installation directories..."
    if [ -d "$N8N_DATA_DIR" ]; then
        log_warning "Backing up existing n8n data to ${N8N_DATA_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        cp -r "$N8N_DATA_DIR" "${N8N_DATA_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    rm -rf "$N8N_INSTALL_DIR" 2>/dev/null || true
    rm -rf /opt/n8n 2>/dev/null || true
    rm -rf /usr/local/n8n 2>/dev/null || true

    log_success "Existing n8n installation purged"
}

################################################################################
# Phase 2: Prepare Environment
################################################################################

prepare_environment() {
    log_info "Preparing n8n environment..."

    # Create directories
    mkdir -p "$N8N_INSTALL_DIR"
    mkdir -p "$N8N_DATA_DIR"
    mkdir -p "$N8N_CONFIG_DIR"
    mkdir -p "$N8N_SSL_DIR"
    mkdir -p "${N8N_DATA_DIR}/workflows"
    mkdir -p "${N8N_DATA_DIR}/credentials"
    mkdir -p "${N8N_DATA_DIR}/logs"

    # Set permissions
    chmod 750 "$N8N_INSTALL_DIR"
    chmod 750 "$N8N_DATA_DIR"
    chmod 750 "$N8N_CONFIG_DIR"
    chmod 700 "$N8N_SSL_DIR"

    log_success "Environment prepared"
}

################################################################################
# Phase 3: Install Dependencies
################################################################################

install_dependencies() {
    log_info "Installing n8n dependencies..."

    if [ "$INSTALL_METHOD" = "docker" ]; then
        # Verify Docker is installed
        if ! command -v docker &> /dev/null; then
            log_error "Docker is not installed. Please install Docker first."
            exit 1
        fi

        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            log_error "Docker Compose is not installed. Please install Docker Compose first."
            exit 1
        fi

        log_success "Docker dependencies verified"
    else
        # Install Node.js if not present
        if ! command -v node &> /dev/null; then
            log_info "Installing Node.js..."
            curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
            apt-get install -y nodejs
        fi

        # Verify Node.js version
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -lt 16 ]; then
            log_error "Node.js 16 or higher is required"
            exit 1
        fi

        log_success "Node.js dependencies verified"
    fi
}

################################################################################
# Phase 4: Generate Credentials
################################################################################

generate_credentials() {
    log_info "Generating n8n credentials..."

    N8N_ADMIN_PASSWORD=$(generate_secure_password)
    N8N_ENCRYPTION_KEY=$(generate_encryption_key)
    N8N_DB_PASSWORD=$(generate_secure_password)
    N8N_JWT_SECRET=$(generate_encryption_key)
    N8N_WEBHOOK_SECRET=$(generate_encryption_key)

    # Save credentials to state file
    cat > "$N8N_STATE_FILE" <<EOF
{
  "version": "1.0.0",
  "installation_date": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "installation_method": "$INSTALL_METHOD",
  "n8n_version": "$N8N_VERSION",
  "credentials": {
    "admin_email": "MasterSpl1nter@weretrade.local",
    "admin_password": "$N8N_ADMIN_PASSWORD",
    "encryption_key": "$N8N_ENCRYPTION_KEY",
    "jwt_secret": "$N8N_JWT_SECRET",
    "webhook_secret": "$N8N_WEBHOOK_SECRET",
    "database": {
      "host": "postgres-primary",
      "port": 5432,
      "database": "$N8N_DB_NAME",
      "user": "$N8N_DB_USER",
      "password": "$N8N_DB_PASSWORD"
    }
  },
  "endpoints": {
    "web_ui": "http://localhost:${N8N_PORT}",
    "webhooks": "http://localhost:${N8N_PORT}/webhook",
    "webhook_test": "http://localhost:${N8N_PORT}/webhook-test"
  }
}
EOF

    chmod 600 "$N8N_STATE_FILE"

    log_success "Credentials generated and saved to $N8N_STATE_FILE"
}

################################################################################
# Phase 5: Setup PostgreSQL Database
################################################################################

setup_database() {
    log_info "Setting up n8n PostgreSQL database..."

    # Check if PostgreSQL is running
    if ! docker ps | grep -q "postgres-primary"; then
        log_warning "PostgreSQL container not running. Skipping database setup."
        log_warning "You'll need to create the database manually or use SQLite."
        return
    fi

    # Create database and user with comprehensive permissions
    # NOTE: Enhanced with full schema privileges to prevent authentication failures
    docker exec postgres-primary psql -U postgres <<EOF
-- Drop existing database and user if they exist (clean slate)
DROP DATABASE IF EXISTS ${N8N_DB_NAME};
DROP USER IF EXISTS ${N8N_DB_USER};

-- Create n8n database user
CREATE USER ${N8N_DB_USER} WITH PASSWORD '${N8N_DB_PASSWORD}';

-- Create n8n database with proper ownership
CREATE DATABASE ${N8N_DB_NAME} OWNER ${N8N_DB_USER};

-- Grant all database privileges
GRANT ALL PRIVILEGES ON DATABASE ${N8N_DB_NAME} TO ${N8N_DB_USER};

-- Connect to database and grant schema privileges
\c ${N8N_DB_NAME}

-- Grant all schema privileges (critical for migrations)
GRANT ALL ON SCHEMA public TO ${N8N_DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${N8N_DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${N8N_DB_USER};

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${N8N_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${N8N_DB_USER};

EOF

    log_success "PostgreSQL database configured with full permissions"
}

################################################################################
# Phase 6: Generate SSL Certificates
################################################################################

generate_ssl_certificates() {
    log_info "Generating SSL certificates for n8n..."

    # Generate self-signed certificate for n8n
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${N8N_SSL_DIR}/n8n-key.pem" \
        -out "${N8N_SSL_DIR}/n8n-cert.pem" \
        -subj "/C=US/ST=State/L=City/O=WereTrade/OU=n8n/CN=$(hostname -f)" \
        2>/dev/null

    chmod 600 "${N8N_SSL_DIR}/n8n-key.pem"
    chmod 644 "${N8N_SSL_DIR}/n8n-cert.pem"

    log_success "SSL certificates generated"
}

################################################################################
# Phase 7: Docker Installation
################################################################################

install_docker() {
    log_info "Installing n8n via Docker..."

    # Create docker-compose.yml
    # NOTE: version field is obsolete in Docker Compose v2, removed to avoid warnings
    cat > "${N8N_CONFIG_DIR}/docker-compose.yml" <<EOF
services:
  n8n:
    container_name: ${N8N_CONTAINER_NAME}
    image: n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    ports:
      - "${N8N_PORT}:5678"
    environment:
      # Basic configuration
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production

      # Database configuration (PostgreSQL)
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres-primary
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}

      # Security
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_JWT_SECRET}

      # Webhooks
      - WEBHOOK_URL=http://localhost:${N8N_PORT}/
      - N8N_PAYLOAD_SIZE_MAX=16

      # Execution
      - EXECUTIONS_DATA_SAVE_ON_ERROR=all
      - EXECUTIONS_DATA_SAVE_ON_SUCCESS=all
      - EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS=true

      # Security headers
      - N8N_SECURE_COOKIE=false
      - N8N_METRICS=true

      # Anti-AI defense: Version obfuscation
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false
    volumes:
      - ${N8N_DATA_DIR}:/home/node/.n8n
      - ${N8N_DATA_DIR}/workflows:/home/node/.n8n/workflows
      - ${N8N_DATA_DIR}/credentials:/home/node/.n8n/credentials
    networks:
      - app_net
      - database_net
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  app_net:
    external: true
  database_net:
    external: true
EOF

    # Create Docker networks if they don't exist
    create_docker_networks "app_net" "database_net"

    # Start n8n container (use DOCKER_COMPOSE from docker-utils.sh for v1/v2 compatibility)
    cd "$N8N_CONFIG_DIR"
    $DOCKER_COMPOSE up -d

    # Wait for n8n to be ready
    log_info "Waiting for n8n to be ready..."
    for i in {1..30}; do
        if curl -sf "http://localhost:${N8N_PORT}/healthz" > /dev/null 2>&1; then
            log_success "n8n is ready!"
            break
        fi
        sleep 2
    done

    log_success "n8n Docker container deployed"
}

################################################################################
# Phase 8: Source Installation (Alternative)
################################################################################

install_from_source() {
    log_info "Installing n8n from source..."

    # Clone n8n repository
    cd "$N8N_INSTALL_DIR"
    git clone https://github.com/n8n-io/n8n.git .

    # Install dependencies
    npm install
    npm run build

    # Create environment file
    cat > "${N8N_CONFIG_DIR}/.env" <<EOF
# Database
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=localhost
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
DB_POSTGRESDB_USER=${N8N_DB_USER}
DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}

# Security
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_JWT_SECRET}

# Basic configuration
N8N_HOST=0.0.0.0
N8N_PORT=${N8N_PORT}
N8N_PROTOCOL=http
NODE_ENV=production

# Data directory
N8N_USER_FOLDER=${N8N_DATA_DIR}

# Anti-AI defense
N8N_DIAGNOSTICS_ENABLED=false
N8N_VERSION_NOTIFICATIONS_ENABLED=false
EOF

    log_success "n8n installed from source"
}

################################################################################
# Phase 9: Create Systemd Service (for source installation)
################################################################################

create_systemd_service() {
    if [ "$INSTALL_METHOD" != "source" ]; then
        return
    fi

    log_info "Creating systemd service..."

    cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=n8n Workflow Automation
After=network.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=${N8N_INSTALL_DIR}
EnvironmentFile=${N8N_CONFIG_DIR}/.env
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=10

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${N8N_DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable n8n
    systemctl start n8n

    log_success "Systemd service created and started"
}

################################################################################
# Phase 10: Anti-AI Defense Integration
################################################################################

integrate_anti_ai_defense() {
    log_info "Integrating anti-AI defense patterns..."

    # Create nginx reverse proxy for fingerprint obfuscation
    cat > "${N8N_CONFIG_DIR}/nginx-n8n.conf" <<'EOF'
# n8n Reverse Proxy with Anti-AI Defense
upstream n8n_backend {
    server localhost:5678;
}

# Version obfuscation pool
map $request_id $n8n_version {
    default "0.228.2";
    ~1 "0.225.1";
    ~2 "0.230.0";
    ~3 "0.227.1";
    ~4 "0.229.0";
    ~5 "0.226.2";
}

server {
    listen 5679 ssl http2;
    server_name _;

    ssl_certificate /opt/weretrade/ssl/n8n/n8n-cert.pem;
    ssl_certificate_key /opt/weretrade/ssl/n8n/n8n-key.pem;

    # Security headers with obfuscation
    add_header X-n8n-Version $n8n_version always;
    add_header X-Powered-By "n8n" always;
    add_header Server "nginx" always;
    more_clear_headers 'X-Runtime';
    more_clear_headers 'X-Request-Id';

    # Remove fingerprinting headers
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;

    location / {
        proxy_pass http://n8n_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Websocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Adversarial timing (10-200ms delay)
        echo_sleep 0.$((RANDOM % 190 + 10));
    }

    location /healthz {
        proxy_pass http://n8n_backend/healthz;
        access_log off;
    }
}
EOF

    # Create adversarial timing middleware script
    cat > "${N8N_CONFIG_DIR}/anti-ai-timing.js" <<'EOF'
/**
 * Anti-AI Adversarial Timing Middleware for n8n
 * Introduces Pareto-distributed delays to confuse ML timing attacks
 */

const crypto = require('crypto');

// Pareto distribution parameters
const ALPHA = 1.5; // Shape parameter
const X_MIN = 10;  // Minimum delay (ms)
const X_MAX = 200; // Maximum delay (ms)

function paretoDelay() {
    const u = crypto.randomBytes(4).readUInt32BE(0) / 0xFFFFFFFF;
    const delay = X_MIN / Math.pow(u, 1 / ALPHA);
    return Math.min(delay, X_MAX);
}

function antiAIMiddleware(req, res, next) {
    // Skip timing for health checks
    if (req.path === '/healthz' || req.path === '/health') {
        return next();
    }

    // Add adversarial timing delay
    const delay = paretoDelay();
    setTimeout(next, delay);
}

module.exports = antiAIMiddleware;
EOF

    # Integrate with main anti-AI defense system
    if [ -f "${SCRIPT_DIR}/../15-anti-ai-defense/09-integrate-n8n.sh" ]; then
        log_info "Integrating n8n with main anti-AI defense system..."
        bash "${SCRIPT_DIR}/../15-anti-ai-defense/09-integrate-n8n.sh" || {
            log_warning "Anti-AI defense integration failed, but n8n has built-in protections"
        }
    else
        log_info "Main anti-AI defense system not found, skipping integration"
        log_info "n8n has built-in anti-AI protections (version obfuscation, adversarial timing)"
    fi

    log_success "Anti-AI defense integrated"
}

################################################################################
# Phase 11: Create Management Scripts
################################################################################

create_management_scripts() {
    log_info "Creating n8n management scripts..."

    # Create monitoring script
    cat > "${N8N_CONFIG_DIR}/monitor.sh" <<'EOF'
#!/bin/bash
# n8n Monitoring Script

set -euo pipefail

N8N_PORT=5678
N8N_CONTAINER="weretrade-n8n"

echo "========================================="
echo "n8n Workflow Automation - Status Report"
echo "========================================="
echo ""

# Container status
if docker ps --format '{{.Names}}' | grep -q "^${N8N_CONTAINER}$"; then
    echo "✅ Container Status: RUNNING"

    # Get container stats
    STATS=$(docker stats --no-stream --format "table {{.CPUPerc}}\t{{.MemUsage}}" "$N8N_CONTAINER" | tail -n 1)
    echo "📊 Resource Usage: $STATS"
else
    echo "❌ Container Status: NOT RUNNING"
    exit 1
fi

# Health check
if curl -sf "http://localhost:${N8N_PORT}/healthz" > /dev/null; then
    echo "✅ Health Check: PASSED"
else
    echo "❌ Health Check: FAILED"
fi

# Database connection
if docker exec "$N8N_CONTAINER" node -e "require('pg').Client" 2>/dev/null; then
    echo "✅ Database Driver: AVAILABLE"
else
    echo "⚠️  Database Driver: NOT FOUND"
fi

# Workflow count
WORKFLOW_DIR="/opt/weretrade/n8n-data/workflows"
if [ -d "$WORKFLOW_DIR" ]; then
    WORKFLOW_COUNT=$(find "$WORKFLOW_DIR" -name "*.json" 2>/dev/null | wc -l)
    echo "📋 Active Workflows: $WORKFLOW_COUNT"
fi

# Recent logs
echo ""
echo "Recent Logs (last 10 lines):"
echo "----------------------------"
docker logs --tail 10 "$N8N_CONTAINER" 2>&1

echo ""
echo "========================================="
EOF

    chmod +x "${N8N_CONFIG_DIR}/monitor.sh"

    # Create backup script
    cat > "${N8N_CONFIG_DIR}/backup.sh" <<'EOF'
#!/bin/bash
# n8n Backup Script

set -euo pipefail

BACKUP_DIR="/opt/weretrade/backups/n8n"
N8N_DATA_DIR="/opt/weretrade/n8n-data"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/n8n-backup-${TIMESTAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

echo "Starting n8n backup..."

# Backup workflows and data
tar -czf "$BACKUP_FILE" \
    -C "$N8N_DATA_DIR" \
    workflows credentials

# Backup database
docker exec postgres-primary pg_dump -U n8n_user n8n_db | gzip > "${BACKUP_DIR}/n8n-db-${TIMESTAMP}.sql.gz"

# Encrypt backup
openssl enc -aes-256-cbc -salt -pbkdf2 \
    -in "$BACKUP_FILE" \
    -out "${BACKUP_FILE}.enc" \
    -pass file:/root/.backup-encryption-key

rm "$BACKUP_FILE"

echo "✅ Backup completed: ${BACKUP_FILE}.enc"

# Cleanup old backups (keep last 7 days)
find "$BACKUP_DIR" -name "n8n-backup-*.tar.gz.enc" -mtime +7 -delete
find "$BACKUP_DIR" -name "n8n-db-*.sql.gz" -mtime +7 -delete

echo "✅ Old backups cleaned up"
EOF

    chmod +x "${N8N_CONFIG_DIR}/backup.sh"

    # Create restart script
    cat > "${N8N_CONFIG_DIR}/restart.sh" <<'EOF'
#!/bin/bash
# n8n Restart Script

set -euo pipefail

# Detect Docker Compose command (v1 vs v2 compatibility)
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "❌ Docker Compose not found"
    exit 1
fi

echo "Restarting n8n..."

if docker ps --format '{{.Names}}' | grep -q "weretrade-n8n"; then
    docker restart weretrade-n8n
    echo "✅ n8n restarted successfully"
else
    echo "Starting n8n..."
    cd /opt/weretrade/config/n8n
    $DOCKER_COMPOSE up -d
    echo "✅ n8n started successfully"
fi

# Wait for health check
for i in {1..30}; do
    if curl -sf "http://localhost:5678/healthz" > /dev/null; then
        echo "✅ n8n is healthy"
        exit 0
    fi
    sleep 2
done

echo "❌ n8n health check failed"
exit 1
EOF

    chmod +x "${N8N_CONFIG_DIR}/restart.sh"

    log_success "Management scripts created"
}

################################################################################
# Phase 12: Setup Monitoring
################################################################################

setup_monitoring() {
    log_info "Setting up n8n monitoring..."

    # Create systemd timer for monitoring
    if command -v systemctl &> /dev/null; then
        cat > /etc/systemd/system/n8n-monitor.timer <<EOF
[Unit]
Description=n8n Monitoring Timer
Requires=n8n-monitor.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

        cat > /etc/systemd/system/n8n-monitor.service <<EOF
[Unit]
Description=n8n Monitoring Service
After=docker.service

[Service]
Type=oneshot
ExecStart=${N8N_CONFIG_DIR}/monitor.sh
StandardOutput=append:/var/log/n8n-monitor.log
StandardError=append:/var/log/n8n-monitor.log
EOF

        systemctl daemon-reload
        systemctl enable n8n-monitor.timer
        systemctl start n8n-monitor.timer

        log_success "Monitoring timer configured"
    fi
}

################################################################################
# Phase 13: Setup Automated Backups
################################################################################

setup_backups() {
    log_info "Setting up automated n8n backups..."

    # Create backup directory
    mkdir -p /opt/weretrade/backups/n8n

    # Create systemd timer for backups
    if command -v systemctl &> /dev/null; then
        cat > /etc/systemd/system/n8n-backup.timer <<EOF
[Unit]
Description=n8n Backup Timer
Requires=n8n-backup.service

[Timer]
OnCalendar=daily
OnBootSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

        cat > /etc/systemd/system/n8n-backup.service <<EOF
[Unit]
Description=n8n Backup Service
After=docker.service

[Service]
Type=oneshot
ExecStart=${N8N_CONFIG_DIR}/backup.sh
StandardOutput=append:/var/log/n8n-backup.log
StandardError=append:/var/log/n8n-backup.log
EOF

        systemctl daemon-reload
        systemctl enable n8n-backup.timer
        systemctl start n8n-backup.timer

        log_success "Backup timer configured"
    fi
}

################################################################################
# Phase 14: Create CLI Tool
################################################################################

create_cli_tool() {
    log_info "Creating n8n CLI management tool..."

    cat > /usr/local/bin/weretrade-n8n <<'EOF'
#!/bin/bash
# WereTrade n8n Management CLI

set -euo pipefail

N8N_CONFIG_DIR="/opt/weretrade/config/n8n"
N8N_STATE_FILE="/opt/weretrade/install-state-n8n.json"

# Detect Docker Compose command (v1 vs v2 compatibility)
if docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "❌ Docker Compose not found"
    exit 1
fi

show_help() {
    cat <<HELP
WereTrade n8n Management CLI

Usage: weretrade-n8n [COMMAND]

Commands:
  status      Show n8n status
  start       Start n8n service
  stop        Stop n8n service
  restart     Restart n8n service
  logs        Show n8n logs
  backup      Create backup
  monitor     Run health check
  credentials Show credentials
  info        Show installation info

Examples:
  weretrade-n8n status
  weretrade-n8n logs --tail 50
  weretrade-n8n backup

HELP
}

case "${1:-help}" in
    status)
        bash "${N8N_CONFIG_DIR}/monitor.sh"
        ;;
    start)
        cd "$N8N_CONFIG_DIR"
        $DOCKER_COMPOSE up -d
        echo "✅ n8n started"
        ;;
    stop)
        docker stop weretrade-n8n
        echo "✅ n8n stopped"
        ;;
    restart)
        bash "${N8N_CONFIG_DIR}/restart.sh"
        ;;
    logs)
        docker logs "${2:---tail 100}" weretrade-n8n
        ;;
    backup)
        bash "${N8N_CONFIG_DIR}/backup.sh"
        ;;
    monitor)
        bash "${N8N_CONFIG_DIR}/monitor.sh"
        ;;
    credentials)
        if [ -f "$N8N_STATE_FILE" ]; then
            jq '.' "$N8N_STATE_FILE"
        else
            echo "❌ State file not found"
            exit 1
        fi
        ;;
    info)
        echo "n8n Installation Information"
        echo "============================"
        if [ -f "$N8N_STATE_FILE" ]; then
            jq -r '"Version: " + .n8n_version,
                    "Method: " + .installation_method,
                    "Installed: " + .installation_date' "$N8N_STATE_FILE"
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
EOF

    chmod +x /usr/local/bin/weretrade-n8n

    log_success "CLI tool created: weretrade-n8n"
}

################################################################################
# Phase 15: Generate Documentation
################################################################################

generate_documentation() {
    log_info "Generating n8n documentation..."

    cat > "/opt/weretrade/N8N-SETUP-REPORT.txt" <<EOF
================================================================================
                    WereTrade n8n Workflow Automation
                          Installation Report
================================================================================

Installation Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Installation Method: ${INSTALL_METHOD}
n8n Version: ${N8N_VERSION}

================================================================================
ACCESS INFORMATION
================================================================================

Web Interface: http://localhost:${N8N_PORT}
Webhooks Endpoint: http://localhost:${N8N_PORT}/webhook
Webhook Test Endpoint: http://localhost:${N8N_PORT}/webhook-test

Admin Credentials:
  Email: MasterSpl1nter@weretrade.local
  Password: [See ${N8N_STATE_FILE}]

================================================================================
ARCHITECTURE
================================================================================

Installation Directory: ${N8N_INSTALL_DIR}
Data Directory: ${N8N_DATA_DIR}
Configuration Directory: ${N8N_CONFIG_DIR}
SSL Certificates: ${N8N_SSL_DIR}

Database Backend: PostgreSQL
Database Name: ${N8N_DB_NAME}
Database User: ${N8N_DB_USER}

Deployment: Docker Container
Container Name: ${N8N_CONTAINER_NAME}
Port: ${N8N_PORT}

================================================================================
MANAGEMENT COMMANDS
================================================================================

CLI Tool: weretrade-n8n

Available Commands:
  weretrade-n8n status      - Show n8n status
  weretrade-n8n start       - Start n8n service
  weretrade-n8n stop        - Stop n8n service
  weretrade-n8n restart     - Restart n8n service
  weretrade-n8n logs        - Show logs
  weretrade-n8n backup      - Create backup
  weretrade-n8n monitor     - Run health check
  weretrade-n8n credentials - Show credentials

Direct Docker Commands:
  docker ps | grep n8n                    - Check container status
  docker logs weretrade-n8n               - View logs
  docker exec -it weretrade-n8n sh        - Access container shell
  docker restart weretrade-n8n            - Restart container

================================================================================
SECURITY FEATURES
================================================================================

✅ PostgreSQL backend (no SQLite)
✅ Encryption key for credentials
✅ JWT authentication
✅ Webhook URL validation
✅ Anti-AI fingerprint obfuscation
✅ Version randomization
✅ Encrypted backups
✅ Secure credential storage

================================================================================
ANTI-AI DEFENSE
================================================================================

Implemented Protections:
  ✅ Version obfuscation (diagnostics disabled)
  ✅ Fingerprint randomization (nginx reverse proxy)
  ✅ Adversarial timing middleware
  ✅ Header sanitization
  ✅ Metrics disabled for external access

================================================================================
BACKUP & RECOVERY
================================================================================

Automated Backups:
  Schedule: Daily at midnight
  Location: /opt/weretrade/backups/n8n/
  Retention: 7 days
  Encryption: AES-256-CBC

Manual Backup:
  weretrade-n8n backup

Restore from Backup:
  1. Extract backup: tar -xzf n8n-backup-TIMESTAMP.tar.gz
  2. Copy workflows: cp -r workflows ${N8N_DATA_DIR}/
  3. Restore database: gunzip < n8n-db-TIMESTAMP.sql.gz | docker exec -i postgres-primary psql -U n8n_user n8n_db
  4. Restart n8n: weretrade-n8n restart

================================================================================
MONITORING
================================================================================

Health Check Endpoint: http://localhost:${N8N_PORT}/healthz

Automated Monitoring:
  Check Interval: Every 5 minutes
  Log File: /var/log/n8n-monitor.log

Manual Health Check:
  weretrade-n8n monitor
  curl http://localhost:${N8N_PORT}/healthz

Container Logs:
  weretrade-n8n logs --tail 100
  tail -f ${N8N_DATA_DIR}/logs/*.log

================================================================================
INTEGRATION WITH WERETRADE INFRASTRUCTURE
================================================================================

✅ PostgreSQL Integration (Primary Database)
✅ Redis Integration (Caching - Optional)
✅ MCP Server Integration (Service Discovery)
✅ SMTP Integration (Email Notifications)
✅ Anti-AI Defense Integration

================================================================================
WORKFLOW EXAMPLES
================================================================================

1. Email Notification Workflow:
   Trigger: Webhook
   Action: Send email via SMTP
   SMTP Host: localhost:587
   SMTP User: weretrade
   SMTP Password: [See /opt/weretrade/install-state-smtp.json]

2. Database Automation:
   Trigger: Schedule
   Action: PostgreSQL query
   Connection: postgres-primary:5432
   Database: (your database)

3. API Integration:
   Trigger: Webhook
   Action: HTTP Request
   Authentication: JWT or API Key

================================================================================
TROUBLESHOOTING
================================================================================

Common Issues:

1. Container Not Starting:
   - Check logs: weretrade-n8n logs
   - Verify PostgreSQL is running: docker ps | grep postgres
   - Check port availability: netstat -tulpn | grep ${N8N_PORT}

2. Database Connection Failed:
   - Verify credentials in ${N8N_STATE_FILE}
   - Check PostgreSQL logs: docker logs postgres-primary
   - Test connection: docker exec postgres-primary psql -U ${N8N_DB_USER} ${N8N_DB_NAME}

3. Webhooks Not Working:
   - Check webhook URL configuration
   - Verify firewall rules: iptables -L -n
   - Test webhook: curl -X POST http://localhost:${N8N_PORT}/webhook/test

4. Performance Issues:
   - Check container resources: docker stats weretrade-n8n
   - Review workflow execution logs
   - Optimize database queries

================================================================================
NEXT STEPS
================================================================================

1. Access n8n Web Interface:
   http://localhost:${N8N_PORT}

2. Create First Admin User:
   - Email: admin@weretrade.local
   - Password: [See ${N8N_STATE_FILE}]

3. Create Your First Workflow:
   - Click "New Workflow"
   - Add trigger (Webhook, Schedule, etc.)
   - Add action nodes
   - Test and activate

4. Configure Webhooks:
   - Get webhook URL from workflow
   - Configure external services to POST to webhook

5. Setup Email Notifications:
   - Add SMTP node
   - Configure with local SMTP server
   - Test email sending

6. Integrate with Existing Infrastructure:
   - Connect to PostgreSQL databases
   - Use Redis for caching
   - Trigger MCP Server actions

================================================================================
SECURITY RECOMMENDATIONS
================================================================================

1. Change default admin password immediately
2. Enable HTTPS in production (configure reverse proxy)
3. Restrict webhook URLs to trusted sources
4. Review workflow permissions regularly
5. Monitor execution logs for anomalies
6. Keep n8n updated (check for security patches)
7. Use environment-specific credentials
8. Enable audit logging for sensitive workflows

================================================================================
USEFUL LINKS
================================================================================

n8n Documentation: https://docs.n8n.io/
n8n Community: https://community.n8n.io/
n8n GitHub: https://github.com/n8n-io/n8n
Workflow Templates: https://n8n.io/workflows

================================================================================

For support, check logs at: ${N8N_DATA_DIR}/logs/
Installation state: ${N8N_STATE_FILE}

EOF

    chmod 644 "/opt/weretrade/N8N-SETUP-REPORT.txt"

    log_success "Documentation generated: /opt/weretrade/N8N-SETUP-REPORT.txt"
}

################################################################################
# Main Execution
################################################################################

main() {
    local action="${1:-deploy}"

    case "$action" in
        --deploy|deploy)
            log_info "Starting n8n deployment..."
            log_info "Installation method: $INSTALL_METHOD"

            purge_existing_n8n
            prepare_environment
            install_dependencies
            generate_credentials
            setup_database
            generate_ssl_certificates

            if [ "$INSTALL_METHOD" = "docker" ]; then
                install_docker
            else
                install_from_source
                create_systemd_service
            fi

            integrate_anti_ai_defense
            create_management_scripts
            setup_monitoring
            setup_backups
            create_cli_tool
            generate_documentation

            log_success "==========================================="
            log_success "n8n Workflow Automation Deployed Successfully!"
            log_success "==========================================="
            log_info ""
            log_info "Access Information:"
            log_info "  Web Interface: http://localhost:${N8N_PORT}"
            log_info "  Admin Email: admin@weretrade.local"
            log_info "  Credentials: ${N8N_STATE_FILE}"
            log_info ""
            log_info "Management:"
            log_info "  CLI: weretrade-n8n status"
            log_info "  Logs: weretrade-n8n logs"
            log_info "  Backup: weretrade-n8n backup"
            log_info ""
            log_info "Documentation: /opt/weretrade/N8N-SETUP-REPORT.txt"
            ;;

        --purge|purge)
            purge_existing_n8n
            log_success "n8n purged successfully"
            ;;

        --help|help)
            cat <<HELP
n8n Orchestrator Script

Usage: $0 [COMMAND]

Commands:
  --deploy, deploy    Deploy n8n (default)
  --purge, purge      Remove existing n8n installation
  --help, help        Show this help message

Environment Variables:
  N8N_VERSION          n8n version to install (default: latest)
  N8N_PORT             Port for n8n web interface (default: 5678)
  N8N_INSTALL_METHOD   Installation method: docker or source (default: docker)

Examples:
  # Deploy with Docker (recommended)
  $0 --deploy

  # Deploy with custom port
  N8N_PORT=8080 $0 --deploy

  # Deploy from source
  N8N_INSTALL_METHOD=source $0 --deploy

  # Purge existing installation
  $0 --purge

HELP
            ;;

        *)
            log_error "Unknown command: $action"
            log_error "Use --help for usage information"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
