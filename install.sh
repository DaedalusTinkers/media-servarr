#!/usr/bin/env bash

set -euo pipefail
umask 077

# ============================================
# media-servarr installer
# ============================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo
echo "============================================"
echo "        media-servarr Installer"
echo "============================================"
echo

# --------------------------------------------
# Detect operating system
# --------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: Cannot determine the operating system."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID}" in
    fedora|fedora-asahi-remix)
        OS_FAMILY="Fedora"
        ;;
    ubuntu)
        OS_FAMILY="Ubuntu"
        ;;
    debian)
        OS_FAMILY="Debian"
        ;;
    *)
        case "${ID_LIKE:-}" in
            *fedora*)
                OS_FAMILY="Fedora"
                ;;
            *debian*)
                OS_FAMILY="Debian"
                ;;
            *)
                echo "ERROR: Unsupported operating system: ${PRETTY_NAME}"
                echo
                echo "Supported operating systems:"
                echo "  - Fedora"
                echo "  - Ubuntu"
                echo "  - Debian"
                exit 1
                ;;
        esac
        ;;
esac

echo "Operating system: ${PRETTY_NAME}"
echo "Project directory: ${PROJECT_DIR}"
echo

# --------------------------------------------
# Install Docker on Fedora
# --------------------------------------------

install_docker_fedora() {
    echo
    echo "Installing Docker Engine and Docker Compose..."
    echo

    sudo dnf -y install dnf-plugins-core

    sudo dnf config-manager addrepo \
        --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo

    sudo dnf -y install \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    sudo systemctl enable --now docker

    # sudo usermod -aG docker "${USER}"

    echo
    echo "Docker installation completed."
    echo
}

# --------------------------------------------
# Install Docker on Ubuntu/Debian
# --------------------------------------------

install_docker_debian() {
    echo
    echo "Installing Docker Engine and Docker Compose..."
    echo

    sudo apt-get update

    sudo apt-get -y install \
        ca-certificates \
        curl

    sudo install -m 0755 -d /etc/apt/keyrings

    sudo curl -fsSL \
        https://download.docker.com/linux/"${ID}"/gpg \
        -o /etc/apt/keyrings/docker.asc

    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/${ID} \
        ${VERSION_CODENAME} stable" |
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update

    sudo apt-get -y install \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    sudo systemctl enable --now docker

    # sudo usermod -aG docker "${USER}"

    echo
    echo "Docker installation completed."
    echo
}


# --------------------------------------------
# Configure Docker access
# --------------------------------------------

configure_docker_access() {
    echo
    echo "Configuring Docker access..."
    echo

    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
    fi

    sudo usermod -aG docker "${USER}"

    if docker info >/dev/null 2>&1; then
        echo "Docker access: OK"
    else
        echo "Docker access will be available after the next login."
        echo "The installer will use sudo for Docker commands"
        echo "during this installation."
    fi

    echo
}


# --------------------------------------------
# Docker command wrapper
# --------------------------------------------

docker_cmd() {
    if docker info >/dev/null 2>&1; then
        docker "$@"
    else
        sudo docker "$@"
    fi
}

# --------------------------------------------
# Check Docker and Docker Compose
# --------------------------------------------

DOCKER_INSTALLED=false
COMPOSE_INSTALLED=false

if command -v docker >/dev/null 2>&1; then
    DOCKER_INSTALLED=true

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_INSTALLED=true
    fi
fi

if [[ "${DOCKER_INSTALLED}" == true && "${COMPOSE_INSTALLED}" == true ]]; then
    echo "Docker:         OK"
    echo "Docker Compose: OK"
    echo
else
    echo "Docker:         $([[ "${DOCKER_INSTALLED}" == true ]] && echo "OK" || echo "NOT INSTALLED")"
    echo "Docker Compose: $([[ "${COMPOSE_INSTALLED}" == true ]] && echo "OK" || echo "NOT INSTALLED")"
    echo

    echo "Docker and Docker Compose are required by media-servarr."
    echo

    read -r -p "Would you like to install the missing components now? [Y/n]: " INSTALL_DOCKER

    if [[ ! "${INSTALL_DOCKER}" =~ ^([Yy]|[Yy][Ee][Ss]|)$ ]]; then
        echo
        echo "Docker installation cancelled."
        echo "Please install Docker and Docker Compose, then run this installer again."
        exit 1
    fi

    case "${OS_FAMILY}" in
        Fedora)
            install_docker_fedora
            ;;
        Ubuntu|Debian)
            install_docker_debian
            ;;
        *)
            echo "ERROR: Docker installation is not supported on this operating system."
            exit 1
            ;;
    esac
fi

configure_docker_access


# --------------------------------------------
# Detect timezone
# --------------------------------------------

if command -v timedatectl >/dev/null 2>&1; then
    TZ_VALUE="$(timedatectl show --property=Timezone --value)"
else
    TZ_VALUE=""
fi

if [[ -z "${TZ_VALUE}" ]]; then
    echo "WARNING: Could not automatically detect the system timezone."
    read -r -p "Enter your timezone (example: America/Los_Angeles): " TZ_VALUE
fi

echo "Timezone:        ${TZ_VALUE}"
echo


# --------------------------------------------
# Detect user and data settings
# --------------------------------------------

PUID="$(id -u)"
DATA_ROOT="/data"

if getent group docker >/dev/null 2>&1; then
    PGID="$(getent group docker | cut -d: -f3)"
else
    echo "ERROR: Docker group was not found."
    exit 1
fi

echo "PUID:            ${PUID}"
echo "Docker PGID:     ${PGID}"
echo "Data root:       ${DATA_ROOT}"
echo


# --------------------------------------------
# Create .env
# --------------------------------------------

ENV_FILE="${PROJECT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
    echo "An existing .env file was found."
    echo "The installer will use the existing configuration."
    echo
else
    # ----------------------------------------
    # VPN configuration
    # ----------------------------------------

    echo "============================================"
    echo "        VPN Configuration"
    echo "============================================"
    echo

    read -r -s -p "ProtonVPN WireGuard private key: " WIREGUARD_PRIVATE_KEY
    echo

    if [[ -z "${WIREGUARD_PRIVATE_KEY}" ]]; then
        echo "ERROR: A WireGuard private key is required."
        exit 1
    fi

    read -r -p "ProtonVPN server country [United States]: " SERVER_COUNTRIES

    if [[ -z "${SERVER_COUNTRIES}" ]]; then
        SERVER_COUNTRIES="United States"
    fi

    echo
    echo "VPN provider:   ProtonVPN"
    echo "VPN type:       WireGuard"
    echo "Server country: ${SERVER_COUNTRIES}"
    echo

    # ----------------------------------------
    # Write .env
    # ----------------------------------------

    cat > "${ENV_FILE}" <<EOF
TZ=${TZ_VALUE}

DATA_ROOT=${DATA_ROOT}

PUID=${PUID}
PGID=${PGID}

VPN_SERVICE_PROVIDER=protonvpn
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY}
SERVER_COUNTRIES=${SERVER_COUNTRIES}
VPN_PORT_FORWARDING=on
PORT_FORWARD_ONLY=on
EOF

    chmod 600 "${ENV_FILE}"

    echo ".env created."
    echo
fi


# --------------------------------------------
# Create application directories
# --------------------------------------------

echo "Creating application directories..."

mkdir -p \
    "${PROJECT_DIR}/config/gluetun" \
    "${PROJECT_DIR}/config/qbittorrent" \
    "${PROJECT_DIR}/config/prowlarr" \
    "${PROJECT_DIR}/config/sonarr" \
    "${PROJECT_DIR}/config/radarr" \
    "${PROJECT_DIR}/config/jellyfin"

echo "Application directories created."

# --------------------------------------------
# Create media directories
# --------------------------------------------

echo "Creating media directories..."

sudo mkdir -p \
    "${DATA_ROOT}/downloads/incoming" \
    "${DATA_ROOT}/downloads/complete" \
    "${DATA_ROOT}/media/movies" \
    "${DATA_ROOT}/media/shows"

echo "Media directories created."
echo


# --------------------------------------------
# Set directory ownership and permissions
# --------------------------------------------

echo "Setting data directory ownership and permissions..."

# The user owns /data, while the docker group retains access.
sudo chown "${PUID}:docker" "${DATA_ROOT}"

sudo chown -R \
    "${PUID}:docker" \
    "${DATA_ROOT}/downloads" \
    "${DATA_ROOT}/media"

sudo find \
    "${DATA_ROOT}/downloads" \
    "${DATA_ROOT}/media" \
    -type d \
    -exec chmod 2775 {} +

sudo find \
    "${DATA_ROOT}/downloads" \
    "${DATA_ROOT}/media" \
    -type f \
    -exec chmod 0664 {} +

echo "Data directory ownership and permissions configured."
echo


# --------------------------------------------
# Configure qBittorrent
# --------------------------------------------

echo "Configuring qBittorrent..."

if [[ ! -f "${PROJECT_DIR}/config/qbittorrent/qBittorrent/qBittorrent.conf" ]]; then
    mkdir -p "${PROJECT_DIR}/config/qbittorrent/qBittorrent"

    cat > "${PROJECT_DIR}/config/qbittorrent/qBittorrent/qBittorrent.conf" <<EOF
[BitTorrent]
Session\DefaultSavePath=${DATA_ROOT}/downloads/complete
Session\TempPath=${DATA_ROOT}/downloads/incoming
Session\TempPathEnabled=true

[Preferences]
WebUI\Username=qbt-admin
EOF

    chmod 600 "${PROJECT_DIR}/config/qbittorrent/qBittorrent/qBittorrent.conf"
fi

# echo "qBittorrent configured."
echo


# --------------------------------------------
# Configure SELinux for bind-mounted directories
# --------------------------------------------

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    echo "Configuring SELinux container labels..."

    if ! command -v semanage >/dev/null 2>&1; then
        echo "Installing SELinux management tools..."

        case "${OS_FAMILY}" in
            Fedora)
                sudo dnf -y install policycoreutils-python-utils
                ;;
            Ubuntu|Debian)
                sudo apt-get update
                sudo apt-get -y install policycoreutils-python-utils
                ;;
            *)
                echo "ERROR: Cannot install SELinux management tools"
                echo "Unsupported operating system: ${OS_FAMILY}"
                exit 1
                ;;
        esac
    fi

    sudo semanage fcontext -a -t container_file_t \
        "${PROJECT_DIR}/config(/.*)?" 2>/dev/null || \
    sudo semanage fcontext -m -t container_file_t \
        "${PROJECT_DIR}/config(/.*)?"

    sudo semanage fcontext -a -t container_file_t \
        "${DATA_ROOT}(/.*)?" 2>/dev/null || \
    sudo semanage fcontext -m -t container_file_t \
        "${DATA_ROOT}(/.*)?"

    sudo restorecon -Rv \
        "${PROJECT_DIR}/config" \
        "${DATA_ROOT}"

    echo "SELinux labels configured."
    echo
fi


# --------------------------------------------
# Create Docker network
# --------------------------------------------

if docker_cmd network inspect media-network >/dev/null 2>&1; then
    echo "Docker network: media-network already exists."
else
    echo "Creating Docker network: media-network..."
    docker_cmd network create media-network
    echo "Docker network created."
fi

echo


# --------------------------------------------
# Validate Docker Compose configuration
# --------------------------------------------

echo "Validating Docker Compose configuration..."

if ! docker_cmd compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" config --quiet; then
    echo
    echo "ERROR: Docker Compose configuration is invalid."
    echo "Please review the configuration and try again."
    exit 1
fi

echo "Docker Compose configuration: OK"
echo


# --------------------------------------------
# Start media-servarr
# --------------------------------------------

echo "============================================"
echo "        Ready to Start"
echo "============================================"
echo

read -r -p "Start the media-servarr stack now? [Y/n]: " START_STACK

if [[ ! "${START_STACK}" =~ ^([Yy]|[Yy][Ee][Ss]|)$ ]]; then
    echo
    echo "Installation complete."
    echo "Run the stack later with:"
    echo
    echo "  cd ${PROJECT_DIR}"
    echo "  docker compose up -d"
    echo
    exit 0
fi

echo
echo "Starting media-servarr..."
echo

docker_cmd compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" up -d

echo
echo "============================================"
echo "        media-servarr Started"
echo "============================================"
echo

docker_cmd compose --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/compose.yml" ps

echo
echo "Web interfaces:"
echo
echo "  qBittorrent:  http://localhost:8080"
echo "  Prowlarr:     http://localhost:9696"
echo "  Sonarr:       http://localhost:8989"
echo "  Radarr:       http://localhost:7878"
echo "  Jellyfin:     http://localhost:8096"
echo
echo "FlareSolverr is available internally to Prowlarr"
echo "at http://flaresolverr:8191"
echo