#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/career-ops}"
REPO_URL="${REPO_URL:-https://github.com/MuseraIsaac/career-ops.git}"
APP_USER="${SUDO_USER:-root}"
PLAYWRIGHT_IMAGE="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.58.2-noble}"

log()  { echo -e "\n[+] $*\n"; }
warn() { echo -e "\n[!] $*\n"; }
die()  { echo -e "\n[ERROR] $*\n" >&2; exit 1; }

cleanup() {
  local ec=$?
  if [[ $ec -ne 0 ]]; then
    echo -e "\n[ERROR] Setup failed. Review the command output above.\n" >&2
  fi
  exit "$ec"
}
trap cleanup EXIT

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root or with sudo."
}

run_as_app_user() {
  if [[ "${APP_USER}" == "root" ]]; then
    bash -lc "$*"
  else
    runuser -u "${APP_USER}" -- bash -lc "$*"
  fi
}

install_host_packages() {
  log "Installing required host packages..."
  dnf install -y \
    git curl ca-certificates dnf-plugins-core \
    bash tar findutils shadow-utils util-linux
}

install_docker() {
  log "Removing conflicting Docker packages if present..."
  dnf remove -y docker docker-client docker-client-latest docker-common docker-latest \
    docker-latest-logrotate docker-logrotate docker-engine || true

  log "Installing Docker CE repository..."
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

  log "Installing Docker Engine, Buildx, and Compose plugin..."
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Enabling and starting Docker..."
  systemctl enable --now docker

  if id "${APP_USER}" &>/dev/null && [[ "${APP_USER}" != "root" ]]; then
    usermod -aG docker "${APP_USER}" || true
  fi

  log "Verifying Docker..."
  docker run --rm hello-world >/dev/null
}

prepare_workspace() {
  log "Creating workspace at ${APP_DIR}..."
  mkdir -p "${APP_DIR}"

  if [[ -d "${APP_DIR}/.git" ]]; then
    log "Repository already exists; pulling latest changes..."
    run_as_app_user "cd '${APP_DIR}' && git pull --ff-only"
  elif [[ -z "$(find "${APP_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "Cloning repository..."
    run_as_app_user "git clone '${REPO_URL}' '${APP_DIR}'"
  else
    die "${APP_DIR} exists and is not empty, but is not a git repository."
  fi

  log "Setting host path ownership and permissions..."
  chown -R root:root "${APP_DIR}"
  chmod 755 "${APP_DIR}"
  find "${APP_DIR}" -type d -exec chmod 755 {} \;
  find "${APP_DIR}" -type f -exec chmod 644 {} \; || true
  find "${APP_DIR}" -type f \( -name "*.sh" -o -name "*.mjs" -o -name "*.js" \) -exec chmod 755 {} \; || true
}

write_container_files() {
  log "Writing Dockerfile..."
  cat > "${APP_DIR}/Dockerfile" <<EOF
FROM ${PLAYWRIGHT_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/root/.local/bin:\$PATH

USER root
WORKDIR /workspace

RUN apt-get update && apt-get install -y --no-install-recommends \\
    curl git ca-certificates bash sudo ripgrep \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \\
    && apt-get update \\
    && apt-get install -y --no-install-recommends nodejs \\
    && npm install -g npm@latest \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://claude.ai/install.sh | bash

RUN echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> /root/.bashrc
RUN /bin/bash -lc 'export PATH="\$HOME/.local/bin:\$PATH" && command -v claude'

CMD ["bash"]
EOF

  log "Writing docker-compose.yml..."
  cat > "${APP_DIR}/docker-compose.yml" <<'EOF'
services:
  career-ops:
    build:
      context: .
      dockerfile: Dockerfile
    image: career-ops-local:latest
    container_name: career-ops
    working_dir: /workspace
    user: "0:0"
    stdin_open: true
    tty: true
    init: true
    ipc: host
    environment:
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
    volumes:
      - ./:/workspace
EOF

  log "Writing .env.example..."
  cat > "${APP_DIR}/.env.example" <<'EOF'
ANTHROPIC_API_KEY=
EOF

  if [[ ! -f "${APP_DIR}/.env" ]]; then
    cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
  fi
}

prepare_repo_files() {
  log "Preparing repo config files..."
  [[ -f "${APP_DIR}/config/profile.yml" ]] || cp "${APP_DIR}/config/profile.example.yml" "${APP_DIR}/config/profile.yml"
  [[ -f "${APP_DIR}/portals.yml" ]] || cp "${APP_DIR}/templates/portals.example.yml" "${APP_DIR}/portals.yml"

  if [[ ! -f "${APP_DIR}/cv.md" ]]; then
    cat > "${APP_DIR}/cv.md" <<'CVEOF'
# Your CV

Replace this file with your full CV in Markdown.
CVEOF
  fi
}

build_and_bootstrap() {
  log "Stopping any previous compose stack..."
  run_as_app_user "cd '${APP_DIR}' && docker compose down --remove-orphans || true"

  log "Building container image..."
  run_as_app_user "cd '${APP_DIR}' && docker compose build --no-cache"

  log "Installing project dependencies inside container..."
  run_as_app_user "
    cd '${APP_DIR}' && \
    docker compose run --rm career-ops bash -lc '
      set -Eeuo pipefail
      echo '\''export PATH=\"\$HOME/.local/bin:\$PATH\"'\'' >> ~/.bashrc
      export PATH=\"\$HOME/.local/bin:\$PATH\"
      npm install
      npx playwright install chromium
      npm run doctor
      command -v claude
      claude --version || true
    '
  "
}

print_next_steps() {
  cat <<EOF

============================================================
Career-Ops container setup is complete.
============================================================

Project path:
  ${APP_DIR}

Edit these files:
  ${APP_DIR}/.env
  ${APP_DIR}/config/profile.yml
  ${APP_DIR}/portals.yml
  ${APP_DIR}/cv.md

Then start an interactive shell:
  cd ${APP_DIR}
  docker compose run --rm career-ops bash

Inside the container, Claude PATH is already configured.
You can run:
  claude

Useful commands:
  Rebuild:
    cd ${APP_DIR} && docker compose build --no-cache

  Re-check:
    cd ${APP_DIR}
    docker compose run --rm career-ops bash -lc 'export PATH="\$HOME/.local/bin:\$PATH"; npm run doctor'

  Manual bootstrap:
    cd ${APP_DIR}
    docker compose run --rm career-ops bash -lc 'echo '\''export PATH="\$HOME/.local/bin:\$PATH"'\'' >> ~/.bashrc; export PATH="\$HOME/.local/bin:\$PATH"; npm install && npx playwright install chromium && npm run doctor'

EOF
}

main() {
  require_root
  install_host_packages
  install_docker
  prepare_workspace
  write_container_files
  prepare_repo_files
  build_and_bootstrap
  print_next_steps
}

main "$@"
