# Урок 5: Health Checks — Kubernetes навчається відрізняти живий Pod від мертвого

> **Рівень:** Початківець (потрібні Уроки 1-4)
> **Тривалість:** ~75 хвилин
> **Що потрібно:** Deployment з Уроку 4 запущений
> **Що отримаєш:** livenessProbe, readinessProbe, startupProbe налаштовані; демо CrashLoopBackOff

---

## Зміст

1. [Проблема: K8s не знає що всередині контейнера](#1-проблема)
2. [Три типи проб](#2-три-типи-проб)
3. [livenessProbe — контейнер живий?](#3-livenessprobe)
4. [readinessProbe — контейнер готовий?](#4-readinessprobe)
5. [startupProbe — для повільного старту](#5-startupprobe)
6. [Три механізми перевірки: HTTP, TCP, exec](#6-механізми-перевірки)
7. [Розбір YAML файлу](#7-розбір-yaml)
8. [Практика: /health endpoints в ASP.NET Core](#8-практика-health-endpoints)
9. [ДЕМО: CrashLoopBackOff — що це і як діагностувати](#9-демо-crashloopbackoff)
10. [ДЕМО: readiness — Pod ізолюється від трафіку](#10-демо-readiness)
11. [Типові помилки](#11-типові-помилки)
12. [Підсумок і вправи](#12-підсумок-і-вправи)

---

## 1. Проблема

### Kubernetes бачить тільки "контейнер запущено"

Після того як контейнер стартував, Kubernetes отримує сигнал "процес живий" від container runtime (containerd). З цього моменту:
- Service починає надсилати трафік на Pod
- K8s вважає Pod "готовим" (`READY: 1/1`)
- Deployment рахує Pod як "available"

Але контейнер "запущено" — це не те саме що "готовий до роботи".

### Три реальні проблеми

**Проблема 1: Додаток ще ініціалізується**

```
t=0s   Контейнер запущений
t=0s   K8s: Pod Ready ✓ → Service починає надсилати запити
t=1s   Перший запит прийшов на Pod
t=1s   .NET: "DI container initializing..." → HTTP 503
t=15s  .NET: підключився до PostgreSQL
t=20s  .NET: прогрів Redis кешу...
t=25s  .NET: реально готовий до роботи
```

Перші 25 секунд — всі запити отримують помилки.

**Проблема 2: Додаток завис, але контейнер "живий"**

```
t=0       Додаток запущений
t=1h      Все працює нормально
t=1h+5m   Deadlock в thread pool: всі потоки зайняті
t=1h+5m   HTTP запити: зависають вічно (timeout 30s)
t=1h+5m   K8s: контейнер запущений, процес є → Pod Ready ✓
```

K8s не знає що додаток фактично мертвий. Трафік продовжує надходити і зависати.

**Проблема 3: Rolling update надсилає трафік на Pod що ще стартує**

```
RollingUpdate: запустили новий Pod (v2)
K8s: контейнер запущений → додаємо в Service Endpoints
Запити йдуть на Pod v2 поки він ще ініціалізується → 503
Потім видаляємо Pod v1 → короткий шторм помилок
```

### Що нам потрібно

Механізм за яким K8s може запитувати у самого додатку: "Ти живий? Ти готовий?"

Відповідь Kubernetes: **Health Probes**.

---

## 2. Три типи проб

```
startupProbe         livenessProbe        readinessProbe
     │                    │                    │
     ▼                    ▼                    ▼
Чи завершив        Чи живий зараз?     Чи готовий до
  старт?           (перезапустити       трафіку зараз?
  (чекати)         якщо ні)            (ізолювати якщо ні)
```

| Проба | Питання | Дія при провалі | Вплив на Service |
|-------|---------|-----------------|-----------------|
| `startupProbe` | Чи завершив старт? | Рестарт контейнера | Немає трафіку до успіху |
| `livenessProbe` | Чи живий? | Вбити і перезапустити | Немає (Pod залишається в Endpoints) |
| `readinessProbe` | Чи готовий? | Виключити з Endpoints | **Так: трафік не надходить** |

Ключова різниця:
- `liveness` провалився → контейнер **вбивається і перезапускається**
- `readiness` провалився → Pod **виключається з Service** (але не перезапускається)

---

## 3. livenessProbe

### Призначення

livenessProbe відповідає на питання: "Чи живий цей контейнер?"

Якщо проба провалюється `failureThreshold` разів поспіль → kubelet вбиває контейнер і запускає новий (`restartPolicy: Always` за замовчуванням для Deployment).

### Що перевіряти

```
livenessProbe для WeatherApi:
  /health/live   → "процес живий і обробляє запити"
  НЕ перевіряє:  PostgreSQL, Redis, зовнішні API
```

Якщо livenessProbe перевіряє PostgreSQL і база недоступна — K8s буде безкінечно перезапускати Pod. Але проблема не в Pod'і, а в базі. Рестарти нічому не допоможуть і лише погіршать ситуацію.

Золоте правило: livenessProbe перевіряє тільки те що всередині контейнера. Зовнішні залежності — для readinessProbe.

### Як виглядає поведінка

```
t=0    Pod запущений
t=15s  liveness: GET /health/live → 200 ✓
t=30s  liveness: GET /health/live → 200 ✓
t=45s  Deadlock в app
t=45s  liveness: GET /health/live → (timeout) ✗  provál #1
t=60s  liveness: GET /health/live → (timeout) ✗  provál #2
t=75s  liveness: GET /health/live → (timeout) ✗  provál #3 → RESTART
t=76s  Новий контейнер стартує
```

---

## 4. readinessProbe

### Призначення

readinessProbe відповідає на питання: "Чи готовий цей Pod приймати трафік зараз?"

Якщо проба провалюється → Pod виключається з `Endpoints` об'єкту Service. Трафік більше не надходить. Pod **не перезапускається**.

Як тільки проба знову пройде → Pod повертається в `Endpoints`.

### Що перевіряти

```
readinessProbe для WeatherApi:
  /health/ready  → "з'єднання з PostgreSQL є"
                   "з'єднання з Redis є"
                   "початкові дані завантажені"
```

readinessProbe може і повинна перевіряти зовнішні залежності: якщо БД недоступна — Pod не повинен приймати запити.

### Як виглядає поведінка при старті

```
t=0    Pod запущений
t=1s   readiness: GET /health/ready → 503 (БД ще не підключена)
t=2s   K8s: Pod не в Endpoints → трафіку немає
t=10s  readiness: GET /health/ready → 503 (підключення іде)
t=20s  readiness: GET /health/ready → 200 ✓
t=20s  K8s: Pod додається в Endpoints → трафік починає надходити
```

### readiness під час rolling update

```
replicas: 3, maxUnavailable: 0, maxSurge: 1

До оновлення:    [v1✓] [v1✓] [v1✓]   всі в Endpoints
                 
Крок 1: запустили новий Pod v2:
         [v1✓] [v1✓] [v1✓] [v2?]   v2 ще не в Endpoints
         
Поки v2 ініціалізується (readiness не проходить):
         всі запити на [v1✓] [v1✓] [v1✓] — жодного обриву

v2 пройшов readiness ✓:
         [v1✓] [v1✓] [v1✓] [v2✓]   тепер v2 в Endpoints

Видаляємо один v1:
         [v1✓] [v1✓] [v2✓]           → і так далі
```

Саме завдяки readinessProbe RollingUpdate справді "zero-downtime".

---

## 5. startupProbe

### Проблема без startupProbe

.NET додаток стартує 20-30 секунд. Якщо livenessProbe починає перевіряти одразу:

```
initialDelaySeconds: 0
periodSeconds: 10
failureThreshold: 3

t=0   контейнер запущений
t=10  liveness: /health/live → 503 (ще ініціалізується) ✗ провал #1
t=20  liveness: /health/live → 503                      ✗ провал #2
t=30  liveness: /health/live → 503                      ✗ провал #3 → RESTART
t=30  контейнер перезапускається ← ніколи не запустився
```

### Рішення: `initialDelaySeconds`

Можна виставити `initialDelaySeconds: 30` в livenessProbe. Але проблема: якщо додаток реально завис на старті — K8s чекатиме 30 секунд перш ніж помітить. Негнучко.

### Правильне рішення: startupProbe

```
startupProbe:
  failureThreshold: 30    # 30 * 10s = 5 хвилин максимальний час старту
  periodSeconds: 10

Поки startupProbe не пройшла:
  - livenessProbe НЕ виконується
  - readinessProbe НЕ виконується
  - Pod залишається Not Ready

Після першого успіху startupProbe:
  - startupProbe більше не виконується
  - вмикаються liveness і readiness
```

Це дає:
- До 5 хвилин на старт (можна регулювати)
- Звичайні `periodSeconds: 15` для liveness після старту
- Без зайвого `initialDelaySeconds` в liveness

---

## 6. Механізми перевірки

### HTTP GET

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: http            # ім'я або номер порту
    httpHeaders:          # опціонально
      - name: Custom-Header
        value: Awesome
```

Успіх: HTTP status code між 200 і 399.

Найчастіший варіант для web-сервісів. Для WeatherApi — основний механізм.

### TCP Socket

```yaml
readinessProbe:
  tcpSocket:
    port: 5432            # просто перевіряємо що порт відкрито
```

Успіх: TCP підключення встановлено.

Корисно для PostgreSQL, Redis, gRPC сервісів де немає HTTP. Перевіряє тільки що порт слухає — не що сервіс справно відповідає.

### Exec

```yaml
livenessProbe:
  exec:
    command:
      - pg_isready           # для PostgreSQL в тому ж Pod'і
      - -U
      - weather_user
```

Успіх: команда завершилась з exit code 0.

Гнучко, але важче відлагоджувати. Корисно для баз даних або сервісів без HTTP endpoint.

---

## 7. Розбір YAML файлу

Відкрий `k8s/05-health/deployment.yaml`.

```yaml
startupProbe:
  httpGet:
    path: /
    port: http
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 30       # 30 * 10s = 5 хвилин на старт
  successThreshold: 1
  timeoutSeconds: 5
```

`initialDelaySeconds: 5` — не починати відразу. Контейнеру потрібно хоча б кілька секунд щоб процес nginx/app запустився і почав слухати порт.

`successThreshold` для startupProbe завжди `1` — одного успіху достатньо щоб сказати "стартував".

```yaml
livenessProbe:
  httpGet:
    path: /                   # для реального WeatherApi: /health/live
    port: http
  initialDelaySeconds: 0      # startupProbe вже відпрацювала — затримки не треба
  periodSeconds: 15
  failureThreshold: 3         # 3 * 15s = 45 секунд до рестарту
  successThreshold: 1
  timeoutSeconds: 5
```

```yaml
readinessProbe:
  httpGet:
    path: /                   # для реального WeatherApi: /health/ready
    port: http
  initialDelaySeconds: 0
  periodSeconds: 10           # частіше ніж liveness: швидко реагуємо на проблеми
  failureThreshold: 3
  successThreshold: 1
  timeoutSeconds: 3           # коротший: якщо відповідь повільна — вже проблема
```

---

## 8. Практика: /health endpoints в ASP.NET Core

### Встановлення пакетів

```bash
dotnet add package Microsoft.Extensions.Diagnostics.HealthChecks
dotnet add package AspNetCore.HealthChecks.NpgSql    # для PostgreSQL
dotnet add package AspNetCore.HealthChecks.Redis      # для Redis
```

### Реєстрація health checks

```csharp
// Program.cs
var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration
    .GetConnectionString("DefaultConnection");
var redisConnection = builder.Configuration["Redis__Host"] + ":"
    + builder.Configuration["Redis__Port"];

builder.Services.AddHealthChecks()
    // "live" — просто перевіряє що процес живий (без зовнішніх залежностей)
    // Нічого не додаємо — сам факт що endpoint відповідає = "живий"

    // "ready" — перевіряє зовнішні залежності, тегуємо "ready"
    .AddNpgsql(
        connectionString!,
        name: "postgres",
        tags: new[] { "ready" }
    )
    .AddRedis(
        redisConnection,
        name: "redis",
        tags: new[] { "ready" }
    );

var app = builder.Build();

// /health/live — тільки "процес живий", не перевіряє БД
app.MapHealthChecks("/health/live", new HealthCheckOptions
{
    Predicate = _ => false,   // не запускати жодного check — просто відповісти 200
    ResponseWriter = WriteSimpleResponse
});

// /health/ready — перевіряє все з тегом "ready"
app.MapHealthChecks("/health/ready", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready"),
    ResponseWriter = WriteJsonResponse
});

app.Run();

// Спрощений JSON response:
static Task WriteJsonResponse(HttpContext context, HealthReport report)
{
    context.Response.ContentType = "application/json";
    var result = JsonSerializer.Serialize(new
    {
        status = report.Status.ToString(),
        checks = report.Entries.ToDictionary(
            e => e.Key,
            e => new { status = e.Value.Status.ToString(), duration = e.Value.Duration }
        )
    });
    return context.Response.WriteAsync(result);
}

static Task WriteSimpleResponse(HttpContext context, HealthReport _)
{
    context.Response.ContentType = "text/plain";
    return context.Response.WriteAsync("Healthy");
}
```

### Оновлення deployment.yaml для реального WeatherApi

```yaml
startupProbe:
  httpGet:
    path: /health/live
    port: http
  initialDelaySeconds: 10   # .NET потребує часу на старт
  periodSeconds: 10
  failureThreshold: 30       # 5 хвилин максимум

livenessProbe:
  httpGet:
    path: /health/live
    port: http
  periodSeconds: 15
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /health/ready
    port: http
  periodSeconds: 10
  failureThreshold: 3
```

### Тестування health endpoints

```bash
# Після kubectl apply, заходимо в Pod:
kubectl exec -it weather-api-<hash> -- sh

# Тестуємо всередині Pod'у:
wget -qO- http://localhost:8080/health/live
# Виведе: Healthy

wget -qO- http://localhost:8080/health/ready
# Виведе: {"status":"Healthy","checks":{"postgres":{"status":"Healthy",...}}}

# Або через kubectl port-forward:
kubectl port-forward deployment/weather-api 8080:8080
# В браузері: http://localhost:8080/health/ready
```

---

## 9. ДЕМО: CrashLoopBackOff

CrashLoopBackOff — один з найпоширеніших станів в Kubernetes. Вчимось розпізнавати і діагностувати.

### Що таке CrashLoopBackOff

```
Pod запускається → контейнер завершується з помилкою (exit code != 0)
                → K8s чекає N секунд (backoff)
                → перезапускає контейнер
                → знову завершується
                → чекає довше (exponential backoff: 10s, 20s, 40s, 80s, 160s, 300s)
                → ...
```

Стан Pod'у: `CrashLoopBackOff`

### Відтворюємо CrashLoopBackOff через liveness

Тимчасово зламаємо livenessProbe щоб вона перевіряла неіснуючий шлях:

```bash
# Редагуємо deployment напряму (тільки для демонстрації!)
kubectl patch deployment weather-api --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/nonexistent"}]'
```

Або відредагуй `deployment.yaml`:
```yaml
livenessProbe:
  httpGet:
    path: /nonexistent   # nginx поверне 404 → liveness провалиться
    port: http
  periodSeconds: 5
  failureThreshold: 2
```

```bash
kubectl apply -f deployment.yaml
```

### Спостерігаємо за розвитком подій

```bash
# В окремому терміналі:
kubectl get pods -w

# Побачимо приблизно:
# NAME                           READY   STATUS             RESTARTS
# weather-api-7d6b8f9c4-xk2pt   1/1     Running            0
# weather-api-8a9bc7d5f-r3mn4   0/1     Running            0          ← новий Pod
# weather-api-8a9bc7d5f-r3mn4   1/1     Running            0
# weather-api-7d6b8f9c4-xk2pt   1/1     Terminating        0          ← старий видаляється
# weather-api-8a9bc7d5f-r3mn4   0/1     Running            1          ← рестарт!
# weather-api-8a9bc7d5f-r3mn4   0/1     CrashLoopBackOff   2
# weather-api-8a9bc7d5f-r3mn4   0/1     CrashLoopBackOff   3
```

### Діагностика CrashLoopBackOff

**Крок 1: Подивитись на Pod'и**

```bash
kubectl get pods
# NAME                           READY   STATUS             RESTARTS   AGE
# weather-api-8a9bc7d5f-r3mn4   0/1     CrashLoopBackOff   5          2m
```

`RESTARTS: 5` і зростає — це CrashLoopBackOff.

**Крок 2: describe — дивимось Events**

```bash
kubectl describe pod weather-api-8a9bc7d5f-r3mn4
```

В секції `Events` побачимо:
```
Events:
  Warning  Unhealthy   5s    kubelet
    Liveness probe failed: HTTP probe failed with statuscode: 404
  Warning  BackOff     2s    kubelet
    Back-off restarting failed container weather-api
```

**Крок 3: Логи контейнера**

```bash
# Логи поточного (перезапущеного) контейнера:
kubectl logs weather-api-8a9bc7d5f-r3mn4

# Логи попереднього контейнера (якщо поточний зависнув або щойно стартував):
kubectl logs weather-api-8a9bc7d5f-r3mn4 --previous
```

### Відкатуємось назад

```bash
kubectl rollout undo deployment weather-api
# або застосуй правильний deployment.yaml:
kubectl apply -f k8s/05-health/deployment.yaml

kubectl rollout status deployment weather-api
```

---

## 10. ДЕМО: readiness — Pod ізолюється від трафіку

### Підготовка

Переконайся що Service з Уроку 3 запущений:

```bash
kubectl get service weather-api-nodeport
```

### Симулюємо "не готовий" Pod

Змінимо readinessProbe на неіснуючий шлях для одного Pod'у:

```bash
# Дивимось Pod'и і вибираємо один:
kubectl get pods -l app=weather-api

# Отримаємо ім'я першого Pod'у:
POD=$(kubectl get pods -l app=weather-api -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD"
```

Видалимо один Pod і спостерігаємо як Deployment підтримує кількість:

```bash
kubectl delete pod $POD
# Pod видалено

# У другому терміналі спостерігаємо:
kubectl get pods -w
# Pod одразу починає відновлюватись (Урок 2!)
```

### Симулюємо тимчасову недоступність через масштабування

Більш наочне демо — масштабувати до 1 репліки і перевірити:

```bash
# Масштабуємо до 1 Pod'у:
kubectl scale deployment weather-api --replicas=1

# Перевіряємо що Service endpoint один:
kubectl get endpoints weather-api-nodeport
# або:
kubectl describe service weather-api-nodeport | grep Endpoints
```

Тепер видалимо Pod і бачимо момент "без Endpoints":

```bash
POD=$(kubectl get pods -l app=weather-api -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $POD

# Одразу після видалення:
kubectl get endpoints
# weather-api-nodeport   <none>   ← Немає жодного endpoint!
# Новий Pod стартує...
```

### Перевіряємо з curl

```bash
# Поки Pod стартує — запити відхиляться:
# (NodePort зазвичай 30XXX, дивись kubectl get svc)
curl http://localhost:30080/

# Як тільки Pod пройшов readiness — відповідає:
curl http://localhost:30080/
# <html>...nginx...</html>
```

Повертаємо нормальну кількість:
```bash
kubectl scale deployment weather-api --replicas=3
```

---

## 11. Типові помилки

### Помилка 1: livenessProbe перевіряє зовнішні залежності

```yaml
# ПОГАНО: якщо PostgreSQL впав → всі Pod'и перезапускаються
livenessProbe:
  httpGet:
    path: /health/ready   # /ready перевіряє БД!
    port: http
```

Наслідки: БД впала → liveness провалюється → Pod перезапускається → знову підключається до БД → знову провалюється → CrashLoopBackOff. Додаток робить ситуацію гіршою під час і без того складного інциденту.

Виправлення: liveness перевіряє тільки сам процес (`/health/live`), readiness перевіряє залежності (`/health/ready`).

### Помилка 2: Немає startupProbe, але великий initialDelaySeconds

```yaml
livenessProbe:
  initialDelaySeconds: 120   # ← 2 хвилини, а раптом завис на 130с?
  periodSeconds: 10
  failureThreshold: 3
```

Проблема: якщо додаток завис на старті на 130 секунд — K8s чекатиме 120 секунд і лише потім помітить через 30 секунд (3 * 10). 2.5 хвилини "вхолосту".

Виправлення: startupProbe з failureThreshold що дає достатній час, і звичайні значення для livenessProbe.

### Помилка 3: timeoutSeconds більший за periodSeconds

```yaml
livenessProbe:
  periodSeconds: 5
  timeoutSeconds: 10   # ← таймаут довший за інтервал!
```

K8s запускає нову probe поки попередня ще не завершилась. Поведінка непередбачувана. Правило: `timeoutSeconds < periodSeconds`.

### Помилка 4: failureThreshold занадто малий для readiness

```yaml
readinessProbe:
  periodSeconds: 10
  failureThreshold: 1   # ← один провал = виключення з Endpoints!
```

При будь-якому тимчасовому збої (GC pause, коротке навантаження) Pod виключається з Endpoints. Рекомендовано мінімум 3.

### Помилка 5: Забули що readiness не перезапускає Pod

```bash
kubectl get pods
# NAME                      READY   STATUS    RESTARTS
# weather-api-xxxxx-abc     0/1     Running   0

# Студент думає: "Pod не готовий — зачекаємо поки перезапуститься"
# Але RESTARTS: 0 — Pod ніколи не перезапуститься через readiness!
```

Readiness провалюється → Pod виключається з Service → сидить і чекає. Потрібно діагностувати чому readiness провалюється і виправити проблему (наприклад, БД недоступна).

### Помилка 6: successThreshold > 1 для liveness

```yaml
livenessProbe:
  successThreshold: 3   # ← 3 успіхи поспіль перш ніж вважати "живим"
```

Для livenessProbe це заборонено K8s: `successThreshold must be 1 for liveness and startup probes`. K8s відхилить такий маніфест.

---

## 12. Підсумок і вправи

### Що ми вивчили

**startupProbe** дає .NET додатку час на ініціалізацію. Поки не пройде — liveness і readiness не перевіряються. Запобігає рестартам під час повільного старту.

**livenessProbe** перевіряє чи живий процес. При провалі — контейнер перезапускається. Перевіряє тільки внутрішній стан додатку, не зовнішні залежності.

**readinessProbe** перевіряє чи готовий Pod приймати трафік. При провалі — Pod виключається з Endpoints Service без перезапуску. Може перевіряти зовнішні залежності (БД, Redis).

Разом вони реалізують справжній "zero-downtime" rolling update.

### Команди уроку — шпаргалка

```bash
# Стан проб у Pod'і:
kubectl describe pod <pod-name>       # Events секція: Liveness/Readiness probe

# Стежити за рестартами:
kubectl get pods -w

# Логи контейнера (поточний і попередній):
kubectl logs <pod-name>
kubectl logs <pod-name> --previous

# Endpoints Service — чи включений Pod:
kubectl get endpoints
kubectl describe service weather-api-nodeport

# Перевірити health endpoint вручну:
kubectl exec -it <pod-name> -- wget -qO- http://localhost:8080/health/live
kubectl exec -it <pod-name> -- wget -qO- http://localhost:8080/health/ready

# Відкат після зламаного deploy:
kubectl rollout undo deployment weather-api
```

### Вправи

**Вправа 1 — Легка:**
Встанови `livenessProbe.failureThreshold: 1` і `periodSeconds: 5` в `deployment.yaml`. Застосуй і спостерігай як Pod перезапускається при першому ж збою probe. Потім поясни чому це погано в production і поверни нормальні значення.

**Вправа 2 — Середня:**
Симулюй CrashLoopBackOff: зміни `livenessProbe.httpGet.path` на `/this-path-does-not-exist`. Застосуй і зачекай поки з'явиться CrashLoopBackOff. Виконай повну діагностику: `kubectl get pods`, `kubectl describe pod`, `kubectl logs --previous`. Зафіксуй що саме показують Events. Потім зроби rollback.

**Вправа 3 — Складна:**
Додай в `deployment.yaml` readinessProbe що перевіряє шлях `/health/ready`, а livenessProbe залиш на `/health/live`. Потім вручну відредагуй ConfigMap щоб зламати якийсь параметр (наприклад, `Redis__Host: "nonexistent-host"`). Спостерігай за поведінкою: readiness починає провалюватись → Pod виключається з Endpoints. Але Pod при цьому НЕ перезапускається (RESTARTS не зростає). Виправ ConfigMap і зроби `kubectl rollout restart`. Поясни різницю між поведінкою liveness і readiness в цьому сценарії.

### Питання для роздумів

- Чому readinessProbe "зцілюється" сама (Pod повертається в Endpoints) а livenessProbe вбиває контейнер? Яка логіка за цим рішенням?
- Якщо в Pod'і 2 контейнери (sidecar pattern) — як readiness поводиться? Чи потрібна probe для кожного контейнера?
- Що відбувається з inflight запитами коли Pod виключається з Endpoints через readiness? Вони обриваються або завершуються? (підказка: `terminationGracePeriodSeconds`)

---

## Наступний урок

**Урок 6: Resources — Не дай Pod'у з'їсти весь вузол**

Зараз у наших Pod'ів є `requests` і `limits`, але ми ніколи не бачили що відбувається якщо їх перевищити. У наступному уроці: live демо OOMKilled (Out of Memory Killed), CPU throttling, QoS класи (Guaranteed, Burstable, BestEffort) і як Scheduler використовує requests для розміщення Pod'ів.

---

*Урок підготовлено для Kubernetes Workshop. Версія K8s: 1.29+*
