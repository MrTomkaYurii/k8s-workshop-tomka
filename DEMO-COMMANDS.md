# Команди для демонстрації — Kubernetes Workshop

> Шпаргалка для ведучого. Команди виконуються послідовно в рамках кожного уроку.  
> Всі команди запускаються з кореневої директорії `k8s-workshop/`.

---

## Урок 00 — Кластер (kind)

### Перевірка середовища

```bash
# Перевіряємо Docker (повинен бути запущений)
docker --version
docker ps

# Перевіряємо інструменти
kind --version
kubectl version --client
```

### Створення кластеру

```bash
# Створюємо кластер з конфігу (2-3 хвилини — завантажує образ kindest/node)
kind create cluster --name workshop --config k8s/00-cluster/kind-config.yaml
```

### Перевірка кластеру

```bash
# Переконуємось що kubectl дивиться на наш кластер
kubectl config current-context
# Очікувано: kind-workshop

# Три вузли — один control-plane, два worker
kubectl get nodes

# Детальна інформація про вузол (CPU, RAM, Pod'и, Events)
kubectl describe node workshop-worker

# Системні Pod'и: etcd, api-server, scheduler, coredns, kube-proxy
kubectl get pods -A

# Вузли кластеру — це Docker-контейнери на вашій машині
docker ps | grep workshop
```

### Kubeconfig (як kubectl знає куди звертатись)

```bash
# Переглядаємо список контекстів
kubectl config get-contexts

# Переключити контекст (якщо є кілька кластерів)
kubectl config use-context kind-workshop
```

---

### 🔄 Перехід до Уроку 01

```bash
# Кластер залишається запущеним — він потрібен для всіх наступних уроків
# Перевірка перед початком уроку 01:
kubectl get nodes
# Очікувано: 3 вузли зі статусом Ready
```

---

## Урок 01 — Pod

### Підготовка (початок уроку)

```bash
# Перевіряємо що кластер запущений
kubectl config current-context
kubectl get nodes
```

### Створення Pod'у

```bash
# Застосовуємо YAML — kubectl передає в API Server, він записує в etcd
kubectl apply -f k8s/01-pod/pod.yaml

# Спостерігаємо за запуском (Ctrl+C щоб вийти)
kubectl get pods --watch
```

### Інспекція Pod'у

```bash
# Список Pod'ів у namespace default
kubectl get pods

# З IP-адресою і назвою вузла
kubectl get pods -o wide

# Повний стан в YAML (поточний стан, не те що ми подали)
kubectl get pod weather-pod -o yaml

# Детальна інформація + Events (тут видно помилки при проблемах)
kubectl describe pod weather-pod
```

### Логи і виконання команд

```bash
# Переглядаємо логи nginx
kubectl logs weather-pod

# Логи в реальному часі
kubectl logs weather-pod -f

# Заходимо всередину контейнера (alpine — sh, не bash)
kubectl exec -it weather-pod -- sh
# Всередині:
#   ls /              # файлова система контейнера
#   env               # змінні середовища
#   curl localhost    # nginx відповідає на localhost:80
#   exit
```

### Дебагінг — корисні команди

```bash
# Події кластеру (хронологія)
kubectl get events --sort-by='.lastTimestamp'

# Перевірити YAML без застосування
kubectl apply -f k8s/01-pod/pod.yaml --dry-run=client
```

---

### 🔴 ДЕМО: Pod без контролера не воскресає

```bash
# [ТЕРМІНАЛ 1] Спостерігаємо за Pod'ами
kubectl get pods --watch

# [ТЕРМІНАЛ 2] Видаляємо Pod
kubectl delete pod weather-pod

# Результат: Pod зник назавжди — нікому за ним стежити
kubectl get pods
# No resources found in default namespace.
```

---

### 🧹 Очистка після Уроку 01

```bash
# Pod вже видалений після ДЕМО. Якщо ні — видаляємо:
kubectl delete pod weather-pod --ignore-not-found
```

### 🔄 Перехід до Уроку 02

```bash
# Перевіряємо що Pod'ів немає — чистий старт
kubectl get pods
# No resources found in default namespace.

# Кластер запущений
kubectl get nodes
```

---

## Урок 02 — Deployment

### Підготовка (початок уроку)

```bash
kubectl config current-context
kubectl get nodes
# Переконуємось що немає залишкових Pod'ів
kubectl get pods
```

### Створення Deployment'у

```bash
# Застосовуємо — Deployment створить ReplicaSet, той створить 3 Pod'и
kubectl apply -f k8s/02-deployment/deployment.yaml

# Спостерігаємо за запуском трьох Pod'ів (Ctrl+C щоб вийти)
kubectl get pods --watch
```

### Розуміємо структуру: Deployment → ReplicaSet → Pod

```bash
# Дивимось Deployment (UP-TO-DATE, AVAILABLE)
kubectl get deployments

# Детальна інформація (Events: кого і коли масштабував)
kubectl describe deployment weather-api

# Дивимось ReplicaSet що Deployment створив
kubectl get replicasets

# Pod'и з розподілом по вузлах
kubectl get pods -o wide
```

### Пояснюємо іменування Pod'ів

```bash
# Ім'я Pod'у = [deployment]-[replicaset-hash]-[random]
# weather-api - 7d6b8f9c4 - xk2pt
#     |              |          |
# Deployment    RS hash    Унікальний суфікс
kubectl get pods
```

---

### 🔴 ДЕМО: Pod під Deployment воскресає

```bash
# [ТЕРМІНАЛ 1] Відкриваємо watch — будемо бачити зміни в реальному часі
kubectl get pods --watch

# [ТЕРМІНАЛ 2] Запам'ятовуємо ім'я одного Pod'у і видаляємо його
kubectl get pods
kubectl delete pod <ім'я-pod'у>  # підставити реальне ім'я

# У ТЕРМІНАЛ 1: видно як старий Pod переходить в Terminating,
# і відразу з'являється новий зі статусом Pending → Running
# Pod'ів знову три, але один — з новим суфіксом (це новий Pod, не той самий)

# Підтверджуємо: Pod'ів три
kubectl get pods
```

---

### Масштабування

```bash
# Збільшуємо до 5 реплік (через команду — тимчасово)
kubectl scale deployment weather-api --replicas=5
kubectl get pods

# Масштабуємо до 0 — Pod'и зупинені, але Deployment зберігається
kubectl scale deployment weather-api --replicas=0
kubectl get pods
# No resources found.

# Повертаємо 3 репліки
kubectl scale deployment weather-api --replicas=3
kubectl rollout status deployment weather-api
```

---

### 🔴 ДЕМО: Rolling Update — оновлення без простою

```bash
# [ТЕРМІНАЛ 1] Спостерігаємо за Pod'ами під час оновлення
kubectl get pods --watch

# [ТЕРМІНАЛ 2] Оновлюємо образ через командний рядок
kubectl set image deployment/weather-api weather-api=nginxinc/nginx-unprivileged:1.27-alpine

# Або через файл (правильніший спосіб):
# Відредагуй image в deployment.yaml → kubectl apply -f k8s/02-deployment/deployment.yaml

# Статус rolling update
kubectl rollout status deployment weather-api

# Дивимось ReplicaSet'и — має бути старий (0 реплік) і новий (3 репліки)
kubectl get replicasets
```

### Перегляд і відкат

```bash
# Історія ревізій
kubectl rollout history deployment weather-api

# Повертаємось до попередньої версії
kubectl rollout undo deployment weather-api

# Або до конкретної ревізії
kubectl rollout undo deployment weather-api --to-revision=1

# Перевіряємо що повернулись
kubectl rollout status deployment weather-api
kubectl get pods
```

---

### 🧹 Очистка після Уроку 02

```bash
# Видаляємо Deployment (і всі Pod'и разом з ним)
kubectl delete deployment weather-api

# Перевіряємо — Pod'и теж зникли
kubectl get deployments
kubectl get pods
```

### 🔄 Перехід до Уроку 03

```bash
# Урок 03 потребує запущений Deployment — створюємо заново
kubectl apply -f k8s/02-deployment/deployment.yaml

# Чекаємо поки всі Pod'и готові
kubectl rollout status deployment weather-api

# Перевіряємо
kubectl get pods
# Очікувано: 3 Pod'и зі статусом Running
```

---

## Урок 03 — Services

### Підготовка (початок уроку)

```bash
kubectl config current-context
kubectl get nodes

# Deployment повинен бути запущений (3 Pod'и)
kubectl get pods
kubectl get deployment weather-api
```

### ClusterIP Service — внутрішній доступ

```bash
# Застосовуємо ClusterIP Service
kubectl apply -f k8s/03-service/clusterip.yaml

# Дивимось Service (CLUSTER-IP — це віртуальна IP, не реальний інтерфейс)
kubectl get services
kubectl get svc  # скорочення

# Детальна інформація: IP, порти, Endpoints (куди направляє трафік)
kubectl describe service weather-api-svc

# Endpoints — реальні IP:port Pod'ів, що відповідають selector
kubectl get endpoints weather-api-svc
```

### Перевіряємо зв'язок між Pod'ами і Service

```bash
# Мітки Pod'ів (selector Service шукає саме їх)
kubectl get pods --show-labels

# Selector Service'у (повинен збігатись)
kubectl describe service weather-api-svc | grep Selector
```

### NodePort Service — доступ ззовні

```bash
# Застосовуємо NodePort Service
kubectl apply -f k8s/03-service/nodeport.yaml

# Порт 80:30080/TCP означає: Service:80, NodePort:30080
kubectl get services

# Знаходимо IP вузла для доступу ззовні
kubectl get nodes -o wide
```

---

### 🔴 ДЕМО: DNS і curl зсередини кластеру

```bash
# Запускаємо тимчасовий Pod для тестування (--rm — видалиться після exit)
kubectl run curl-test \
  --image=curlimages/curl:latest \
  --restart=Never \
  --rm \
  -it \
  -- sh

# --- Всередині Pod'у ---

# Дивимось як налаштований DNS
cat /etc/resolv.conf
# nameserver — це IP CoreDNS

# Розпізнаємо ім'я Service'у через DNS
nslookup weather-api-svc
# Повертає ClusterIP Service'у

# HTTP запит через DNS-ім'я (коротке)
curl -s http://weather-api-svc/

# HTTP запит через повне FQDN
curl -s http://weather-api-svc.default.svc.cluster.local/

# Виходимо — Pod видалиться автоматично
exit
```

---

### 🔴 ДЕМО: Endpoints змінюються при зміні Pod'ів

```bash
# [ТЕРМІНАЛ 1] Спостерігаємо за Endpoints в реальному часі
kubectl get endpoints weather-api-svc --watch

# [ТЕРМІНАЛ 2] Видаляємо один Pod
kubectl get pods
kubectl delete pod <ім'я-pod'у>  # підставити реальне ім'я

# У ТЕРМІНАЛ 1: видно що один IP зник з Endpoints, потім з'явився новий
# Service весь цей час доступний (переключився на двох живих Pod'ів)
```

### Демо-скрипт з повним циклом

```bash
# Автоматизований демонстраційний скрипт (DNS + curl + масштабування + NodePort)
./k8s/03-service/demo-curl.sh
```

---

### 🧹 Очистка після Уроку 03

```bash
# Видаляємо Services
kubectl delete service weather-api-svc
kubectl delete service weather-api-nodeport

# Видаляємо Deployment (і всі Pod'и)
kubectl delete deployment weather-api

# Перевіряємо — кластер чистий
kubectl get pods
kubectl get services
# Повинен залишитись лише стандартний 'kubernetes' service
```

---

---

## Урок 06 — Resources

### Підготовка (початок уроку)

```bash
kubectl config current-context
kubectl get nodes
kubectl get pods   # кластер повинен бути чистим
```

### LimitRange і ResourceQuota

```bash
# Застосовуємо дефолти для namespace
kubectl apply -f k8s/06-resources/limitrange.yaml
kubectl describe limitrange default-resource-limits

# Застосовуємо квоту namespace
kubectl apply -f k8s/06-resources/resourcequota.yaml
kubectl describe resourcequota workshop-quota
```

### Deployment з Guaranteed QoS

```bash
# Застосовуємо Deployment з resources (requests == limits → Guaranteed)
kubectl apply -f k8s/06-resources/deployment.yaml
kubectl rollout status deployment weather-api

# Перевіряємо QoS клас Pod'у
POD=$(kubectl get pods -l app=weather-api -o jsonpath='{.items[0].metadata.name}')
kubectl get pod $POD -o jsonpath='{.status.qosClass}'
# Очікувано: Guaranteed

# Детально — limits і requests
kubectl describe pod $POD | grep -A8 "Limits:"
```

### Kubectl top (якщо metrics-server встановлено)

```bash
# Встановлення metrics-server (один раз):
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment metrics-server -n kube-system

# Споживання Pod'ів і вузлів
kubectl top pods
kubectl top nodes
kubectl top pods --containers
```

---

### 🔴 ДЕМО: OOMKilled

```bash
# [ТЕРМІНАЛ 1] Спостерігаємо за Pod'ами
kubectl get pods --watch

# [ТЕРМІНАЛ 2] Запускаємо Pod що виділяє 200MB при ліміті 100Mi
kubectl apply -f k8s/06-resources/oom-demo.yaml

# У терміналі 1 бачимо:
# oom-demo   0/1   ContainerCreating
# oom-demo   1/1   Running            ← Pod запущений
# oom-demo   0/1   OOMKilled          ← вбитий ядром Linux!
# oom-demo   0/1   CrashLoopBackOff   ← K8s намагається перезапустити

# Діагностика:
kubectl describe pod oom-demo | grep -A5 "Last State"
# Last State:  Terminated
#   Reason:    OOMKilled
#   Exit Code: 137        ← 128 + SIGKILL(9) = 137

# Чистимо:
kubectl delete pod oom-demo --ignore-not-found
```

---

### 🔴 ДЕМО: CPU Throttling

```bash
# Запускаємо Pod що намагається використати 1 CPU при ліміті 200m
kubectl run cpu-throttle \
  --image=polinux/stress \
  --restart=Never \
  --limits='cpu=200m,memory=128Mi' \
  --requests='cpu=100m,memory=64Mi' \
  -- stress --cpu 1 --timeout 60

# Pod живий але throttled
kubectl get pods

# Заходимо і перевіряємо throttling через cgroup:
kubectl exec -it cpu-throttle -- cat /sys/fs/cgroup/cpu/cpu.stat
# nr_throttled / nr_periods → % часу в throttled стані

# Чистимо:
kubectl delete pod cpu-throttle --ignore-not-found
```

---

### 🧹 Очистка після Уроку 06

```bash
# Видаляємо Deployment
kubectl delete deployment weather-api --ignore-not-found

# Видаляємо LimitRange і ResourceQuota (для чистоти перед наступним уроком)
kubectl delete limitrange default-resource-limits --ignore-not-found
kubectl delete resourcequota workshop-quota --ignore-not-found

kubectl get pods    # порожньо
```

### 🔄 Перехід до Уроку 07

```bash
# Урок 07 потребує чистого namespace (Pod'ів немає)
kubectl get pods
kubectl get pvc     # PVC теж не повинно бути

# Перевіряємо StorageClass (потрібен для PVC)
kubectl get storageclass
# standard (default) — повинен бути присутній
```

---

## Урок 07 — StatefulSet (PostgreSQL)

### Підготовка (початок уроку)

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass   # standard (default) має бути
```

### Розгортання PostgreSQL

```bash
# Крок 1: Secret (обов'язково першим)
kubectl apply -f k8s/07-statefulset/postgres-secret.yaml
kubectl get secret postgres-secret

# Крок 2: Headless Service (DNS для Pod'ів StatefulSet)
kubectl apply -f k8s/07-statefulset/postgres-headless-svc.yaml

# Крок 3: Client Service (для WeatherApi)
kubectl apply -f k8s/07-statefulset/postgres-client-svc.yaml

kubectl get services
# postgres-headless: CLUSTER-IP = None   ← headless
# postgres-svc:      CLUSTER-IP = 10.x   ← звичайний ClusterIP

# Крок 4: StatefulSet
kubectl apply -f k8s/07-statefulset/postgres-statefulset.yaml

# Спостерігаємо за порядковим запуском:
kubectl get pods --watch
# postgres-0   ContainerCreating → Running → Ready (1/1)
# (тільки після Ready → міг би стартувати postgres-1)
```

### Інспекція StatefulSet

```bash
# Статус StatefulSet
kubectl get statefulset
kubectl describe statefulset postgres

# PVC що був автоматично створений
kubectl get pvc
# postgres-data-postgres-0   Bound   1Gi   ← автоматично з VolumeClaimTemplate

# PV що з'явився
kubectl get pv
```

### Створюємо тестові дані

```bash
# Підключаємось до PostgreSQL
kubectl exec -it postgres-0 -- psql -U weather_user -d weatherdb

# Всередині psql:
# CREATE TABLE cities (id SERIAL PRIMARY KEY, name VARCHAR(100), country VARCHAR(50));
# INSERT INTO cities (name, country) VALUES ('Lviv','Ukraine'),('Kyiv','Ukraine'),('Warsaw','Poland');
# SELECT * FROM cities;
# \q
```

---

### 🔴 ДЕМО: Дані виживають після смерті Pod'у

```bash
# [ТЕРМІНАЛ 1] Спостерігаємо
kubectl get pods --watch

# [ТЕРМІНАЛ 2] Видаляємо Pod
kubectl delete pod postgres-0

# У терміналі 1 бачимо:
# postgres-0   1/1   Terminating → 0/1 Pending → 0/1 Running → 1/1 Running
# Той самий Pod, той самий PVC — дані збережені!

# Перевіряємо дані після відновлення:
kubectl exec -it postgres-0 -- psql -U weather_user -d weatherdb -c "SELECT * FROM cities;"
# Всі 3 рядки на місці!
```

---

### 🔴 ДЕМО: DNS для окремих Pod'ів

```bash
# Запускаємо тимчасовий Pod для DNS тестування
kubectl run dns-test \
  --image=busybox:1.36 \
  --restart=Never \
  --rm \
  -it \
  -- sh

# Всередині Pod'у:
# nslookup postgres-headless
# → Повертає IP postgres-0 напряму (не ClusterIP!)

# nslookup postgres-0.postgres-headless
# → Завжди postgres-0, навіть після рестарту

# nslookup postgres-svc
# → Повертає ClusterIP (звичайний Service)

# exit  ← Pod автоматично видалиться
```

### Демо масштабування (опціонально)

```bash
# Масштабуємо до 3 реплік — спостерігаємо порядковий запуск
kubectl scale statefulset postgres --replicas=3
kubectl get pods --watch
# postgres-0 Ready → postgres-1 стартує → postgres-1 Ready → postgres-2 стартує

# Дивимось три PVC
kubectl get pvc
# postgres-data-postgres-0, postgres-data-postgres-1, postgres-data-postgres-2

# Повертаємо до 1 репліки (зворотній порядок зупинки: 2 → 1)
kubectl scale statefulset postgres --replicas=1
kubectl get pods --watch

# PVC залишились! (це поведінка за задумом)
kubectl get pvc
```

---

### 🧹 Очистка після Уроку 07

```bash
# Видаляємо StatefulSet (Pod'и зникають, PVC залишаються!)
kubectl delete statefulset postgres

# Перевіряємо — PVC живі
kubectl get pvc

# Видаляємо PVC вручну (і дані разом з ними)
kubectl delete pvc -l app=postgres

# Видаляємо Services і Secret
kubectl delete service postgres-headless postgres-svc
kubectl delete secret postgres-secret

# Перевіряємо чистоту
kubectl get pods
kubectl get pvc
kubectl get services
```

---

## Фінальне очищення — Видалення кластеру

```bash
# Видаляємо кластер (видалить всі Docker-контейнери вузлів)
kind delete cluster --name workshop

# Перевіряємо що кластер видалено
kind get clusters
docker ps | grep workshop
# Нічого не повинно бути

# kubeconfig автоматично очищається від контексту kind-workshop
kubectl config get-contexts
```

---

## Швидка довідка — найчастіші команди

```bash
# --- Кластер ---
kind create cluster --name workshop --config k8s/00-cluster/kind-config.yaml
kind delete cluster --name workshop
kubectl config current-context

# --- Pod'и ---
kubectl get pods
kubectl get pods -o wide          # з IP і вузлом
kubectl get pods --watch          # в реальному часі
kubectl describe pod <name>       # детально + Events
kubectl logs <name> -f            # логи в реальному часі
kubectl exec -it <name> -- sh    # зайти всередину
kubectl delete pod <name>

# --- Deployment ---
kubectl get deployments
kubectl describe deployment <name>
kubectl rollout status deployment <name>
kubectl rollout history deployment <name>
kubectl rollout undo deployment <name>
kubectl scale deployment <name> --replicas=<n>
kubectl set image deployment/<name> <container>=<image>

# --- Services ---
kubectl get services
kubectl get endpoints
kubectl describe service <name>

# --- Діагностика ---
kubectl get events --sort-by='.lastTimestamp'
kubectl get pods -A              # всі namespace
kubectl apply -f <file> --dry-run=client  # перевірка без застосування
```
