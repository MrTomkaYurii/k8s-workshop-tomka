#!/usr/bin/env bash
# =============================================================================
# 00-setup.sh — Встановлення та перевірка середовища для воркшопу
# =============================================================================
#
# Цей скрипт:
#   1. Перевіряє наявність всіх необхідних інструментів
#   2. Встановлює відсутні (де можливо автоматично)
#   3. Виводить підсумок готовності середовища
#
# ВИКОРИСТАННЯ:
#   chmod +x scripts/00-setup.sh
#   ./scripts/00-setup.sh
#
# Підтримувані ОС: macOS, Linux (Ubuntu/Debian/RHEL)
# =============================================================================

set -e  # Зупинити скрипт при будь-якій помилці
set -u  # Помилка при використанні невизначеної змінної

# =============================================================================
# Налаштування кольорів для красивого виводу
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'  # No Color — скинути форматування

# =============================================================================
# Допоміжні функції
# =============================================================================

# Вивести заголовок секції
print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}=== $1 ===${NC}"
    echo ""
}

# Вивести успіх
print_ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

# Вивести помилку
print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

# Вивести попередження
print_warning() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

# Вивести інформацію
print_info() {
    echo -e "  ${BLUE}→${NC} $1"
}

# Перевірити чи команда існує
command_exists() {
    command -v "$1" &> /dev/null
}

# Визначити операційну систему
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/redhat-release ]]; then
        echo "redhat"
    else
        echo "unknown"
    fi
}

# Визначити архітектуру процесора
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        arm64)   echo "arm64" ;;
        *)       echo "$arch" ;;
    esac
}

# =============================================================================
# Виявлення середовища
# =============================================================================
OS=$(detect_os)
ARCH=$(detect_arch)
ERRORS=0   # Лічильник критичних помилок

echo ""
echo -e "${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Kubernetes Workshop — Перевірка       ║${NC}"
echo -e "${BOLD}║   середовища для навчання               ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""
print_info "Операційна система: $OS"
print_info "Архітектура: $ARCH"

# =============================================================================
# Крок 1: Docker
# =============================================================================
print_section "Крок 1: Перевірка Docker"

if command_exists docker; then
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
    print_ok "Docker встановлено: версія $DOCKER_VERSION"

    # Перевіряємо що Docker daemon запущено і відповідає
    if docker info &> /dev/null; then
        print_ok "Docker daemon запущено і відповідає"

        # Перевіряємо достатній обсяг пам'яті (мінімум 4GB рекомендовано)
        DOCKER_MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
        DOCKER_MEM_GB=$(( DOCKER_MEM / 1024 / 1024 / 1024 ))
        if (( DOCKER_MEM_GB >= 4 )); then
            print_ok "Docker пам'ять: ${DOCKER_MEM_GB}GB (достатньо)"
        else
            print_warning "Docker пам'ять: ${DOCKER_MEM_GB}GB (рекомендовано 4GB+)"
            print_info "Збільши ліміт в Docker Desktop → Settings → Resources → Memory"
        fi
    else
        print_error "Docker daemon НЕ запущено!"
        print_info "Запусти Docker Desktop і спробуй знову"
        ERRORS=$((ERRORS + 1))
    fi
else
    print_error "Docker не встановлено!"
    print_info "Встанови Docker Desktop: https://www.docker.com/products/docker-desktop"
    ERRORS=$((ERRORS + 1))
fi

# =============================================================================
# Крок 2: kind
# =============================================================================
print_section "Крок 2: Перевірка kind (Kubernetes IN Docker)"

KIND_VERSION_TARGET="0.23.0"  # Мінімальна версія

if command_exists kind; then
    KIND_VERSION=$(kind --version | awk '{print $3}')
    print_ok "kind встановлено: версія $KIND_VERSION"
else
    print_warning "kind не встановлено"

    if [[ "$OS" == "macos" ]]; then
        print_info "Встановлення через Homebrew..."
        if command_exists brew; then
            brew install kind
            print_ok "kind встановлено через Homebrew"
        else
            print_error "Homebrew не встановлено. Встанови вручну:"
            print_info "curl -Lo ./kind https://kind.sigs.k8s.io/dl/v${KIND_VERSION_TARGET}/kind-darwin-${ARCH}"
            print_info "chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind"
            ERRORS=$((ERRORS + 1))
        fi
    elif [[ "$OS" == "debian" ]] || [[ "$OS" == "redhat" ]]; then
        print_info "Завантажуємо kind для Linux ${ARCH}..."
        curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v${KIND_VERSION_TARGET}/kind-linux-${ARCH}"
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
        print_ok "kind встановлено в /usr/local/bin/kind"
    else
        print_error "Невідома ОС. Встанови kind вручну:"
        print_info "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
        ERRORS=$((ERRORS + 1))
    fi
fi

# =============================================================================
# Крок 3: kubectl
# =============================================================================
print_section "Крок 3: Перевірка kubectl"

if command_exists kubectl; then
    KUBECTL_VERSION=$(kubectl version --client --output=yaml 2>/dev/null \
        | grep gitVersion \
        | head -1 \
        | awk '{print $2}')
    print_ok "kubectl встановлено: $KUBECTL_VERSION"
else
    print_warning "kubectl не встановлено"

    if [[ "$OS" == "macos" ]]; then
        if command_exists brew; then
            print_info "Встановлення через Homebrew..."
            brew install kubectl
            print_ok "kubectl встановлено"
        else
            print_error "Встанови kubectl вручну: https://kubernetes.io/docs/tasks/tools/"
            ERRORS=$((ERRORS + 1))
        fi
    elif [[ "$OS" == "debian" ]]; then
        print_info "Встановлення kubectl для Linux..."
        KUBECTL_STABLE=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -LO "https://dl.k8s.io/release/${KUBECTL_STABLE}/bin/linux/${ARCH}/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/kubectl
        print_ok "kubectl встановлено"
    else
        print_error "Встанови kubectl вручну: https://kubernetes.io/docs/tasks/tools/"
        ERRORS=$((ERRORS + 1))
    fi
fi

# =============================================================================
# Крок 4: helm
# =============================================================================
print_section "Крок 4: Перевірка helm (менеджер пакетів для K8s)"

if command_exists helm; then
    HELM_VERSION=$(helm version --short 2>/dev/null | cut -d'+' -f1)
    print_ok "helm встановлено: $HELM_VERSION"
else
    print_warning "helm не встановлено"

    if [[ "$OS" == "macos" ]] && command_exists brew; then
        print_info "Встановлення через Homebrew..."
        brew install helm
        print_ok "helm встановлено"
    else
        print_info "Встановлення через офіційний скрипт..."
        curl -fsSL -o /tmp/get_helm.sh \
            https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 /tmp/get_helm.sh
        /tmp/get_helm.sh
        rm /tmp/get_helm.sh
        print_ok "helm встановлено"
    fi
fi

# =============================================================================
# Крок 5: Перевірка мережевих портів
# =============================================================================
print_section "Крок 5: Перевірка портів"

# Перевіряємо чи порт 80 вільний (потрібен для Ingress)
check_port() {
    local port=$1
    if command_exists lsof; then
        if lsof -i ":$port" &> /dev/null; then
            print_warning "Порт $port зайнятий"
            lsof -i ":$port" | grep LISTEN | head -3
            print_info "Вивільни порт $port перед запуском кластеру"
        else
            print_ok "Порт $port вільний"
        fi
    else
        print_info "Порт $port: перевірка пропущена (lsof не встановлено)"
    fi
}

check_port 80
check_port 443

# =============================================================================
# Крок 6: Підсумок
# =============================================================================
print_section "Підсумок"

echo "  Встановлені версії:"
command_exists docker  && echo "    Docker:  $(docker --version | cut -d' ' -f3 | tr -d ',')"
command_exists kind    && echo "    kind:    $(kind --version | awk '{print $3}')"
command_exists kubectl && echo "    kubectl: $(kubectl version --client --short 2>/dev/null || echo 'встановлено')"
command_exists helm    && echo "    helm:    $(helm version --short 2>/dev/null | cut -d'+' -f1)"

echo ""

if (( ERRORS == 0 )); then
    echo -e "  ${GREEN}${BOLD}✓ Середовище готове до роботи!${NC}"
    echo ""
    echo "  Наступний крок — створення кластеру:"
    echo ""
    echo "    kind create cluster --name workshop \\"
    echo "      --config k8s/00-cluster/kind-config.yaml"
    echo ""
else
    echo -e "  ${RED}${BOLD}✗ Знайдено $ERRORS помилок. Виправ їх і запусти скрипт знову.${NC}"
    echo ""
    exit 1
fi
