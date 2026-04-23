# Урок 1: Від контейнерів до Pod'ів — Народження кластеру

> **Рівень:** Абсолютний початківець  
> **Тривалість:** ~60 хвилин  
> **Що потрібно:** Docker Desktop, термінал  
> **Що отримаєш:** Запущений Kubernetes-кластер і перший Pod

---

## Зміст

1. [Чому взагалі виник Kubernetes?](#1-чому-взагалі-виник-kubernetes)
2. [Архітектура Kubernetes — як це влаштовано всередині](#2-архітектура-kubernetes)
3. [Наш інструментарій: kind, kubectl, helm](#3-наш-інструментарій)
4. [Встановлення та перевірка середовища](#4-встановлення-середовища)
5. [Перший кластер: що таке kind-config.yaml](#5-перший-кластер)
6. [Pod — найменша одиниця Kubernetes](#6-pod--найменша-одиниця)
7. [Практика: створюємо перший Pod](#7-практика-перший-pod)
8. [🎯 ДЕМО: Pod без контролера не воскресає](#8-демо-pod-без-контролера)
9. [Типові помилки початківців](#9-типові-помилки)
10. [Підсумок і вправи](#10-підсумок-і-вправи)

---

## 1. Чому взагалі виник Kubernetes?

### Проблема: від монолітів до мікросервісів

Уяви, що ти розробляєш інтернет-магазин. Спочатку це один великий додаток:
- приймає замовлення
- рахує платежі
- надсилає листи
- показує каталог товарів

Все це — один процес, один сервер. Якщо сервер падає — падає все. Якщо потрібно більше потужності — треба купувати дорожчий сервер (вертикальне масштабування).

З часом команди починають розбивати такий додаток на **мікросервіси** — маленькі незалежні програми, кожна з яких відповідає за свою задачу. Тоді:

```
[Каталог товарів]  [Кошик]  [Платежі]  [Пошта]  [Аналітика]
```

Кожен сервіс можна масштабувати окремо. Якщо в "Чорну п'ятницю" навантаження на каталог зростає — масштабуємо тільки його.

### Контейнери вирішують проблему "у мене працює"

**Контейнер** — це ізольоване середовище для запуску програми. Він містить:
- Код програми
- Всі залежності (бібліотеки, .NET runtime)
- Конфігурацію середовища

```
┌─────────────────────────┐
│      Контейнер          │
│  ┌───────────────────┐  │
│  │   Ваш додаток     │  │
│  ├───────────────────┤  │
│  │  .NET 9 Runtime   │  │
│  ├───────────────────┤  │
│  │ Linux бібліотеки  │  │
│  └───────────────────┘  │
│                         │
│  Ізольована файлова     │
│  система, мережа, PID   │
└─────────────────────────┘
```

Docker — найпопулярніший інструмент для роботи з контейнерами. Але сам по собі Docker не вирішує питання:
- Що робити якщо контейнер впав?
- Як розподілити 100 контейнерів між 10 серверами?
- Як оновити 50 копій сервісу без простою?
- Як передати секретні паролі в контейнер?

### Kubernetes: оркестрація контейнерів

**Kubernetes** (скорочено K8s) — це система управління контейнерами. Вона відповідає на всі питання вище:

| Проблема | Рішення K8s |
|----------|-------------|
| Контейнер впав | Автоматично перезапускає |
| Потрібно більше копій | HorizontalPodAutoscaler |
| Оновлення без простою | Rolling Update |
| Секретні паролі | Secret об'єкти |
| Розподіл по серверах | Scheduler |
| Знайти потрібний сервіс | Service + DNS |

Назва "Kubernetes" — грецьке слово "κυβερνήτης" (кибернетес), що означає **стерничий** або **капітан корабля**. Контейнери — вантаж на кораблі, Kubernetes — капітан, який вирішує де і як розмістити вантаж.

---

## 2. Архітектура Kubernetes

Перш ніж запускати команди, розберемось ЯК Kubernetes влаштований. Це допоможе розуміти що відбувається при кожній команді.

### Загальна картина: Control Plane і Worker Nodes

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Кластер                   │
│                                                         │
│  ┌─────────────────────────────────────┐                │
│  │         Control Plane (Мозок)       │               │
│  │  ┌──────────┐  ┌──────────────────┐ │               │
│  │  │API Server│  │      etcd        │ │               │
│  │  │(вхідні  │  │  (база даних      │ │               │
│  │  │ запити) │  │   кластеру)       │ │               │
│  │  └──────────┘  └──────────────────┘ │               │
│  │  ┌──────────┐  ┌──────────────────┐ │               │
│  │  │Scheduler │  │Controller Manager│ │               │
│  │  │(розподіл │  │(стежить за       │ │               │
│  │  │  Pod'ів) │  │ станом)          │ │               │
│  │  └──────────┘  └──────────────────┘ │               │
│  └─────────────────────────────────────┘               │
│                                                         │
│  ┌──────────────┐    ┌──────────────┐                  │
│  │  Worker Node 1│    │ Worker Node 2│                  │
│  │  ┌─────────┐ │    │ ┌─────────┐ │                  │
│  │  │ kubelet │ │    │ │ kubelet │ │                  │
│  │  └─────────┘ │    │ └─────────┘ │                  │
│  │  ┌─────────┐ │    │ ┌─────────┐ │                  │
│  │  │  Pod A  │ │    │ │  Pod B  │ │                  │
│  │  │  Pod C  │ │    │ │  Pod D  │ │                  │
│  │  └─────────┘ │    │ └─────────┘ │                  │
│  └──────────────┘    └──────────────┘                  │
└─────────────────────────────────────────────────────────┘
```

### Компоненти Control Plane

**API Server (`kube-apiserver`)**  
Єдина точка входу для всіх операцій. Коли ти пишеш `kubectl apply -f pod.yaml`, запит іде саме сюди. API Server перевіряє права доступу, валідує запит і зберігає результат в etcd.

**etcd**  
Розподілена база ключ-значення. Тут зберігається **весь стан кластеру**: які Pod'и існують, які вузли доступні, які Deployment'и запущені. Якщо втратити etcd — втрачаєш весь кластер. Тому в production etcd завжди реплікується (3 або 5 копій).

```
# Що зберігається в etcd (спрощено):
/registry/pods/default/my-pod → { spec: {...}, status: {...} }
/registry/nodes/worker-1     → { conditions: [...], capacity: {...} }
/registry/services/...       → { ... }
```

**Scheduler (`kube-scheduler`)**  
Вирішує НА ЯКОМУ вузлі запустити новий Pod. Аналізує:
- Скільки ресурсів (CPU, RAM) потрібно Pod'у
- Скільки ресурсів вільно на кожному вузлі
- Чи є обмеження (наприклад, "тільки на вузлах з GPU")
- Правила розподілу (намагається не ставити всі Pod'и на один вузол)

**Controller Manager (`kube-controller-manager`)**  
Набір контролерів, кожен з яких стежить за певним типом об'єктів. Наприклад:
- `ReplicaSet Controller` — якщо потрібно 3 Pod'и, але є тільки 2, він створить третій
- `Node Controller` — якщо вузол не відповідає 5 хвилин, позначає Pod'и як "невідомі"
- `Job Controller` — запускає задачі і перевіряє чи завершились вони успішно

### Компоненти Worker Node

**kubelet**  
"Агент" Kubernetes на кожному вузлі. Отримує від API Server список Pod'ів, які повинні працювати на цьому вузлі, і запускає/зупиняє контейнери через Docker/containerd. Постійно звітує про стан Pod'ів назад в API Server.

**kube-proxy**  
Відповідає за мережеві правила на вузлі. Коли ти звертаєшся до Service, саме kube-proxy перенаправляє трафік до потрібного Pod'у.

**Container Runtime**  
Власне той, хто запускає контейнери. Раніше це був Docker, зараз найпопулярніший — **containerd** (що насправді є частиною Docker'а, яку винесли окремо).

### Як відбувається створення Pod'а: покрокова схема

```
kubectl apply -f pod.yaml
        │
        ▼
┌───────────────┐    Записує стан    ┌─────────┐
│  API Server   │ ─────────────────► │  etcd   │
│               │                    └─────────┘
└───────────────┘
        │
        │  Новий Pod з'явився без вузла (unscheduled)
        ▼
┌───────────────┐    Вибирає вузол   ┌─────────────┐
│   Scheduler   │ ─────────────────► │ API Server  │
│               │                    │ (оновлює    │
└───────────────┘                    │ Pod.spec.   │
                                     │ nodeName)   │
                                     └─────────────┘
                                             │
                                             │  kubelet помічає що
                                             │  з'явився Pod для нього
                                             ▼
                                     ┌─────────────┐
                                     │   kubelet   │
                                     │  (Worker 1) │
                                     └─────────────┘
                                             │
                                     ┌───────┴───────┐
                                     ▼               ▼
                               Завантажує       Запускає
                               образ            контейнер
                               (docker pull)    (containerd)
```

---

## 3. Наш інструментарій

### kind — Kubernetes IN Docker

**kind** — інструмент для запуску Kubernetes кластеру локально. Замість реальних серверів, вузли кластеру — це Docker контейнери на твоєму комп'ютері.

```
Твій комп'ютер
└── Docker
    ├── [control-plane] контейнер  ← тут живе API Server, etcd, scheduler
    ├── [worker-1] контейнер       ← тут запускаються твої Pod'и
    └── [worker-2] контейнер       ← тут теж
```

Чому kind, а не minikube чи Docker Desktop K8s?
- **Minikube** — один вузол, складніше симулювати розподіл Pod'ів
- **Docker Desktop K8s** — зручний, але прихований від користувача
- **kind** — прозорий, multi-node, ідеальний для навчання

### kubectl — командний рядок Kubernetes

`kubectl` (вимовляють "кьюб-сіті-ель" або "кьюбектл") — CLI для роботи з кластером. Через нього ти робиш абсолютно все: створюєш об'єкти, дивишся логи, заходиш всередину Pod'ів.

```bash
# Базова структура команд:
kubectl [дія] [тип_об'єкту] [ім'я] [опції]

# Приклади:
kubectl get pods                    # показати всі Pod'и
kubectl describe pod my-pod         # детальна інформація
kubectl delete pod my-pod           # видалити Pod
kubectl apply -f pod.yaml           # застосувати конфігурацію з файлу
kubectl logs my-pod                 # переглянути логи
kubectl exec -it my-pod -- bash     # зайти всередину Pod'у
```

### helm — менеджер пакетів для Kubernetes

**helm** — як apt/npm, але для Kubernetes. Дозволяє пакувати складні K8s-конфігурації у перевикористовувані пакети (Charts). Вивчимо в останньому уроці.

---

## 4. Встановлення середовища

### Перевіримо що вже є

Відкрий термінал і виконай:

```bash
# Перевіряємо Docker
docker --version
# Очікувана відповідь: Docker version 26.x.x, build ...

# Перевіряємо що Docker daemon запущено
docker ps
# Очікувана відповідь: порожній список або список контейнерів
```

### Встановлення kind

```bash
# macOS через Homebrew:
brew install kind

# Linux:
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Windows (PowerShell як адміністратор):
choco install kind
# або
winget install Kubernetes.kind

# Перевірка:
kind --version
# Очікувана відповідь: kind v0.23.0 go1.21.x ...
```

### Встановлення kubectl

```bash
# macOS:
brew install kubectl

# Linux:
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Windows:
choco install kubernetes-cli
# або
winget install Kubernetes.kubectl

# Перевірка:
kubectl version --client
# Очікувана відповідь: Client Version: v1.29.x
```

### Корисні псевдоніми (заощаджують час)

Додай у `~/.bashrc` або `~/.zshrc`:

```bash
# Скорочення для kubectl
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgd='kubectl get deployments'
alias kd='kubectl describe'
alias kdel='kubectl delete'

# Автодоповнення для kubectl
source <(kubectl completion bash)
# або для zsh:
source <(kubectl completion zsh)
```

---

## 5. Перший кластер

### Що таке kind-config.yaml?

Перш ніж створювати кластер, потрібно описати його конфігурацію. Kubernetes, як і будь-яка система K8s, конфігурується через YAML-файли.

**YAML** (YAML Ain't Markup Language) — формат серіалізації даних. Якщо ти знайомий з JSON, YAML — це те саме, але читабельніше:

```yaml
# YAML:                    # JSON еквівалент:
name: weather-api           # { "name": "weather-api",
version: 1                  #   "version": 1,
tags:                       #   "tags": ["web", "api"]
  - web                     # }
  - api
```

**Важливо:** В YAML відступи мають значення! Використовуй пробіли (не Tab).

### Розбір kind-config.yaml

Відкрий файл `k8s/00-cluster/kind-config.yaml`:

```yaml
kind: Cluster              # Тип об'єкту — ми описуємо кластер
apiVersion: kind.x-k8s.io/v1alpha4  # Версія API kind
```

Кожен YAML-файл в Kubernetes (і kind) починається з двох полів:
- `kind` — що саме ми описуємо (Cluster, Pod, Deployment...)
- `apiVersion` — яку версію API використовуємо

```yaml
nodes:
  - role: control-plane    # Перший вузол — control plane
```

`nodes` — список вузлів кластеру. В нас буде:
- 1 control-plane — "мозок" кластеру
- 2 worker nodes — де запускаються наші Pod'и

```yaml
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
```

`extraPortMappings` — пробрасування портів з Docker контейнера (вузла) на наш комп'ютер. Це потрібно для Ingress (урок 9), щоб ми могли звертатись до додатку через localhost.

### Створення кластеру

```bash
# Переходимо в директорію воркшопу
cd k8s-workshop

# Створюємо кластер з конфігурації
# Ця команда може зайняти 2-3 хвилини — завантажує Docker образи
kind create cluster \
  --name workshop \
  --config k8s/00-cluster/kind-config.yaml

# Очікуваний вивід:
# Creating cluster "workshop" ...
#  ✓ Ensuring node image (kindest/node:v1.29.2) 🖼
#  ✓ Preparing nodes 📦 📦 📦
#  ✓ Writing configuration 📜
#  ✓ Starting control-plane 🕹️
#  ✓ Installing CNI 🔌
#  ✓ Installing StorageClass 💾
#  ✓ Joining worker nodes 🚜
# Set kubectl context to "kind-workshop"
```

### Що відбулось всередині?

```
kind create cluster виконав:
1. Завантажив Docker образ kindest/node:v1.29.2
   (це спеціальний образ з усіма K8s компонентами)

2. Запустив 3 Docker контейнери:
   - workshop-control-plane
   - workshop-worker
   - workshop-worker2

3. Всередині control-plane запустив:
   - etcd
   - kube-apiserver
   - kube-scheduler
   - kube-controller-manager
   - CoreDNS (DNS для Pod'ів)

4. Налаштував kubeconfig (~/.kube/config)
   щоб kubectl знав куди звертатись
```

### Перевірка кластеру

```bash
# Перевіряємо контекст — з яким кластером працюємо
kubectl config current-context
# Виведе: kind-workshop

# Переглядаємо вузли кластеру
kubectl get nodes
# Виведе:
# NAME                     STATUS   ROLES           AGE   VERSION
# workshop-control-plane   Ready    control-plane   2m    v1.29.2
# workshop-worker          Ready    <none>          2m    v1.29.2
# workshop-worker2         Ready    <none>          2m    v1.29.2

# Детальна інформація про вузол
kubectl describe node workshop-worker
# Покаже: CPU, RAM, Pod'и на вузлі, умови (Conditions)

# Переглядаємо системні Pod'и
kubectl get pods --all-namespaces
# або:
kubectl get pods -A
# Виведе всі Pod'и включно з системними (kube-system namespace)
```

### Розуміємо kubeconfig

```bash
# Де зберігається конфігурація kubectl
cat ~/.kube/config
```

Файл `~/.kube/config` містить:
- **clusters** — список кластерів (адреса API Server, сертифікати)
- **users** — credentials для авторизації  
- **contexts** — прив'язка "користувач + кластер"
- **current-context** — активний контекст

```bash
# Якщо маєш кілька кластерів — перемикайся між ними:
kubectl config get-contexts          # список всіх контекстів
kubectl config use-context kind-workshop  # переключитись
```

---

## 6. Pod — найменша одиниця

### Що таке Pod?

**Pod** (від англ. "стручок гороху") — найменший об'єкт, яким Kubernetes управляє. Це обгортка навколо одного або кількох контейнерів.

Чому Pod, а не просто контейнер?

```
┌─────────────────────────────────────────┐
│                   Pod                   │
│  Спільна IP-адреса: 10.244.1.15         │
│  Спільний мережевий стек                │
│  Спільні Volumes (диски)                │
│                                         │
│  ┌──────────────┐   ┌──────────────┐    │
│  │  Контейнер 1 │   │  Контейнер 2 │    │
│  │  (app:8080)  │   │  (sidecar)   │    │
│  │              │   │              │    │
│  │ localhost:   │◄─►│ localhost:   │    │
│  │    8080      │   │    9090      │    │
│  └──────────────┘   └──────────────┘    │
└─────────────────────────────────────────┘
```

Контейнери в одному Pod'і:
- Мають **спільну IP-адресу** — спілкуються через `localhost`
- Мають **доступ до спільних дисків** (Volumes)
- Запускаються і зупиняються **разом**
- Завжди розміщуються **на одному вузлі**

### Коли потрібен Pod з кількома контейнерами?

Це так звані **sidecar патерни**:
- **Logging sidecar** — основний контейнер пише логи у файл, sidecar читає і відправляє в Elasticsearch
- **Proxy sidecar** — Envoy/Istio проксі для service mesh
- **Init containers** — виконуються ДО старту основного контейнера (наприклад, міграції БД)

У більшості випадків Pod має **один контейнер** — це найпростіший варіант.

### Структура pod.yaml: кожне поле з поясненням

```yaml
apiVersion: v1   # Pod живе в основному API (не apps/v1)
kind: Pod        # Тип об'єкту
```

**Чому `v1`, а не `apps/v1`?**  
Kubernetes API розділений на групи. Основні об'єкти (Pod, Service, ConfigMap) — в групі `v1`. Більш складні (Deployment, StatefulSet) — в `apps/v1`. Це дозволяє K8s розвивати різні частини API незалежно.

```yaml
metadata:
  name: weather-pod    # Ім'я Pod'у — унікальне в namespace
  namespace: default   # Простір імен
  labels:              # Мітки — довільні ключ:значення
    app: weather-api
    version: "1.0"
```

**Labels (мітки)** — дуже важлива концепція. Це ключ-значення пари, які ти сам придумуєш. Вони використовуються для:
- Пошуку об'єктів (`kubectl get pods -l app=weather-api`)
- Service selector — сервіс знаходить свої Pod'и за мітками
- Визначення цільової групи для HPA

```yaml
spec:              # Специфікація — бажаний стан
  containers:
    - name: weather-api       # Ім'я контейнера
      image: nginx:alpine     # Docker образ (registry/image:tag)
```

**image** — це те саме що в `docker run`. Kubernetes за замовчуванням шукає образ на Docker Hub. Для локальних образів потрібно явно завантажити у kind.

```yaml
      ports:
        - containerPort: 80   # Порт, який слухає процес всередині
          name: http
```

**Важливо:** `containerPort` — це лише документація, вона нічого не відкриває. Процес всередині контейнера сам визначає на якому порті слухати. `containerPort` просто інформує людей і інструменти.

```yaml
      resources:
        requests:
          memory: "64Mi"   # Мінімальна гарантія RAM
          cpu: "50m"       # 50 мілікорів = 0.05 CPU
        limits:
          memory: "128Mi"  # Максимум RAM (перевищення → OOMKilled)
          cpu: "100m"      # Максимум CPU (перевищення → throttling)
```

**requests vs limits:**
- `requests` — Scheduler дивиться на requests щоб вирішити куди поставити Pod. Гарантований мінімум.
- `limits` — жорстка стеля. RAM: перевищення → процес вбивається (OOMKilled). CPU: перевищення → throttling (уповільнення, не смерть).

**Одиниці CPU:**
- `1` = 1 ядро процесора = 1000m
- `100m` = 0.1 ядра
- `50m` = 0.05 ядра

**Одиниці пам'яті:**
- `64Mi` = 64 мебібайти (2^26 байт) ≈ 67 МБ
- `64M` = 64 мегабайти (64 * 10^6 байт) — різниця невелика, але є

```yaml
      restartPolicy: Never
```

**restartPolicy** — що робити якщо контейнер завершив роботу:
- `Always` — завжди перезапускати (для серверів, демонів)
- `OnFailure` — перезапускати тільки при помилці (для Job'ів)
- `Never` — ніколи не перезапускати

Для нашого **ДЕМО** ми використаємо `Never`, щоб показати що "голий" Pod не відновлюється.

---

## 7. Практика: перший Pod

### Крок 1: Застосовуємо конфігурацію

```bash
# Застосовуємо YAML файл — kubectl передає його в API Server
kubectl apply -f k8s/01-pod/pod.yaml

# Виведе: pod/weather-pod created
```

**`kubectl apply` vs `kubectl create`:**
- `kubectl create` — тільки для нових об'єктів, помилка якщо вже існує
- `kubectl apply` — create OR update. Можна запускати скільки завгодно разів — ідемпотентна операція. **Завжди використовуй apply.**

### Крок 2: Перевіряємо стан

```bash
# Список Pod'ів у namespace default
kubectl get pods

# Виведе:
# NAME          READY   STATUS              RESTARTS   AGE
# weather-pod   0/1     ContainerCreating   0          5s

# Через кілька секунд:
# NAME          READY   STATUS    RESTARTS   AGE
# weather-pod   1/1     Running   0          15s
```

**Розшифровка стовпців:**
- `READY` — `1/1` означає "1 з 1 контейнерів готові"
- `STATUS` — поточний стан Pod'у
- `RESTARTS` — скільки разів контейнер перезапускався
- `AGE` — як давно створено Pod

**Можливі статуси Pod'у:**
```
Pending          → Pod прийнятий, але ще не запущений
                   (завантажується образ або чекає на вузол)
ContainerCreating → образ завантажено, контейнер створюється
Running          → Pod запущений і працює
Succeeded        → всі контейнери завершились успішно (для Job)
Failed           → контейнер завершився з помилкою
CrashLoopBackOff → контейнер постійно падає і перезапускається
ImagePullBackOff → не вдається завантажити образ
Terminating      → Pod видаляється
```

### Крок 3: Детальна інформація

```bash
# Детальна інформація про Pod
kubectl describe pod weather-pod
```

`describe` показує:
- Мітки і анотації
- Статус і умови (Conditions)
- На якому вузлі запущено
- Контейнери і їхній стан
- **Events** — що відбувалось з Pod'ом (дуже корисно для дебагінгу!)

```
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  30s   default-scheduler  Successfully assigned default/weather-pod to workshop-worker
  Normal  Pulling    29s   kubelet            Pulling image "nginx:alpine"
  Normal  Pulled     20s   kubelet            Successfully pulled image "nginx:alpine"
  Normal  Created    20s   kubelet            Created container weather-api
  Normal  Started    20s   kubelet            Started container weather-api
```

Читаємо Events знизу вгору або зверху вниз — вони хронологічні. При проблемах тут буде написано що пішло не так.

### Крок 4: Переглядаємо логи

```bash
# Логи Pod'у (останні записи)
kubectl logs weather-pod

# Слідкуємо за логами в реальному часі
kubectl logs weather-pod --follow
# або:
kubectl logs weather-pod -f

# Логи конкретного контейнера (якщо в Pod'і кілька)
kubectl logs weather-pod -c weather-api

# Логи попереднього запуску (якщо контейнер перезапускався)
kubectl logs weather-pod --previous
```

### Крок 5: Заходимо всередину Pod'у

```bash
# Виконати команду в контейнері
kubectl exec weather-pod -- ls /

# Інтерактивна сесія (якщо є bash)
kubectl exec -it weather-pod -- bash
# або з sh (для alpine образів):
kubectl exec -it weather-pod -- sh

# Всередині контейнера можна:
ls /                       # переглянути файли
env                        # змінні середовища
curl localhost             # перевірити додаток
cat /etc/os-release        # яка ОС
exit                       # вийти
```

**Прапорці `-it`:**
- `-i` (interactive) — передає stdin
- `-t` (tty) — виділяє псевдотермінал

Без них команда виконається і завершиться без інтерактивності.

### Крок 6: Корисні варіанти kubectl get

```bash
# Показати IP-адресу і вузол
kubectl get pods -o wide

# Виведе:
# NAME          READY   STATUS    RESTARTS   AGE   IP            NODE
# weather-pod   1/1     Running   0          5m    10.244.1.5    workshop-worker

# Показати в форматі YAML (поточний стан)
kubectl get pod weather-pod -o yaml

# Показати в форматі JSON
kubectl get pod weather-pod -o json

# Витягнути конкретне поле через jsonpath
kubectl get pod weather-pod -o jsonpath='{.status.podIP}'

# Стежити за змінами в реальному часі
kubectl get pods --watch
# або:
kubectl get pods -w
```

---

## 8. 🎯 ДЕМО: Pod без контролера

### Чого ми хочемо довести

Kubernetes часто рекламують як "самовідновлювальну" систему. Але це правда лише частково — Kubernetes відновлює Pod'и тільки якщо є **контролер**, який за ними стежить (наприклад, Deployment або ReplicaSet).

"Голий" Pod без контролера — як найманий працівник без роботодавця. Якщо щось трапилось — нікому замовити нового.

### Крок 1: Переконуємось що Pod працює

```bash
# Дивимось статус нашого Pod'у
kubectl get pods
# weather-pod   1/1     Running   0          10m
```

### Крок 2: Видаляємо Pod

```bash
# 🎯 ДЕМО МОМЕНТ: Видаляємо Pod
kubectl delete pod weather-pod

# Виведе: pod "weather-pod" deleted
```

### Крок 3: Перевіряємо — Pod не відновився

```bash
# Перевіряємо список Pod'ів
kubectl get pods

# Виведе:
# No resources found in default namespace.
# (або порожній список)
```

**Pod зник і не повернувся.** Ніхто не знає що він повинен існувати. Ніхто не намагається його відновити.

### Крок 4: Порівняння — що станеться у Deployment (спойлер)

```bash
# У наступному уроці ми побачимо:
kubectl delete pod weather-api-7d6b8f9c4-xk2pt   # Pod від Deployment
# Kubernetes одразу створить новий Pod замість видаленого!
# Бо ReplicaSet Controller каже: "має бути 3 Pod'и, а є 2 — виправляємо"
```

### Коли використовувати "голий" Pod?

**Майже ніколи.** Голі Pod'и використовують тільки для:
- Навчання та розуміння концепцій (як зараз)
- Одноразових дебаг-Pod'ів (`kubectl run debug-pod --image=busybox -it --rm -- sh`)
- Деяких системних компонентів, які управляються поза K8s

**У production завжди використовуй:**
- `Deployment` — для stateless сервісів (API, веб)
- `StatefulSet` — для stateful сервісів (БД, черги)
- `DaemonSet` — для агентів на кожному вузлі (моніторинг)
- `Job`/`CronJob` — для разових або регулярних задач

---

## 9. Типові помилки початківців

### ❌ Помилка 1: ImagePullBackOff

```
NAME          READY   STATUS             RESTARTS   AGE
weather-pod   0/1     ImagePullBackOff   0          2m
```

**Причина:** Kubernetes не може завантажити Docker образ.

**Як діагностувати:**
```bash
kubectl describe pod weather-pod
# В секції Events побачимо:
# Failed to pull image "weather-api:1.0": ... not found
```

**Рішення:**
```bash
# Перевір ім'я образу — можливо опечатка
# Для локальних образів з kind — треба явно завантажити:
kind load docker-image weather-api:1.0 --name workshop
```

### ❌ Помилка 2: Pending — не вистачає ресурсів

```
NAME          READY   STATUS    RESTARTS   AGE
weather-pod   0/1     Pending   0          5m
```

**Причина:** Scheduler не може знайти вузол з достатніми ресурсами.

```bash
kubectl describe pod weather-pod
# Events:
# Warning  FailedScheduling  5m  default-scheduler
#   0/2 nodes are available: 2 Insufficient memory
```

**Рішення:** Зменши `resources.requests.memory` або видали інші Pod'и.

### ❌ Помилка 3: CrashLoopBackOff

```
NAME          READY   STATUS             RESTARTS   AGE
weather-pod   0/1     CrashLoopBackOff   5          3m
```

**Причина:** Контейнер запускається, але одразу падає.

```bash
# Дивись логи:
kubectl logs weather-pod
# Або логи попереднього запуску:
kubectl logs weather-pod --previous
```

**Затримка перезапусків (`BackOff`):**
```
1-й рестарт:   10 секунд очікування
2-й рестарт:   20 секунд
3-й рестарт:   40 секунд
...максимум:  5 хвилин
```

Kubernetes спеціально уповільнює перезапуски щоб не перевантажувати систему.

### ❌ Помилка 4: Забути namespace

```bash
kubectl get pods
# No resources found in default namespace.

# Але Pod існує в іншому namespace!
kubectl get pods --all-namespaces   # Показати всі namespace
kubectl get pods -n kube-system     # Конкретний namespace
```

### ❌ Помилка 5: Неправильні відступи в YAML

```yaml
# НЕПРАВИЛЬНО — Tab замість пробілів:
spec:
	containers:    # ← Tab викличе помилку

# ПРАВИЛЬНО — 2 пробіли:
spec:
  containers:    # ← 2 пробіли
```

Перевірка YAML перед застосуванням:
```bash
# Перевірити синтаксис без застосування:
kubectl apply -f pod.yaml --dry-run=client

# Детальніша перевірка (також перевіряє через API Server):
kubectl apply -f pod.yaml --dry-run=server
```

---

## 10. Підсумок і вправи

### Ключові висновки уроку

1. **Kubernetes вирішує реальні проблеми** — управління контейнерами в масштабі, автоматичне відновлення, масштабування, оновлення без простою.

2. **Control Plane — мозок, Worker Nodes — руки** — API Server приймає всі запити, etcd зберігає стан, Scheduler вирішує де запустити, Controller Manager підтримує бажаний стан.

3. **Pod — найменша одиниця, але не вживається наодинці** — у реальних проектах завжди є контролер (Deployment, StatefulSet...) який стежить за Pod'ами і відновлює їх при потребі.

### Команди уроку — шпаргалка

```bash
# Кластер
kind create cluster --name workshop --config kind-config.yaml
kind delete cluster --name workshop
kubectl config current-context

# Pod'и
kubectl apply -f pod.yaml          # Створити/оновити
kubectl get pods                   # Список
kubectl get pods -o wide           # З IP і вузлом
kubectl describe pod <name>        # Детально
kubectl logs <name>                # Логи
kubectl logs <name> -f             # Логи в реальному часі
kubectl exec -it <name> -- sh      # Зайти всередину
kubectl delete pod <name>          # Видалити

# Дебагінг
kubectl get events                 # Події кластеру
kubectl get pods --watch           # Стежити за змінами
kubectl apply -f pod.yaml --dry-run=client  # Перевірка без застосування
```

### Вправи для самостійної роботи

**Вправа 1 — Легка:**  
Створи Pod з образом `busybox` і виконай всередині нього команду `echo "Hello Kubernetes"`. Перевір що результат видно в логах.

**Вправа 2 — Середня:**  
Додай до Pod'у другий контейнер з образом `alpine`. Переконайся що обидва контейнери запустились (`READY: 2/2`). Зайди всередину кожного контейнера окремо.

**Вправа 3 — Складна:**  
Знайди в `kubectl describe pod` значення поля `Node`. Опиши цей вузол (`kubectl describe node <name>`). Знайди в описі вузла список всіх Pod'ів що на ньому запущені.

**Питання для роздумів:**  
- Якщо `restartPolicy: Always`, але контейнер одразу падає — що відбудеться?
- Чому IP-адреса Pod'у змінюється при кожному перестворенні? Як це вирішити?
- Навіщо потрібні Labels якщо є Name?

---

## Наступний урок

**Урок 2: Deployment — керований відряд Pod'ів**

Ми побачили що голий Pod — ненадійний. В наступному уроці:
- Що таке ReplicaSet і навіщо він потрібен
- Як Deployment управляє ReplicaSet'ами
- Живе ДЕМО: Kill Pod → Pod воскресає
- Стратегії оновлення (RollingUpdate vs Recreate)

---

*Урок підготовлено для Kubernetes Workshop. Версія K8s: 1.29+*
