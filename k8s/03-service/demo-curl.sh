#!/usr/bin/env bash
# =============================================================================
# demo-curl.sh — Демонстрація Service: DNS, балансування, Endpoints
# =============================================================================
#
# Що показує цей скрипт:
#   1. DNS розпізнавання всередині кластеру
#   2. ClusterIP як стабільна точка доступу
#   3. Автоматичне оновлення Endpoints при зміні Pod'ів
#   4. NodePort доступ ззовні
#
# ВИКОРИСТАННЯ:
#   chmod +x k8s/03-service/demo-curl.sh
#   ./k8s/03-service/demo-curl.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

print_step() {
    echo ""
    echo -e "${BLUE}${BOLD}--- $1 ---${NC}"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_cmd() {
    echo -e "  ${BOLD}\$ $1${NC}"
}

# =============================================================================
# Крок 1: Перевірка готовності
# =============================================================================
print_step "Крок 1: Перевірка що Deployment і Services запущені"

if ! kubectl get deployment weather-api &> /dev/null; then
    echo "[ERROR] Deployment weather-api не знайдено"
    echo "Запусти: kubectl apply -f k8s/02-deployment/deployment.yaml"
    exit 1
fi

if ! kubectl get service weather-api-svc &> /dev/null; then
    echo "[ERROR] Service weather-api-svc не знайдено"
    echo "Запусти: kubectl apply -f k8s/03-service/clusterip.yaml"
    exit 1
fi

print_ok "Deployment weather-api знайдено"
print_ok "Service weather-api-svc знайдено"

echo ""
echo "Поточний стан:"
kubectl get pods -l app=weather-api -o wide
echo ""
kubectl get services weather-api-svc

# =============================================================================
# Крок 2: Endpoints — кому Service направляє трафік
# =============================================================================
print_step "Крок 2: Endpoints -- список живих Pod'ів"

echo ""
echo "Endpoints показують реальні IP:port Pod'ів за якими Service балансує:"
print_cmd "kubectl get endpoints weather-api-svc"
kubectl get endpoints weather-api-svc

# =============================================================================
# Крок 3: DNS зсередини кластеру
# =============================================================================
print_step "Крок 3: DNS розпізнавання зсередини кластеру"

echo ""
echo "Запускаємо тимчасовий Pod і перевіряємо DNS..."
echo "(Pod автоматично видалиться після завершення через --rm)"
echo ""

# nslookup через окремий Pod
kubectl run dns-test \
  --image=busybox:1.36 \
  --restart=Never \
  --rm \
  --quiet \
  -- nslookup weather-api-svc 2>/dev/null || true

echo ""
echo "Пояснення результату:"
echo "  Server:  -- це CoreDNS (10.96.0.10 або подібне)"
echo "  Address: -- IP ClusterIP Service'у (weather-api-svc)"
echo "  CoreDNS розпізнав скорочене ім'я до FQDN автоматично"

# =============================================================================
# Крок 4: HTTP запит до Service через DNS
# =============================================================================
print_step "Крок 4: HTTP запит через DNS-ім'я Service'у"

echo ""
echo "Запускаємо curl з тимчасового Pod'у..."
print_cmd "curl -s http://weather-api-svc/ (зсередині кластеру)"
echo ""

kubectl run curl-demo \
  --image=curlimages/curl:latest \
  --restart=Never \
  --rm \
  --quiet \
  -- curl -s --max-time 5 http://weather-api-svc/ 2>/dev/null | head -20 || true

echo ""
echo "Якщо вище ти бачиш HTML від nginx -- Service працює правильно."
echo "DNS-ім'я 'weather-api-svc' розпізналось до ClusterIP,"
echo "ClusterIP перенаправив запит на один з Pod'ів."

# =============================================================================
# Крок 5: Стеження за Endpoints при зміні Pod'ів
# =============================================================================
print_step "Крок 5: Як Endpoints змінюються при масштабуванні"

echo ""
echo "Поточна кількість Endpoints:"
kubectl get endpoints weather-api-svc

echo ""
echo "Масштабуємо Deployment до 1 репліки..."
kubectl scale deployment weather-api --replicas=1
sleep 5

echo "Endpoints після масштабування до 1:"
kubectl get endpoints weather-api-svc

echo ""
echo "Масштабуємо назад до 3 реплік..."
kubectl scale deployment weather-api --replicas=3

echo ""
echo "Чекаємо поки Pod'и запустяться..."
kubectl rollout status deployment weather-api --timeout=60s

echo "Endpoints після масштабування до 3:"
kubectl get endpoints weather-api-svc

print_ok "Endpoints автоматично оновились разом з Pod'ами"

# =============================================================================
# Крок 6: NodePort доступ
# =============================================================================
print_step "Крок 6: Перевірка NodePort"

if kubectl get service weather-api-nodeport &> /dev/null; then
    echo ""
    echo "NodePort Service знайдено."
    kubectl get service weather-api-nodeport

    echo ""
    # Знаходимо IP будь-якого вузла
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[1].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    NODE_PORT="30080"

    if [ -n "$NODE_IP" ]; then
        echo "IP вузла: $NODE_IP, NodePort: $NODE_PORT"
        echo ""
        print_cmd "curl http://$NODE_IP:$NODE_PORT/"
        curl -s --max-time 5 "http://$NODE_IP:$NODE_PORT/" | head -5 || true
        echo ""
        print_ok "NodePort доступний ззовні кластеру"
    else
        echo "Не вдалось визначити IP вузла. Перевір вручну:"
        echo "  kubectl get nodes -o wide"
        echo "  curl http://<node-ip>:$NODE_PORT/"
    fi
else
    echo "NodePort Service не знайдено. Застосуй:"
    echo "  kubectl apply -f k8s/03-service/nodeport.yaml"
fi

# =============================================================================
# Підсумок
# =============================================================================
print_step "Підсумок демо"

echo ""
echo "Що ми побачили:"
echo "  1. Service надає стабільне DNS-ім'я незалежно від Pod'ів"
echo "  2. DNS-ім'я всередині кластеру: weather-api-svc.default.svc.cluster.local"
echo "  3. Endpoints автоматично оновлюються при зміні Pod'ів"
echo "  4. NodePort відкриває доступ ззовні кластеру"
echo ""
echo "Наступний урок: ConfigMap і Secret"
