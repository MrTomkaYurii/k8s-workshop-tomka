# Урок 4: Config і Secrets — Конфігурація без rebuild образу

> **Рівень:** Початківець (потрібні Уроки 1-3)
> **Тривалість:** ~70 хвилин
> **Що потрібно:** Deployment і Service з Уроків 2-3 запущені
> **Що отримаєш:** ConfigMap і Secret підключені до Pod'ів трьома способами

---

## Зміст

1. [Проблема: конфіг в коді](#1-проблема)
2. [ConfigMap — несекретні налаштування](#2-configmap)
3. [Secret — секретні дані](#3-secret)
4. [Три способи підключення до Pod'у](#4-три-способи)
5. [Розбір YAML файлів](#5-розбір-yaml)
6. [Практика: підключаємо ConfigMap і Secret](#6-практика)
7. [ДЕМО: змінюємо конфіг без rebuild](#7-демо-зміна-конфігу)
8. [Підводні камені Secret](#8-підводні-камені)
9. [Типові помилки](#9-типові-помилки)
10. [Підсумок і вправи](#10-підсумок-і-вправи)

---

## 1. Проблема

В Уроці 2 у `deployment.yaml` ми написали конфіг напряму:

```yaml
env:
  - name: ASPNETCORE_ENVIRONMENT
    value: "Development"
  - name: ASPNETCORE_URLS
    value: "http://+:8080"
```

Це працює для першого уроку. Але в реальному проекті є чотири проблеми.

### Проблема 1: один YAML для всіх середовищ

У нас три середовища: dev, staging, production. В кожному:
- різні рівні логування
- різні URL бази даних
- різний розмір пулу підключень

Якщо конфіг в `deployment.yaml` — треба три окремі файли і постійно їх синхронізувати. Або одна купа if-else логіки. Обидва варіанти погані.

### Проблема 2: паролі в коді

```yaml
env:
  - name: DB_PASSWORD
    value: "my-secret-password"   # ← це потрапляє в git!
```

Пароль у git — катастрофа. Навіть якщо видалити коміт — він залишиться в git history. Будь-хто з доступом до репозиторію бачить продакшн паролі.

### Проблема 3: rebuild щоб змінити конфіг

Хочеш змінити рівень логування? Треба:
1. Змінити код або env var у Dockerfile
2. Зробити `docker build`
3. Запушити в registry
4. Зробити rolling update

Це 10-15 хвилин заради однієї зміни рядка конфігу.

### Проблема 4: неможливо керувати доступом

Кожен хто бачить `deployment.yaml` бачить і всі паролі. Неможливо дати розробнику доступ до конфігу але приховати паролі.

### Рішення: відокремити конфіг від коду

```
Без K8s:
  deployment.yaml  ←  тут і конфіг, і паролі, і код

З K8s:
  deployment.yaml  ←  тільки структура (скільки реплік, який образ)
  ConfigMap        ←  несекретні налаштування (окремий K8s об'єкт)
  Secret           ←  паролі і ключі (окремий K8s об'єкт)
```

---

## 2. ConfigMap

**ConfigMap** — K8s об'єкт для зберігання несекретних налаштувань у вигляді ключ-значення.

```
ConfigMap: weather-api-config
  ┌──────────────────────────────────────────────────────┐
  │ ASPNETCORE_ENVIRONMENT  = "Production"               │
  │ Logging__LogLevel__Default = "Information"           │
  │ WeatherApi__CacheTtlSeconds = "300"                  │
  │ Redis__Host = "redis-service"                        │
  └──────────────────────────────────────────────────────┘
                        │
              підключення до Pod'у
                        │
  ┌─────────────────────▼────────────────────────────────┐
  │ Pod: weather-api                                     │
  │ env: ASPNETCORE_ENVIRONMENT=Production               │
  │      Logging__LogLevel__Default=Information          │
  │      ... (всі ключі ConfigMap)                       │
  └──────────────────────────────────────────────────────┘
```

### Що зберігати в ConfigMap

✅ Зберігати:
- ASPNETCORE_ENVIRONMENT
- URL-адреси внутрішніх сервісів (хост Redis, хост БД — але не паролі)
- Рівні логування
- Feature flags
- Таймаути, розміри пагінації, TTL кешу
- Цілі файли конфігурації (nginx.conf, appsettings.json)

❌ Не зберігати:
- Паролі, токени, API ключі → це для Secret
- Бінарні дані (використовуй `binaryData` якщо дійсно потрібно)

### Формат ключів для .NET конфіги

ASP.NET Core читає конфіг ієрархічно. Розділювач у JSON — `:`, але змінні середовища не можуть містити `:`. Тому використовується `__` (подвійне підкреслення):

```
appsettings.json:           Змінна середовища:
{                           WeatherApi__CacheTtlSeconds=300
  "WeatherApi": {
    "CacheTtlSeconds": 300
  }
}
```

Саме тому в ConfigMap ми бачимо ключі вигляду `Logging__LogLevel__Default`.

---

## 3. Secret

**Secret** — K8s об'єкт для секретних даних. Архітектурно схожий на ConfigMap, але з рядом відмінностей.

### Чим Secret відрізняється від ConfigMap

| Характеристика | ConfigMap | Secret |
|---------------|-----------|--------|
| Призначення | Несекретні конфіги | Паролі, токени, ключі |
| Зберігання в etcd | Відкрито | base64 (НЕ шифрування) |
| Видно в `kubectl describe` | Так | Значення приховані |
| RBAC | Загальний доступ | Можна обмежити |
| Монтування | env або volume | env або volume |
| Типові поля | URLs, timeouts | passwords, API keys |

### Secret — це НЕ шифрування

Одна з найпоширеніших помилок: думати що Secret зашифрований.

```bash
# Беремо Secret з кластеру:
kubectl get secret weather-api-secret -o yaml

# Бачимо:
data:
  Redis__Password: cmVkaXMtZGV2LXBhc3N3b3Jk

# Декодуємо (base64 — не шифрування!):
echo 'cmVkaXMtZGV2LXBhc3N3b3Jk' | base64 -d
# Виведе: redis-dev-password
```

`base64` — це кодування, а не шифрування. Будь-хто з доступом до API Server або до etcd може прочитати Secret.

### Тоді навіщо взагалі Secret?

1. **Менше шансів випадково засвітити.** `kubectl describe pod` не показує значення Secret-змінних.
2. **RBAC.** Можна дати розробнику доступ до ConfigMap але заблокувати Secret через ролі.
3. **Семантика.** Інструменти і оператори розуміють що Secret — секретний і можуть з ним поводитись відповідно.
4. **Шлях до справжнього шифрування.** `EncryptionConfiguration` в K8s дозволяє шифрувати Secret в etcd. З ConfigMap це неможливо.

### Справжній захист Secret у production

```
Розробка:           Staging/Production:
secret.yaml ←OK     Sealed Secrets (зашифрований YAML в git)
(не в git)          External Secrets + HashiCorp Vault / AWS SSM
```

Sealed Secrets: утиліта `kubeseal` шифрує Secret публічним ключем кластеру. В git зберігається `SealedSecret` — зашифрований об'єкт. Тільки кластер може його розшифрувати.

---

## 4. Три способи підключення до Pod'у

### Спосіб 1: `env.valueFrom` — окремий ключ

```yaml
env:
  - name: DB_CONNECTION
    valueFrom:
      secretKeyRef:
        name: weather-api-secret       # ім'я Secret
        key: ConnectionStrings__DefaultConnection  # ключ в Secret
```

Коли використовувати: коли потрібно взяти 1-3 конкретні ключі або перейменувати ключ.

### Спосіб 2: `envFrom` — всі ключі одразу

```yaml
envFrom:
  - configMapRef:
      name: weather-api-config    # всі ключі ConfigMap стають env vars
  - secretRef:
      name: weather-api-secret    # всі ключі Secret стають env vars
```

Коли використовувати: найчастіший варіант. Простий і зрозумілий. Якщо ключ є і в ConfigMap і в Secret — Secret перезаписує (підключай Secret після ConfigMap).

### Спосіб 3: Volume — файл у контейнері

```yaml
# У spec.containers:
volumeMounts:
  - name: app-config
    mountPath: /app/config/custom.json
    subPath: appsettings.Production.json   # тільки цей ключ

# У spec:
volumes:
  - name: app-config
    configMap:
      name: weather-api-config
```

Коли використовувати: коли додаток читає конфіг із файлу (nginx.conf, appsettings.json), або коли потрібно **гаряче оновлення конфігу** (volume оновлюється автоматично без рестарту; env vars — ні).

### Порівняння способів

| Спосіб | Простота | Гаряче оновлення | Коли |
|--------|----------|-----------------|------|
| `valueFrom` | Середня | Ні | 1-3 конкретні ключі |
| `envFrom` | Висока | Ні | Більшість випадків |
| volume | Низька | Так | Файли конфігу, nginx |

---

## 5. Розбір YAML файлів

### configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: weather-api-config
  namespace: default
data:
  ASPNETCORE_ENVIRONMENT: "Production"
  ASPNETCORE_URLS: "http://+:8080"
  Logging__LogLevel__Default: "Information"
  WeatherApi__CacheTtlSeconds: "300"
  Redis__Host: "redis-service"
```

Все в `data` — це рядки. Навіть числа пишуться в лапках: `"300"`. ASP.NET Core сам конвертує тип при читанні.

### secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: weather-api-secret
type: Opaque
stringData:                  # stringData: K8s сам конвертує в base64
  ConnectionStrings__DefaultConnection: "Host=postgres-service;..."
  WeatherApi__ExternalApiKey: "your-api-key"
  Redis__Password: "redis-dev-password"
```

`type: Opaque` — довільний набір ключів. Інші типи: `kubernetes.io/tls` (TLS сертифікати), `kubernetes.io/dockerconfigjson` (доступ до registry).

### deployment.yaml (фрагмент)

```yaml
spec:
  containers:
    - name: weather-api
      envFrom:
        - configMapRef:
            name: weather-api-config   # підключаємо всі ключі ConfigMap
        - secretRef:
            name: weather-api-secret   # підключаємо всі ключі Secret
      env:
        # Downward API: метадані самого Pod'у
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
```

---

## 6. Практика

### Крок 1: Застосовуємо ConfigMap і Secret

```bash
kubectl apply -f k8s/04-config/configmap.yaml
# configmap/weather-api-config created

kubectl apply -f k8s/04-config/secret.yaml
# secret/weather-api-secret created
```

### Крок 2: Перевіряємо що створилось

```bash
# ConfigMap
kubectl get configmap
# NAME                   DATA   AGE
# weather-api-config     9      10s

kubectl describe configmap weather-api-config
# Побачимо всі ключі і значення

# Secret
kubectl get secret
# NAME                  TYPE     DATA   AGE
# weather-api-secret    Opaque   3      10s

kubectl describe secret weather-api-secret
# Ключі видно, але Values приховані ("3 bytes" замість значення)
```

### Крок 3: Застосовуємо оновлений Deployment

```bash
kubectl apply -f k8s/04-config/deployment.yaml
kubectl rollout status deployment weather-api
```

### Крок 4: Перевіряємо що змінні потрапили в Pod

```bash
# Беремо ім'я будь-якого Pod'у
kubectl get pods

# Виводимо всі змінні середовища в Pod'і
kubectl exec -it weather-api-<hash>-<hash> -- env | sort

# Перевіряємо конкретні:
kubectl exec -it weather-api-<hash>-<hash> -- env | grep -E "ASPNET|WEATHER|REDIS"
```

Ти побачиш всі ключі з ConfigMap і Secret як змінні середовища. Значення Secret теж будуть видні — тут немає захисту на рівні процесу, Secret приховується тільки від `kubectl describe`.

### Крок 5: Перевіряємо Downward API

```bash
kubectl exec -it weather-api-<hash>-<hash> -- env | grep POD
# POD_NAME=weather-api-7d6b8f9c4-xk2pt
# POD_NAMESPACE=default
```

Це корисно для логування — кожен Pod знає своє ім'я і може включити його в logs.

---

## 7. ДЕМО: Змінюємо конфіг без rebuild

Головна перевага ConfigMap: зміна конфігу не вимагає rebuild Docker-образу.

### Крок 1: Перевіряємо поточне значення

```bash
kubectl exec -it weather-api-<hash>-<hash> -- env | grep CACHE
# WeatherApi__CacheTtlSeconds=300
```

### Крок 2: Змінюємо ConfigMap

Відредагуй `k8s/04-config/configmap.yaml`: змінити `WeatherApi__CacheTtlSeconds: "300"` на `"600"`, потім:

```bash
kubectl apply -f k8s/04-config/configmap.yaml
# configmap/weather-api-config configured
```

### Крок 3: Pod'и ще мають старе значення

```bash
kubectl exec -it weather-api-<hash>-<hash> -- env | grep CACHE
# WeatherApi__CacheTtlSeconds=300   ← ще 300!
```

**Чому?** Env vars читаються при старті контейнера. ConfigMap оновився, але запущені Pod'и не знають про це. Volumes оновлюються автоматично — env vars ні.

### Крок 4: Перезапускаємо Deployment

```bash
kubectl rollout restart deployment weather-api
# deployment.apps/weather-api restarted

kubectl rollout status deployment weather-api
```

### Крок 5: Нові Pod'и мають нове значення

```bash
kubectl exec -it weather-api-<hash>-<hash> -- env | grep CACHE
# WeatherApi__CacheTtlSeconds=600   ← тепер 600!
```

Rolling update замінив Pod'и без простою — нові Pod'и стартували з оновленим ConfigMap.

---

## 8. Підводні камені Secret

### Камінь 1: Secret не в git — складно синхронізувати

Якщо `secret.yaml` не в git (а він не повинен бути), то як:
- новий розробник налаштує середовище?
- CD pipeline отримає паролі?
- відновитись після краху кластеру?

Рішення: документувати які Secret потрібні і де їх взяти, або використовувати Sealed Secrets / External Secrets Operator.

### Камінь 2: Pod не запустився бо Secret не існує

```bash
# Якщо Secret видалити або не створити:
kubectl describe pod weather-api-<hash>
# Events:
#   Warning  Failed  CreateContainerConfigError
#   Error: secret "weather-api-secret" not found
```

Pod зависне в стані `Pending` або `CreateContainerConfigError`. Deployment не зможе запустити жоден Pod.

### Камінь 3: `optional: false` за замовчуванням

```yaml
envFrom:
  - secretRef:
      name: weather-api-secret
      optional: false   # за замовчуванням: Pod не стартує якщо Secret відсутній
```

Якщо Secret не обов'язковий (наприклад, тільки для деяких середовищ):

```yaml
envFrom:
  - secretRef:
      name: weather-api-secret
      optional: true    # Pod запуститься навіть без Secret
```

### Камінь 4: Великий розмір ConfigMap

ConfigMap має обмеження: 1 МБ. Якщо зберігаєш великі конфіг-файли — вони швидко з'їдають ліміт. Для великих бінарних або текстових файлів використовуй Persistent Volume або зберігай в образі контейнера.

---

## 9. Типові помилки

### Помилка 1: Зміна ConfigMap не зразу вступає в силу

```bash
kubectl apply -f configmap.yaml
# ← Pod'и ще мають старі значення!

# Потрібно:
kubectl rollout restart deployment weather-api
```

### Помилка 2: Ключ з ConfigMap перетирається Secret

```yaml
envFrom:
  - configMapRef:
      name: weather-api-config   # тут ASPNETCORE_ENVIRONMENT=Production
  - secretRef:
      name: weather-api-secret   # якщо тут теж є ASPNETCORE_ENVIRONMENT → перетере!
```

Якщо один ключ є і в ConfigMap і в Secret — перемагає той що йде останнім у `envFrom`. Перевіряй унікальність ключів.

### Помилка 3: Паролі в ConfigMap

```yaml
# НЕПРАВИЛЬНО:
kind: ConfigMap
data:
  DB_PASSWORD: "secret"   # ConfigMap не для паролів!
```

Це доступно всім хто може читати ConfigMap. Використовуй Secret.

### Помилка 4: Secret в git без шифрування

```yaml
# secret.yaml потрапив в git:
stringData:
  DB_PASSWORD: "production-password-123"   # тепер це публічно
```

Додай `secret.yaml` в `.gitignore`. Для CI/CD використовуй змінні середовища або Sealed Secrets.

### Помилка 5: Числа без лапок в ConfigMap

```yaml
# НЕПРАВИЛЬНО (YAML спарсить як число, а K8s очікує рядок):
data:
  PORT: 8080

# ПРАВИЛЬНО:
data:
  PORT: "8080"
```

---

## 10. Підсумок і вправи

### Що ми вивчили

**ConfigMap** зберігає несекретні налаштування окремо від коду. Зміна конфігу — `kubectl apply` + `kubectl rollout restart`, без rebuild образу.

**Secret** зберігає паролі і ключі. Архітектурно схожий на ConfigMap, але значення приховані в `kubectl describe` і можна обмежити доступ через RBAC. В etcd зберігається як base64 — не шифрування, але краще ніж відкритий текст.

**Три способи підключення:** `valueFrom` (конкретний ключ), `envFrom` (всі ключі), volume (файл в контейнері).

### Команди уроку — шпаргалка

```bash
# ConfigMap
kubectl apply -f configmap.yaml
kubectl get configmap
kubectl describe configmap weather-api-config

# Secret
kubectl apply -f secret.yaml
kubectl get secret
kubectl describe secret weather-api-secret   # значення приховані

# Прочитати конкретне поле Secret:
kubectl get secret weather-api-secret \
  -o jsonpath='{.data.Redis__Password}' | base64 -d

# Перезапустити Pod'и після зміни ConfigMap:
kubectl rollout restart deployment weather-api

# Переглянути env vars в Pod'і:
kubectl exec -it <pod-name> -- env | sort
```

### Вправи

**Вправа 1 — Легка:**
Додай в `configmap.yaml` новий ключ `WeatherApi__DefaultCity: "Lviv"`. Застосуй ConfigMap і перезапусти Deployment. Переконайся що змінна з'явилась в Pod'і.

**Вправа 2 — Середня:**
Створи `configmap-dev.yaml` з `ASPNETCORE_ENVIRONMENT: "Development"` і підміни `configmap.yaml` в deployment на dev-версію. Переконайся що Pod'и запустились з правильним середовищем. Поверни назад на Production.

**Вправа 3 — Складна:**
Видали Secret (`kubectl delete secret weather-api-secret`) і перевір що станеться з Pod'ами. Зафіксуй стан в `kubectl get pods` і `kubectl describe pod`. Потім відтвори Secret і переконайся що Pod'и відновились самостійно (без `kubectl rollout restart`). Поясни чому вони відновились або чому ні.

### Питання для роздумів

- Чому `kubectl rollout restart` запускає rolling update, а не просто вбиває всі Pod'и одразу?
- Якщо зберігати конфіг у volume а не env vars — Pod не потребує рестарту при зміні ConfigMap. Чому тоді більшість .NET додатків все одно потребує рестарту?
- Sealed Secrets шифрує Secret публічним ключем кластеру. Що відбувається якщо кластер перестворити? Чи можна відновити Sealed Secret на новому кластері?

---

## Наступний урок

**Урок 5: Health Checks — Kubernetes навчається відрізняти живий Pod від мертвого**

Зараз Kubernetes вважає Pod "готовим" як тільки контейнер запустився. Але .NET додатку потрібно 10-30 секунд на ініціалізацію: DI контейнер, підключення до БД, прогрів кешу. Як не надсилати запити на Pod що ще не готовий? Як автоматично перезапускати Pod що завис у дедлоку? Відповідь — Health Probes.

---

*Урок підготовлено для Kubernetes Workshop. Версія K8s: 1.29+*
