# Урок 6: Resources — Не дай Pod'у з'їсти весь вузол

> **Рівень:** Початківець (потрібні Уроки 1-5)
> **Тривалість:** ~70 хвилин
> **Що потрібно:** Кластер з Уроку 1
> **Що отримаєш:** Правильно виставлені resources, розуміння QoS класів, live демо OOMKilled і CPU throttling

---

## Зміст

1. [Проблема: "шумний сусід" і OOMKilled в production](#1-проблема)
2. [Як Kubernetes рахує CPU](#2-cpu)
3. [Як Kubernetes рахує пам'ять](#3-память)
4. [Requests vs Limits: різниця і наслідки](#4-requests-vs-limits)
5. [Scheduler і requests: як Pod потрапляє на вузол](#5-scheduler-і-requests)
6. [QoS класи: що відбувається під тиском](#6-qos-класи)
7. [LimitRange: дефолти для namespace](#7-limitrange)
8. [ResourceQuota: загальні ліміти для namespace](#8-resourcequota)
9. [Kubectl top: моніторинг споживання ресурсів](#9-kubectl-top)
10. [Практика: правильні resources для WeatherApi](#10-практика)
11. [ДЕМО: OOMKilled — Pod вбивається за перевищення пам'яті](#11-демо-oomkilled)
12. [ДЕМО: CPU throttling — Pod уповільнюється, але не вмирає](#12-демо-cpu-throttling)
13. [Типові помилки](#13-типові-помилки)
14. [Підсумок і вправи](#14-підсумок-і-вправи)

---

## 1. Проблема

### "Шумний сусід" без обмежень

Уявімо production кластер без налаштованих resources. На вузлі запущено кілька Pod'ів:

```
Worker Node (8 CPU, 16 GB RAM)
├── weather-api       ← твій сервіс
├── payment-service   ← критичний платіжний сервіс
└── analytics-job     ← фоновий аналіз даних
```

Вночі запускається analytics-job і починає обробляти великий датасет. Він займає 14 GB RAM і 7 CPU ядер — нікому не заважав, ніяких лімітів немає.

```
t=02:00  analytics-job їсть 14 GB RAM, 7 CPU
t=02:01  weather-api намагається виділити пам'ять → не вистачає
t=02:01  Linux OOM killer вбиває weather-api (найбільший "апетит" серед решти)
t=02:01  payment-service почав отримувати HTTP 503 бо weather-api мертвий
t=02:01  Kubernetes запускає новий weather-api Pod
t=02:03  Новий Pod теж вбивається — пам'яті все ще немає
t=03:30  analytics-job закінчив роботу, все повертається в норму
t=03:30  SLA порушено: 1.5 години downtime платіжного сервісу
```

Ось чому resources — це не опція, а обов'язкова практика.

### Другий сценарій: Pod зайшов у нескінченний цикл

```python
# Баг в коді: нескінченна рекурсія або memory leak
while True:
    cache.append(fetch_data())  # пам'ять росте нескінченно
```

Без `limits.memory` Pod буде їсти пам'ять до тих пір поки:
- Linux OOM killer не вб'є процес (непередбачуваний момент)
- або вузол не вичерпає всю пам'ять і не обвалиться

З `limits.memory: 256Mi` — Pod вб'ється одразу при перевищенні 256 Mi. Чітко, передбачувано, без зачіпання сусідів.

### Що нам потрібно

Два поняття:
- `requests` — мінімум ресурсів який **гарантується** Pod'у
- `limits` — максимум ресурсів який Pod **не може перевищити**

---

## 2. CPU

### Одиниці вимірювання CPU

Kubernetes вимірює CPU в **ядрах** або **мілікорах**:

```
1    = 1 ядро процесора (1 vCPU у хмарі)
0.5  = 0.5 ядра (половина)
500m = 500 мілікорів = 0.5 ядра (те саме)
100m = 100 мілікорів = 0.1 ядра (1/10 ядра)
1m   = 1 мілікор = 0.001 ядра (найменша одиниця)
```

Практично:
- `50m` — майже idle (фоновий процес, що нічого не робить)
- `100m` — легке навантаження (простий web server без трафіку)
- `250m` — помірне (обробка кількох запитів на секунду)
- `500m` — серйозне (активне навантаження)
- `1` — повне ядро (CPU-інтенсивна задача)

### Що відбувається при перевищенні CPU limits

CPU — **compressible resource** (стискуваний ресурс). Якщо Pod намагається використати більше CPU ніж `limits.cpu`:

- Процес **не вбивається** (на відміну від пам'яті)
- Ядро Linux **throttle** процес: призупиняє виконання, даючи CPU іншим
- Процес працює **повільніше**, але не падає

```
Вузол: 2 CPU
Pod A: limits.cpu=500m, зараз використовує 700m

Ядро Linux:
  Дає Pod A 500ms CPU-часу з кожної секунди
  Решту 200ms "відбирає" (Pod A заморожується)
  Pod A виконується, але з затримками: запити, що займали 50ms, тепер 70ms
```

### Як перевірити CPU throttling

```bash
# Зайти в контейнер і подивитись статистику cgroup:
kubectl exec -it <pod-name> -- cat /sys/fs/cgroup/cpu/cpu.stat
# throttled_time N  ← час в наносекундах, протягом якого Pod був throttled
```

Або через метрики (якщо встановлений Prometheus):
```
container_cpu_cfs_throttled_seconds_total
```

Якщо `throttled_time` постійно зростає — limits.cpu занадто низький.

---

## 3. Пам'ять

### Одиниці вимірювання пам'яті

```
Ki  = кibibyte = 1024 байт     (kibibytes — 2^10)
Mi  = mebibyte = 1024 Ki       (mebibytes — 2^20)  ← найчастіше
Gi  = gibibyte = 1024 Mi       (gibibytes — 2^30)

K   = kilobyte = 1000 байт     (десяткові, рідко)
M   = megabyte = 1000 K
G   = gigabyte = 1000 M

128Mi ≈ 134 MB   (134.2 MB точно)
1Gi   ≈ 1.07 GB  (1.074 GB точно)
```

У Kubernetes прийнято використовувати `Mi` і `Gi`. Різниця між Mi і M невелика (~7%), але краще бути точним.

### Що відбувається при перевищенні Memory limits

Пам'ять — **incompressible resource** (нестискуваний ресурс). Ядро Linux не може "відібрати" вже виділену пам'ять у процесу без наслідків.

Тому при перевищенні `limits.memory`:

```
Pod намагається виділити пам'ять > limits.memory
        │
        ▼
Linux kernel OOM killer
        │
        ▼
Процес вбивається сигналом SIGKILL
exit code: 137 (128 + SIGKILL=9)
        │
        ▼
Kubernetes:
  READY: 0/1
  STATUS: OOMKilled
  RESTARTS: +1
```

**Exit code 137** — завжди ознака OOMKilled. Запам'ятай це число.

```bash
# Побачити OOMKilled:
kubectl get pods
# NAME           READY   STATUS      RESTARTS
# memory-hog     0/1     OOMKilled   3

# Подробиці:
kubectl describe pod memory-hog
# Last State: Terminated
#   Reason: OOMKilled
#   Exit Code: 137
```

### Linux OOM Killer vs Kubernetes OOM

Є два різних OOM механізми:

**1. CGroup OOM (Kubernetes)** — спрацьовує коли Pod перевищує `limits.memory`. Вбиває тільки контейнер що порушив ліміт. Kubernetes бачить це і показує `OOMKilled`.

**2. System OOM Killer** — спрацьовує коли весь вузол вичерпав пам'ять. Вбиває процеси за алгоритмом "найбільший або найнижчий пріоритет". Kubernetes може не встигнути відреагувати. Pod'и типу BestEffort отримують OOM score найвищим — вбиваються першими.

---

## 4. Requests vs Limits

### Схема взаємодії

```
                    Requests                          Limits
                    (мінімум)                         (максимум)
                       │                                 │
          ┌────────────┴───────────────┐    ┌────────────┴────────────┐
          │                           │    │                         │
  Scheduler використовує         Pod гарантовано   Pod не може
  для розміщення Pod'у на        отримає цей мінімум  перевищити це
  вузол (читай секцію 5)         ресурсів             значення
                                      │                         │
                              ┌───────┴──────┐        ┌────────┴───────┐
                              │              │        │                │
                           CPU: можна     Memory:   CPU:           Memory:
                           тимчасово      завжди    throttling     OOMKilled
                           буrstuvati     гарантія  (уповільнення) (смерть)
```

### Як вибрати значення

```
Правило 1: requests — реальне споживання в idle + невеликий запас
Правило 2: limits — пік споживання + 20-30%
Правило 3: limits.memory >= requests.memory (інакше K8s відхилить)
Правило 4: limits.cpu може бути значно більше requests.cpu (CPU-burst OK)
Правило 5: limits.memory не більше ніж в 2-3x від requests.memory (для QoS)
```

### Як дізнатись реальне споживання

```bash
# Поточне споживання Pod'ів (потребує metrics-server, секція 9):
kubectl top pods

# Поточне споживання по вузлах:
kubectl top nodes

# Споживання одного Pod'у:
kubectl top pod weather-api-xxx-xxx
```

Якщо metrics-server ще не встановлено — можна зайти всередину контейнера:

```bash
kubectl exec -it <pod-name> -- cat /sys/fs/cgroup/memory/memory.usage_in_bytes
# Виведе поточне споживання в байтах
```

---

## 5. Scheduler і Requests

### Як Scheduler вибирає вузол

Коли потрібно запустити Pod, Scheduler проходить через два кроки:

**Крок 1: Filtering (Фільтрація)** — виключаємо вузли які точно не підходять:
- Не вистачає CPU (allocatable CPU - вже зарезервовано < requests.cpu Pod'у)
- Не вистачає пам'яті
- Є taint які Pod не tolerate
- Немає потрібних labels (nodeSelector, affinity)

**Крок 2: Scoring (Оцінка)** — з тих що лишились, вибираємо найкращий:
- Найбільше вільних ресурсів (LeastResourceAllocation)
- Найменше Pod'ів (LeastAllocatedPriority)
- Інші критерії

Ключовий момент: **Scheduler дивиться на requests, не на limits і не на реальне споживання**.

```
Вузол: 4 CPU, 8 GB RAM
  weather-api: requests.cpu=100m, requests.memory=128Mi
  worker-job:  requests.cpu=2000m, requests.memory=4Gi
  analytics:   requests.cpu=1500m, requests.memory=3Gi
  
Вже зарезервовано: 3600m CPU, 7.125 Gi RAM

Новий Pod: requests.cpu=500m, requests.memory=512Mi
  Scheduler: 4000m - 3600m = 400m вільно
  400m < 500m → ВУЗОЛ НЕ ПІДХОДИТЬ!
  Pod зависає в Pending.
  
Але реально:
  weather-api: використовує 50m CPU, 80Mi RAM (набагато менше requests)
  Фізично на вузлі є місце — але Scheduler не знає і не може покладатись на це.
```

Саме тому правильні requests — це не просто "красивий YAML", а реальна стратегія розміщення.

### Overcommitment

Якщо виставити requests менше реального споживання — більше Pod'ів помістяться на вузол (overcommitment). Але це ризиковано: якщо всі Pod'и одночасно попросять пам'ять — виникне тиск і OOM killer почне роботу.

Правило: CPU можна overcommit агресивніше (throttling — не смерть). Memory — обережно.

---

## 6. QoS класи

### Три класи якості обслуговування

Kubernetes автоматично призначає кожному Pod'у **QoS клас** на основі налаштованих resources. Цей клас визначає пріоритет Pod'у при нестачі ресурсів на вузлі.

#### Guaranteed — найвищий пріоритет

**Умова:** У ВСІХ контейнерів Pod'у: `requests.cpu == limits.cpu` І `requests.memory == limits.memory`

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "500m"
  limits:
    memory: "256Mi"   # рівно = requests
    cpu: "500m"       # рівно = requests
```

**Наслідки:**
- Scheduler гарантує що вузол завжди матиме ці ресурси для Pod'у
- При нестачі пам'яті на вузлі — цей Pod **вбивається останнім**
- OOM score: -998 (найнижчий = найменш вірогідно бути вбитим)

Коли використовувати: критичні production сервіси, бази даних, payment сервіси.

#### Burstable — середній пріоритет

**Умова:** Хоча б один контейнер має requests, але requests != limits (або є requests без limits)

```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"   # відрізняється від requests
    cpu: "500m"
```

**Наслідки:**
- Pod може "вибухнути" і тимчасово використати більше ніж requests
- При нестачі пам'яті — вбивається після BestEffort, перед Guaranteed
- OOM score: залежить від того, наскільки Pod перевищив requests

Коли використовувати: більшість звичайних сервісів де трафік непостійний.

#### BestEffort — найнижчий пріоритет

**Умова:** Жодних requests або limits не вказано

```yaml
# Немає секції resources взагалі
containers:
  - name: app
    image: my-app:1.0
```

**Наслідки:**
- Scheduler може поставити Pod будь-куди (немає гарантій)
- При нестачі пам'яті — **вбивається першим**
- OOM score: 1000 (максимальний = першим кандидат на вбивство)

Коли використовувати: тільки для справді некритичних задач (batch jobs, дебаг Pod'и).

### Визначити QoS клас Pod'у

```bash
kubectl get pod <pod-name> -o jsonpath='{.status.qosClass}'
# Виведе: Guaranteed, Burstable або BestEffort

# Або через describe:
kubectl describe pod <pod-name> | grep QoS
# QoS Class: Burstable
```

### Що відбувається при нестачі пам'яті на вузлі (node pressure)

```
Вузол: 8 GB RAM
  Реальне використання зростає до 7.8 GB...

kubelet помічає memory pressure:
  
  1. Евіктить BestEffort Pod'и (OOM score 1000)
     → Pod переноситься на інший вузол
  
  Тиск не знизився:
  
  2. Евіктить Burstable Pod'и що найбільше перевищили requests
     → Pod переноситься на інший вузол
  
  Тиск не знизився (рідкісна ситуація):
  
  3. Евіктить Guaranteed Pod'и (лише якщо більше нічого)
     → Pod переноситься на інший вузол
```

Евікція відрізняється від OOMKill: Pod "виселяється" і Kubernetes запускає його на іншому вузлі. OOMKill — процес вбивається Linux kernel.

---

## 7. LimitRange

### Проблема: Pod без resources

Якщо розробник забув вказати resources в Pod'і:
- Pod стає BestEffort (вбивається першим під тиском)
- Scheduler не може правильно розмістити Pod
- Один Pod може з'їсти весь вузол

### LimitRange — дефолти для namespace

**LimitRange** — об'єкт K8s що задає дефолтні та мінімальні/максимальні значення resources для всіх Pod'ів у namespace.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: default
spec:
  limits:
    - type: Container
      default:           # якщо limits не вказано — підставляє ці значення
        cpu: "500m"
        memory: "256Mi"
      defaultRequest:    # якщо requests не вказано — підставляє ці значення
        cpu: "100m"
        memory: "128Mi"
      max:               # Pod не може попросити більше ніж це
        cpu: "2"
        memory: "2Gi"
      min:               # Pod не може попросити менше ніж це
        cpu: "50m"
        memory: "64Mi"
```

Якщо Pod створюється без resources — LimitRange автоматично підставляє `default` і `defaultRequest`.

```bash
# Переглянути LimitRange в namespace:
kubectl get limitrange
kubectl describe limitrange default-limits
```

**Важливо:** LimitRange застосовується тільки до нових Pod'ів. Існуючі Pod'и він не змінює.

---

## 8. ResourceQuota

### Проблема: один namespace з'їдає весь кластер

У великих організаціях кілька команд використовують один кластер, але різні namespaces. Без обмежень одна команда може запустити 100 Pod'ів і зайняти всі ресурси.

### ResourceQuota — обмеження для namespace в цілому

**ResourceQuota** обмежує **загальну** кількість ресурсів що можуть бути використані в namespace.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: default
spec:
  hard:
    # Обмеження CPU
    requests.cpu: "4"       # всі Pod'и разом не можуть попросити більше 4 CPU
    limits.cpu: "8"         # загальний ліміт CPU
    
    # Обмеження пам'яті
    requests.memory: "8Gi"
    limits.memory: "16Gi"
    
    # Обмеження кількості об'єктів
    pods: "20"              # не більше 20 Pod'ів
    services: "10"
    persistentvolumeclaims: "5"
    
    # Обмеження Storage
    requests.storage: "50Gi"
```

Якщо попробувати створити Pod що перевищить квоту:

```bash
kubectl apply -f pod.yaml
# Error from server (Forbidden): pods "my-pod" is forbidden:
# exceeded quota: team-quota,
# requested: limits.memory=512Mi,
# used: limits.memory=15.8Gi,
# limited: limits.memory=16Gi
```

```bash
# Поточний стан квоти:
kubectl get resourcequota
kubectl describe resourcequota team-quota
# Used   Hard
# pods   18     20    ← 18 з 20 використано
```

### LimitRange vs ResourceQuota

| | LimitRange | ResourceQuota |
|--|-----------|---------------|
| Що контролює | Ресурси одного Pod'у/Container | Ресурси namespace в цілому |
| Задає дефолти | Так | Ні |
| Блокує | Pod що порушує min/max | Pod/об'єкт що перевищує загальну квоту |
| Рівень | Container або Pod | Namespace |

---

## 9. Kubectl top

### Що таке Metrics Server

`kubectl top` — команда для перегляду поточного споживання ресурсів. Вона потребує **Metrics Server** — компонент що збирає метрики з kubelet кожного вузла.

В kind Metrics Server не встановлений за замовчуванням.

### Встановлення Metrics Server в kind

```bash
# Встановити через kubectl apply:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# kind використовує self-signed TLS — потрібно додати прапорець:
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Чекаємо поки Metrics Server запуститься:
kubectl rollout status deployment metrics-server -n kube-system
```

### Команди kubectl top

```bash
# Споживання по Pod'ах:
kubectl top pods
# NAME                           CPU(cores)   MEMORY(bytes)
# weather-api-7d6b8f9c4-xk2pt   5m           45Mi
# weather-api-7d6b8f9c4-9nqr7   3m           43Mi

# Споживання по вузлах:
kubectl top nodes
# NAME                     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# workshop-worker          120m         6%     512Mi           32%
# workshop-worker2         89m          4%     489Mi           30%

# Споживання по контейнерах всередині Pod'ів:
kubectl top pods --containers

# Фільтр по мітках:
kubectl top pods -l app=weather-api
```

Метрики оновлюються кожні 15-30 секунд. Це не realtime, але достатньо для загального розуміння.

---

## 10. Практика

### Крок 1: Перевіряємо поточний стан

```bash
kubectl config current-context
# kind-workshop

kubectl get nodes
# Три вузли Ready
```

### Крок 2: Застосовуємо оновлений Deployment

Відкрий `k8s/06-resources/deployment.yaml` і вивчи нові налаштування resources.

Порівняння з попередніми уроками:

| Урок | requests CPU | limits CPU | requests Memory | limits Memory | QoS |
|------|-------------|------------|----------------|--------------|-----|
| 02-05 | 100m | 500m | 128Mi | 256Mi | Burstable |
| **06** | **256Mi** | **256Mi** | **256m** | **256m** | **Guaranteed** |

```bash
kubectl apply -f k8s/06-resources/deployment.yaml
kubectl rollout status deployment weather-api
```

### Крок 3: Перевіряємо QoS клас

```bash
# Отримуємо ім'я одного Pod'у:
POD=$(kubectl get pods -l app=weather-api -o jsonpath='{.items[0].metadata.name}')

# Дивимось QoS клас:
kubectl get pod $POD -o jsonpath='{.status.qosClass}'
# Guaranteed

# Або через describe:
kubectl describe pod $POD | grep "QoS Class"
# QoS Class: Guaranteed
```

### Крок 4: Застосовуємо LimitRange і ResourceQuota

```bash
kubectl apply -f k8s/06-resources/limitrange.yaml
kubectl describe limitrange default-resource-limits

kubectl apply -f k8s/06-resources/resourcequota.yaml
kubectl describe resourcequota workshop-quota
```

### Крок 5: Перевіряємо що Pod без resources отримує дефолти

```bash
# Тимчасовий Pod без resources:
kubectl run test-defaults \
  --image=nginxinc/nginx-unprivileged:alpine \
  --restart=Never

# Дивимось що підставив LimitRange:
kubectl get pod test-defaults -o jsonpath='{.spec.containers[0].resources}'
# Побачимо requests і limits з LimitRange (не те що ми вказали — ми нічого не вказали)

# Видаляємо тестовий Pod:
kubectl delete pod test-defaults
```

### Крок 6: Перевіряємо споживання через kubectl top

```bash
# Якщо metrics-server встановлено:
kubectl top pods -l app=weather-api

# Знайди у виводі різницю між реальним споживанням і requests/limits
```

---

## 11. ДЕМО: OOMKilled

Зараз ми навмисно створимо Pod що перевищить memory limit і спостерігатимемо за OOMKilled.

### Крок 1: Застосовуємо oom-demo Pod

```bash
kubectl apply -f k8s/06-resources/oom-demo.yaml
```

Цей Pod:
- Запускає утиліту `stress`
- Намагається виділити 200MB пам'яті
- Має `limits.memory: 100Mi`
- Результат передбачуваний: OOMKilled

### Крок 2: Спостерігаємо в реальному часі

```bash
# Термінал 1: watch за Pod'ами
kubectl get pods --watch

# Ти побачиш:
# NAME         READY   STATUS              RESTARTS   AGE
# oom-demo     0/1     ContainerCreating   0          2s
# oom-demo     1/1     Running             0          4s     ← Pod запущений
# oom-demo     0/1     OOMKilled           0          6s     ← вбитий!
# oom-demo     0/1     CrashLoopBackOff    1          10s    ← K8s намагається перезапустити
```

`restartPolicy: OnFailure` в маніфесті — тому Pod перезапускається. Але він буде вбитий знову і знову.

### Крок 3: Діагностика OOMKilled

```bash
# Статус Pod'у:
kubectl get pod oom-demo
# NAME       READY   STATUS      RESTARTS   AGE
# oom-demo   0/1     OOMKilled   3          30s

# Детальна інформація:
kubectl describe pod oom-demo
```

У секції `Containers` → `Last State` побачимо:
```
Last State:   Terminated
  Reason:     OOMKilled
  Exit Code:  137
  Started:    Mon, 01 Jan 2026 10:00:05 +0000
  Finished:   Mon, 01 Jan 2026 10:00:07 +0000
```

**Exit Code 137 = 128 + 9 (SIGKILL)** — сигнатура OOMKilled.

### Крок 4: Дивимось Events

```bash
kubectl describe pod oom-demo | grep -A5 Events
# Events:
#   Warning  OOMKilling  12s   kubelet
#     Memory cgroup out of memory: Kill process 1234 (stress)
#     score 1999 or sacrifice child
```

### Крок 5: Порівнюємо behavior — більший ліміт

Щоб побачити що Pod **виживає** при достатньому ліміті:

```bash
# Видаляємо oom-demo:
kubectl delete pod oom-demo

# Запускаємо з достатньою пам'яттю (300Mi > 200Mi що просить stress):
kubectl run no-oom \
  --image=polinux/stress \
  --restart=Never \
  --limits='memory=300Mi,cpu=200m' \
  --requests='memory=100Mi,cpu=100m' \
  -- stress --vm 1 --vm-bytes 200M --vm-hang 30

# Pod працює і не вбивається:
kubectl get pods
# NAME     READY   STATUS    RESTARTS
# no-oom   1/1     Running   0       ← живий!

# Видаляємо:
kubectl delete pod no-oom
```

---

## 12. ДЕМО: CPU Throttling

CPU throttling складніше "побачити" ніж OOMKilled — Pod не вмирає, просто сповільнюється. Але ми можемо виміряти це через cgroup статистику.

### Крок 1: Запускаємо CPU-інтенсивний Pod

```bash
# Pod що намагається використати 1 CPU, але ліміт 200m (0.2 CPU):
kubectl run cpu-throttle \
  --image=polinux/stress \
  --restart=Never \
  --limits='cpu=200m,memory=128Mi' \
  --requests='cpu=100m,memory=64Mi' \
  -- stress --cpu 1 --timeout 120
```

### Крок 2: Вимірюємо throttling

```bash
# Заходимо в Pod (в іншому терміналі, поки stress ще виконується):
kubectl exec -it cpu-throttle -- sh

# Дивимось CPU статистику cgroup:
cat /sys/fs/cgroup/cpu/cpu.stat
# nr_periods     120          ← кількість 100ms CPU квант
# nr_throttled   89           ← скільки разів throttled (89 з 120 = 74%!)
# throttled_time 8900000000   ← ns часу в throttled стані

# Виходимо:
exit
```

`nr_throttled / nr_periods = 89/120 = 74%` — Pod throttled 74% часу. Це означає що ваш сервіс відповідає в 5 разів повільніше ніж міг би.

### Крок 3: kubectl top показує реальне vs ліміт

```bash
# Якщо metrics-server встановлено:
kubectl top pod cpu-throttle
# NAME          CPU(cores)   MEMORY(bytes)
# cpu-throttle   200m        10Mi

# CPU(cores) = 200m = ліміт. Pod намагається більше, але throttled до 200m.
```

### Крок 4: Чистимо після демо

```bash
kubectl delete pod cpu-throttle
```

---

## 13. Типові помилки

### Помилка 1: Не вказувати resources взагалі

```yaml
# ПОГАНО:
containers:
  - name: app
    image: my-app:1.0
    # немає resources
```

Наслідки: BestEffort QoS, перший кандидат на евікцію, Scheduler не може правильно розподілити.

Виправлення: завжди вказуй resources. Встанови LimitRange як страховку.

### Помилка 2: Limits значно більше за requests (burst без контролю)

```yaml
# НЕБЕЗПЕЧНО:
resources:
  requests:
    memory: "64Mi"
  limits:
    memory: "4Gi"   # в 64 рази більше requests!
```

Scheduler резервує 64Mi на вузлі, але Pod може з'їсти 4Gi. Це overcommitment що призводить до memory pressure і евікції інших Pod'ів.

Правило: limits.memory не більше 2-3x від requests.memory.

### Помилка 3: Занадто низькі limits.cpu викликають latency

```yaml
# ПОГАНО для .NET:
resources:
  limits:
    cpu: "50m"   # 5% ядра для .NET → 10-20x throttling
```

.NET runtime сам по собі (GC, JIT, thread pool) потребує ~100-200m в idle. З 50m CPU Pod буде throttled навіть коли не обробляє запити.

Мінімальний `requests.cpu` для .NET: 100m. Рекомендований: 250m+.

### Помилка 4: Ігнорувати різницю між Mi і M

```yaml
# Здається однаково — але різниця 7%:
memory: "128M"    # 128,000,000 байт
memory: "128Mi"   # 134,217,728 байт  ← правильно для Kubernetes
```

Завжди використовуй `Mi`, `Gi` в Kubernetes (бінарні одиниці).

### Помилка 5: limits.cpu = requests.cpu при непостійному навантаженні

```yaml
# Якщо сервіс має пікове навантаження:
resources:
  requests:
    cpu: "500m"
  limits:
    cpu: "500m"   # рівно = Guaranteed, але без можливості burst
```

Під час піку трафіку Pod буде throttled до 500m і не зможе обробити більше. Краще:
```yaml
resources:
  requests:
    cpu: "200m"   # резервуємо скромно
  limits:
    cpu: "1000m"  # дозволяємо burst до 1 CPU
```

Але: пам'ять requests == limits (Guaranteed) — правильно для критичних сервісів.

### Помилка 6: ResourceQuota без LimitRange

```yaml
# ResourceQuota є, але Pod без resources:
kind: ResourceQuota
spec:
  hard:
    limits.memory: "10Gi"
```

Якщо Pod не має limits — він не рахується в квоті. Один Pod може з'їсти всі 10Gi "непомітно". Завжди встановлюй LimitRange разом з ResourceQuota.

---

## 14. Підсумок і вправи

### Що ми вивчили

**CPU** — стискуваний ресурс. Перевищення limits → throttling (уповільнення, не смерть). Вимірюється в ядрах і мілікорах.

**Memory** — нестискуваний ресурс. Перевищення limits → OOMKilled (exit code 137, моментальна смерть процесу).

**Requests** використовує Scheduler для розміщення Pod'у. **Limits** — жорстка стеля споживання.

**QoS класи** визначають пріоритет при нестачі ресурсів: Guaranteed → Burstable → BestEffort (евікція у зворотньому порядку).

**LimitRange** задає дефолти для Pod'ів без resources. **ResourceQuota** обмежує загальне споживання namespace.

### Команди уроку — шпаргалка

```bash
# Resources Pod'у:
kubectl get pod <name> -o jsonpath='{.spec.containers[0].resources}'
kubectl describe pod <name> | grep -A8 "Limits:"

# QoS клас:
kubectl get pod <name> -o jsonpath='{.status.qosClass}'

# Споживання (потребує metrics-server):
kubectl top pods
kubectl top nodes
kubectl top pods --containers

# LimitRange і Quota:
kubectl get limitrange
kubectl describe limitrange <name>
kubectl get resourcequota
kubectl describe resourcequota <name>

# Діагностика OOMKilled:
kubectl describe pod <name> | grep -A5 "Last State"
# exit code 137 = OOMKilled

# CPU throttling всередині Pod'у:
kubectl exec -it <pod> -- cat /sys/fs/cgroup/cpu/cpu.stat
```

### Вправи

**Вправа 1 — Легка:**
Створи Pod без resources. Переконайся що `kubectl describe pod` показує `QoS Class: BestEffort`. Потім застосуй `k8s/06-resources/limitrange.yaml` і створи такий самий Pod ще раз — перевір що тепер у нього є resources (LimitRange підставив дефолти).

**Вправа 2 — Середня:**
Запусти `k8s/06-resources/oom-demo.yaml`, дочекайся OOMKilled. Потім відредагуй файл: збільш `limits.memory` до `300Mi`. Переконайся що Pod тепер виживає. Поясни чому stress allocates 200M але ліміт 300Mi — більше ніж достатньо.

**Вправа 3 — Складна:**
Встанови Metrics Server (інструкції в секції 9). Запусти `kubectl top pods --containers` і порівняй реальне споживання weather-api з його requests і limits. Поміркуй: чи правильно виставлені поточні requests? Запропонуй більш точні значення на основі реального споживання.

### Питання для роздумів

- Якщо Pod стоїть у черзі `Pending` через нестачу ресурсів — які є варіанти вирішення без збільшення вузлів кластеру?
- Чому для memory краще requests == limits (Guaranteed), але для CPU — ні?
- Що відбудеться якщо LimitRange встановлює `default.memory: 256Mi`, але Pod явно вказує `requests.memory: 1Gi`? Яке значення переможе?

---

## Наступний урок

**Урок 7: StatefulSet — Дані, які переживають смерть Pod'у**

Всі наші Pod'и досі були stateless — вони нічого не пам'ятають між перезапусками. Але PostgreSQL потребує стабільного диску, стабільного імені і порядкового запуску. Deployment для цього не підходить. У наступному уроці:
- Persistent Volumes, PVC, StorageClass — як K8s керує дисками
- StatefulSet — Pod'и зі стабільною ідентичністю
- Headless Service + DNS для окремих Pod'ів
- Live демо: вбиваємо postgres-0 → дані залишаються

---

*Урок підготовлено для Kubernetes Workshop. Версія K8s: 1.29+*
