# Урок 7: StatefulSet — Дані, які переживають смерть Pod'у

> **Рівень:** Середній (потрібні Уроки 1-6)
> **Тривалість:** ~90 хвилин
> **Що потрібно:** Кластер з Уроку 1
> **Що отримаєш:** PostgreSQL на StatefulSet, PVC, Headless Service; демо виживання даних після смерті Pod'у

---

## Зміст

1. [Проблема: чому Deployment не підходить для stateful сервісів](#1-проблема)
2. [PersistentVolume і PersistentVolumeClaim](#2-pv-і-pvc)
3. [StorageClass: динамічний provisioning](#3-storageclass)
4. [Що таке StatefulSet](#4-що-таке-statefulset)
5. [Стабільна ідентичність Pod'у](#5-стабільна-ідентичність)
6. [VolumeClaimTemplates: кожен Pod отримує власний диск](#6-volumeclaimtemplates)
7. [Headless Service для StatefulSet](#7-headless-service)
8. [Порядок запуску і зупинки](#8-порядок-запуску)
9. [Розбір маніфестів: PostgreSQL на StatefulSet](#9-розбір-маніфестів)
10. [Практика: розгортаємо PostgreSQL](#10-практика)
11. [ДЕМО: дані виживають після смерті Pod'у](#11-демо-виживання-даних)
12. [ДЕМО: підключення до конкретного Pod'у через DNS](#12-демо-dns)
13. [Коли StatefulSet, коли Deployment?](#13-коли-statefulset)
14. [Типові помилки](#14-типові-помилки)
15. [Підсумок і вправи](#15-підсумок-і-вправи)

---

## 1. Проблема

### Deployment — для рівноправних Pod'ів

Deployment розрахований на **stateless** сервіси. Його ключові властивості:
- Всі Pod'и взаємозамінні (fungible): будь-який може обробити будь-який запит
- Pod'и не мають імені — лише `app-randomhash-randomsuffix`
- При рестарті Pod отримує **нову** IP і **новий** порожній диск
- Deployment може вбивати Pod'и у довільному порядку

Це ідеально для WeatherApi. Але для бази даних це катастрофа.

### Три проблеми Deployment для PostgreSQL

**Проблема 1: Дані зникають при рестарті**

```
Deployment Pod "postgres-7d6bc-xk2pt":
  /var/lib/postgresql/data/  ← дані в контейнері
  
kubectl delete pod postgres-7d6bc-xk2pt
  → Pod видалено, диск знищено разом з даними
  → Новий Pod: /var/lib/postgresql/data/ — порожня директорія
```

Уся база даних зникла при кожному рестарті. Навіть звичайний rolling update стирає дані.

**Проблема 2: Немає стабільного мережевого імені**

Реплікація PostgreSQL потребує щоб replica знала де знаходиться master.

```
Master: postgres-7d6bc-xk2pt  IP: 10.244.1.5
Replica налаштована підключатись до 10.244.1.5

Rolling update → новий master: postgres-8a9cd-m3np7  IP: 10.244.2.8
Replica: "Де master? IP 10.244.1.5 не відповідає..."
```

Deployment не гарантує стабільного імені або IP. Кожен рестарт — нова адреса.

**Проблема 3: Довільний порядок запуску і зупинки**

При масштабуванні Deployment вбиває Pod'и у непередбачуваному порядку. Але для PostgreSQL важливо:
- Master повинен запуститись **до** replica
- Replica повинна зупинитись **до** master (graceful shutdown кластеру)

### Що нам потрібно

- **Стабільний диск** що переживає рестарти Pod'у
- **Стабільне ім'я** що не змінюється між рестартами
- **Порядковий запуск** (спочатку Pod 0, потім Pod 1...)
- **Порядкова зупинка** (спочатку Pod N, потім Pod N-1...)

Рішення: **StatefulSet**.

---

## 2. PV і PVC

Перед StatefulSet треба зрозуміти як Kubernetes керує дисками.

### PersistentVolume (PV) — реальне сховище

**PersistentVolume** — ресурс кластеру що представляє одиницю зберігання. Це може бути:
- Директорія на вузлі (hostPath, local) — для dev/тестування
- NFS share — для self-hosted production
- AWS EBS volume — для AWS
- GCP Persistent Disk — для GCP
- Azure Disk — для Azure

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-pv
spec:
  capacity:
    storage: 10Gi          # розмір диску
  accessModes:
    - ReadWriteOnce        # хто і як може читати/писати
  storageClassName: manual  # до якого StorageClass належить
  hostPath:
    path: /data/postgres   # де на вузлі (тільки для kind/dev!)
```

PV — це як "оголошення диску" адміністратором кластеру.

### PersistentVolumeClaim (PVC) — запит на сховище

**PersistentVolumeClaim** — запит від Pod'у на отримання сховища. Pod не говорить "дай мені конкретний PV" — він каже "дай мені 5Gi з можливістю ReadWriteOnce".

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: standard   # запит до конкретного StorageClass
```

### Binding: як PVC знаходить PV

```
PVC: "потрібно 5Gi, ReadWriteOnce, storageClass=standard"
        │
        ▼
K8s Control Plane шукає підходящий PV:
  ← PV1: 10Gi, ReadWriteOnce, standard ← підходить! (10Gi >= 5Gi)
  ← PV2: 2Gi,  ReadWriteOnce, standard ← не підходить (2Gi < 5Gi)
        │
        ▼
PVC bound до PV1
PV1 стає Bound і більше не доступний іншим PVC
```

```bash
# Статус PVC:
kubectl get pvc
# NAME            STATUS   VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS
# postgres-data   Bound    pvc-abc123  5Gi        RWO            standard

# Статус PV:
kubectl get pv
# NAME       CAPACITY   STATUS   CLAIM                   STORAGECLASS
# pvc-abc123 5Gi        Bound    default/postgres-data   standard
```

### Access Modes

| Режим | Скорочення | Опис |
|-------|-----------|------|
| ReadWriteOnce | RWO | Читання/запис одним вузлом одночасно |
| ReadOnlyMany | ROX | Читання багатьма вузлами |
| ReadWriteMany | RWX | Читання/запис багатьма вузлами |
| ReadWriteOncePod | RWOP | Читання/запис одним Pod'ом (Kubernetes 1.22+) |

PostgreSQL потребує **ReadWriteOnce** — лише один вузол пише на диск одночасно. ReadWriteMany потрібен рідко (shared filesystems, наприклад NFS або GlusterFS).

### Reclaim Policy — що відбувається при видаленні PVC

```
Retain:  PV залишається, дані збережені, але PV не може бути використаний іншим PVC
Delete:  PV видаляється разом з даними (CloudProvider видаляє диск)
Recycle: ЗАСТАРІЛИЙ — PV очищується (rm -rf) і стає доступним знову
```

У production зазвичай `Delete` для хмарних PV (AWS EBS, GCP PD) — диск видаляється разом з даними при видаленні PVC.

---

## 3. StorageClass

### Проблема статичного provisioning

Якщо адміністратор повинен вручну створювати PV для кожного PVC — це не масштабується. При 100 мікросервісах з базами даних потрібно 100 PV вручну.

### StorageClass — автоматичний provisioning

**StorageClass** описує "клас" сховища і contains посилання на **provisioner** — компонент що вміє автоматично створювати PV при появі PVC.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: kubernetes.io/aws-ebs   # для AWS
parameters:
  type: gp3                           # тип EBS диску
  iops: "3000"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer   # створити диск тільки коли Pod призначено на вузол
```

Коли PVC появляється з `storageClassName: fast-ssd`:
1. K8s викликає AWS EBS provisioner
2. AWS EBS provisioner звертається до AWS API і створює новий gp3 диск
3. Provisioner створює PV що описує цей диск
4. PVC автоматично bound до нового PV

### StorageClass в kind

kind постачається зі StorageClass `standard` що використовує `rancher.io/local-path` provisioner — створює директорії на вузлі для зберігання даних.

```bash
# Переглянути доступні StorageClasses:
kubectl get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY
# standard (default)   rancher.io/local-path   Delete

# Детальна інформація:
kubectl describe storageclass standard
```

**Важливо для kind:** `standard` provisioner використовує `hostPath` — дані зберігаються в директорії Docker контейнера (вузла). При видаленні kind кластеру — дані зникають. Але між перестворенням Pod'ів всередині кластеру — дані зберігаються.

---

## 4. Що таке StatefulSet

**StatefulSet** — контролер Kubernetes для управління stateful додатками. Як Deployment, але з гарантіями:

| | Deployment | StatefulSet |
|--|-----------|------------|
| Імена Pod'ів | Випадкові | Стабільні (`app-0`, `app-1`, ...) |
| Порядок запуску | Довільний | `app-0` → `app-1` → `app-2` |
| Порядок зупинки | Довільний | `app-2` → `app-1` → `app-0` |
| Мережева ідентичність | Змінюється | Стабільна (DNS) |
| Диски | Спільні або порожні | Власний диск для кожного |
| Оновлення | Rolling update | Rolling update (у зворотньому порядку) |

### Коли StatefulSet — правильний вибір

- **Бази даних**: PostgreSQL, MySQL, MongoDB, Cassandra
- **Черги повідомлень**: RabbitMQ, Kafka
- **Розподілені сховища**: Redis Cluster, Elasticsearch
- **Будь-що що зберігає стан на диску і потребує стабільного DNS-імені**

---

## 5. Стабільна ідентичність

### Стабільні імена Pod'ів

У StatefulSet Pod'и отримують предбачувані імена: `<statefulset-name>-<ordinal>`.

```
StatefulSet: postgres
  Pod 0: postgres-0
  Pod 1: postgres-1
  Pod 2: postgres-2
```

Ці імена **не змінюються** між рестартами. Навіть якщо Pod видалено і створено заново — він повернеться з тим самим іменем.

```bash
# Видаляємо postgres-0:
kubectl delete pod postgres-0

# Pod відновлюється... з тим самим іменем:
kubectl get pods
# NAME         READY   STATUS    RESTARTS
# postgres-0   1/1     Running   1          ← те саме ім'я!
# postgres-1   1/1     Running   0
```

### Стабільна мережева ідентичність

У поєднанні з Headless Service (секція 7) кожен Pod StatefulSet отримує стабільний DNS запис:

```
<pod-name>.<headless-service-name>.<namespace>.svc.cluster.local

postgres-0.postgres-headless.default.svc.cluster.local → 10.244.1.5
postgres-1.postgres-headless.default.svc.cluster.local → 10.244.2.3
postgres-2.postgres-headless.default.svc.cluster.local → 10.244.1.8
```

Навіть після рестарту `postgres-0` і отримання нового IP — DNS запис оновиться і знову вказуватиме на `postgres-0`. Replica знає що master завжди доступний по `postgres-0.postgres-headless`.

---

## 6. VolumeClaimTemplates

### Спільний диск проти власного диску

**Deployment з одним PVC (неправильно для БД):**
```
PVC: postgres-data (один на всіх)
├── Pod 1: читає і пише в postgres-data
├── Pod 2: читає і пише в postgres-data   ← конфлікт!
└── Pod 3: читає і пише в postgres-data   ← дані кошуються
```

Три репліки PostgreSQL не можуть писати в один файл бази даних одночасно.

**StatefulSet з VolumeClaimTemplates (правильно):**
```
VolumeClaimTemplate: postgres-data
├── Pod postgres-0: отримує PVC postgres-data-postgres-0   ← власний диск
├── Pod postgres-1: отримує PVC postgres-data-postgres-1   ← власний диск
└── Pod postgres-2: отримує PVC postgres-data-postgres-2   ← власний диск
```

Кожен Pod StatefulSet отримує **власний PVC** з передбачуваним іменем `<template-name>-<pod-name>`.

### Як виглядає VolumeClaimTemplates

```yaml
spec:
  # Цей шаблон замінює spec.template.spec.volumes + окремі PVC маніфести
  volumeClaimTemplates:
    - metadata:
        name: postgres-data          # назва → PVC = postgres-data-postgres-0
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: standard
        resources:
          requests:
            storage: 1Gi
```

При створенні StatefulSet з 3 репліками автоматично створиться:
- `postgres-data-postgres-0` (PVC)
- `postgres-data-postgres-1` (PVC)
- `postgres-data-postgres-2` (PVC)

### Важлива особливість: PVC не видаляється при масштабуванні до нуля

```bash
# Масштабуємо до 0:
kubectl scale statefulset postgres --replicas=0

# Pod'и зникають, але PVC залишаються!
kubectl get pvc
# NAME                       STATUS   CAPACITY
# postgres-data-postgres-0   Bound    1Gi     ← PVC живий, дані збережені
# postgres-data-postgres-1   Bound    1Gi
# postgres-data-postgres-2   Bound    1Gi

# Масштабуємо назад до 3:
kubectl scale statefulset postgres --replicas=3
# Pod'и підключаться до своїх PVC — дані повернуться
```

PVC видаляється тільки при явному `kubectl delete pvc postgres-data-postgres-0`. При видаленні StatefulSet PVC теж **залишаються** (захист від випадкової втрати даних).

---

## 7. Headless Service

### Навіщо Headless Service для StatefulSet

Звичайний ClusterIP Service балансує трафік між Pod'ами — не дозволяє звернутись до конкретного Pod'у. Але для StatefulSet потрібно:
- Підключити replica до конкретного master (postgres-0)
- Дати кожному Pod'у стабільне DNS-ім'я

**Headless Service** (`clusterIP: None`) не дає балансування — замість цього кожен Pod отримує власний DNS запис.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-headless
spec:
  clusterIP: None        # headless — без балансування
  selector:
    app: postgres
  ports:
    - port: 5432
      name: postgres
```

DNS поведінка:
```bash
# Звичайний ClusterIP:
nslookup postgres-svc
→ 10.96.45.123          # один IP

# Headless:
nslookup postgres-headless
→ 10.244.1.5            # IP postgres-0
→ 10.244.2.3            # IP postgres-1
→ 10.244.1.8            # IP postgres-2

# Конкретний Pod:
nslookup postgres-0.postgres-headless
→ 10.244.1.5            # завжди postgres-0
```

### Два Service'и для StatefulSet

У production зазвичай два Service'и:

```
1. Headless Service (postgres-headless, clusterIP: None):
   → для внутрішньої реплікації і DNS-ідентичності Pod'ів
   → підключення replica до master

2. ClusterIP Service (postgres-svc):
   → для додатків (WeatherApi) — прозоре балансування
   → для читання якщо налаштовано read replicas
```

---

## 8. Порядок запуску

### Ordered startup (порядковий запуск)

StatefulSet запускає Pod'и **по черзі, від 0 до N**. Наступний Pod запускається тільки після того як попередній став Ready.

```
StatefulSet postgres, replicas: 3

t=0    postgres-0: Pending → Running → Ready
t=15s  postgres-1: Pending → Running → Ready   (чекав поки postgres-0 став Ready)
t=30s  postgres-2: Pending → Running → Ready   (чекав поки postgres-1 став Ready)
```

Навіщо це потрібно для PostgreSQL:
- `postgres-0` запускається як master
- `postgres-1` запускається як standby — підключається до master (postgres-0.postgres-headless)
- `postgres-2` запускається як standby — те ж саме

Якби запускались паралельно — replica запустилась би раніше master і не могла б підключитись.

### Ordered termination (порядкове завершення)

Зупинка у **зворотному порядку**: від N до 0.

```
kubectl scale statefulset postgres --replicas=0

t=0    postgres-2: Terminating → Gone
t=10s  postgres-1: Terminating → Gone
t=20s  postgres-0: Terminating → Gone
```

Master (postgres-0) зупиняється **останнім** — дає час репліці завершити роботу і скинути незаписані дані.

### Паралельний режим

За замовчуванням StatefulSet використовує `podManagementPolicy: OrderedReady`. Для сценаріїв де порядок не важливий:

```yaml
spec:
  podManagementPolicy: Parallel   # всі Pod'и стартують і зупиняються паралельно
```

Корисно для кластерів де порядок справді не має значення (Cassandra, деякі NoSQL).

---

## 9. Розбір маніфестів: PostgreSQL на StatefulSet

Відкрий файли в `k8s/07-statefulset/`. Розберемо кожен.

### postgres-secret.yaml

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: postgres-secret
stringData:
  password: "workshop-pg-password"       # пароль суперuser postgres
  replication-password: "repl-password"  # пароль для реплікації (для майбутнього)
```

Secret завжди створюємо до StatefulSet — Pod не запуститься без нього.

### postgres-headless-svc.yaml

```yaml
spec:
  clusterIP: None    # headless — ключове поле
  publishNotReadyAddresses: true  # включати Pod'и в DNS навіть якщо Not Ready
```

`publishNotReadyAddresses: true` важливо при ініціалізації кластеру: Pod'и можуть звертатись один до одного ще до того як пройдуть readinessProbe.

### postgres-statefulset.yaml (ключові поля)

```yaml
spec:
  serviceName: postgres-headless  # ОБОВ'ЯЗКОВО: посилання на Headless Service
                                   # без цього StatefulSet не отримає DNS
  replicas: 1                      # для демо — один Pod; production: 3
  
  template:
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - name: POSTGRES_DB
              value: weatherdb
            - name: POSTGRES_USER
              value: weather_user
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
              # PGDATA вказує у піддиректорію — вирішує проблему kind:
              # local-path provisioner створює директорію з lost+found,
              # а postgres не хоче ініціалізуватись в непорожній директорії
  
  volumeClaimTemplates:
    - metadata:
        name: postgres-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: standard    # kind's default StorageClass
        resources:
          requests:
            storage: 1Gi
```

### Чому `serviceName` обов'язковий

`spec.serviceName` — ім'я Headless Service — потрібний щоб StatefulSet міг побудувати DNS-ім'я для кожного Pod'у. Без нього Pod'и не матимуть передбачуваних DNS записів.

---

## 10. Практика

### Крок 1: Перевірка середовища

```bash
kubectl config current-context
kubectl get nodes

# Перевіряємо StorageClass:
kubectl get storageclass
# standard (default) — повинен бути
```

### Крок 2: Застосовуємо Secret

```bash
kubectl apply -f k8s/07-statefulset/postgres-secret.yaml

# Перевіряємо (значення приховані — нормально):
kubectl get secret postgres-secret
kubectl describe secret postgres-secret
```

### Крок 3: Застосовуємо Services

```bash
# Headless Service (для DNS StatefulSet Pod'ів):
kubectl apply -f k8s/07-statefulset/postgres-headless-svc.yaml

# Client Service (для з'єднання WeatherApi):
kubectl apply -f k8s/07-statefulset/postgres-client-svc.yaml

kubectl get services
# NAME                 TYPE        CLUSTER-IP    PORT(S)
# postgres-headless    ClusterIP   None          5432/TCP   ← headless (None)
# postgres-svc         ClusterIP   10.96.88.50   5432/TCP   ← для клієнтів
```

### Крок 4: Застосовуємо StatefulSet

```bash
kubectl apply -f k8s/07-statefulset/postgres-statefulset.yaml

# Спостерігаємо за порядковим запуском:
kubectl get pods --watch
# NAME         READY   STATUS              RESTARTS   AGE
# postgres-0   0/1     ContainerCreating   0          2s
# postgres-0   0/1     Running             0          5s
# postgres-0   1/1     Running             0          20s  ← став Ready → наступний Pod міг би стартувати
```

### Крок 5: Перевіряємо StatefulSet

```bash
# Статус StatefulSet:
kubectl get statefulset
# NAME       READY   AGE
# postgres   1/1     1m

# Детально:
kubectl describe statefulset postgres

# Pod:
kubectl get pods -l app=postgres

# PVC що був створений автоматично:
kubectl get pvc
# NAME                       STATUS   VOLUME         CAPACITY   ACCESS MODES
# postgres-data-postgres-0   Bound    pvc-abc123def  1Gi        RWO
```

### Крок 6: Підключаємось до PostgreSQL і створюємо дані

```bash
# Заходимо в Pod:
kubectl exec -it postgres-0 -- psql -U weather_user -d weatherdb

# Всередині psql:
CREATE TABLE cities (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    country VARCHAR(50)
);

INSERT INTO cities (name, country) VALUES
    ('Lviv', 'Ukraine'),
    ('Kyiv', 'Ukraine'),
    ('Warsaw', 'Poland');

SELECT * FROM cities;
--  id | name   | country
-- ----+--------+---------
--   1 | Lviv   | Ukraine
--   2 | Kyiv   | Ukraine
--   3 | Warsaw | Poland

\q
```

---

## 11. ДЕМО: Дані виживають після смерті Pod'у

Це ключовий момент уроку. Порівняємо поведінку з Deployment (Урок 1-2).

### Що відбувалось у Deployment (згадуємо Урок 2)

```bash
# У Deployment: Pod видалено → нові дані в пам'яті
# Диск контейнера знищується разом з Pod'ом
```

### StatefulSet: Pod видалено → PVC залишається → дані збережені

```bash
# Термінал 1: спостерігаємо за Pod'ами
kubectl get pods --watch

# Термінал 2: видаляємо postgres-0
kubectl delete pod postgres-0

# У терміналі 1 побачимо:
# NAME         READY   STATUS        RESTARTS
# postgres-0   1/1     Terminating   0
# postgres-0   0/1     Pending       0          ← знову починає запускатись!
# postgres-0   1/1     Running       1          ← той самий Pod, той самий PVC
```

### Перевіряємо що дані збереглись

```bash
# Після того як postgres-0 знову Running:
kubectl exec -it postgres-0 -- psql -U weather_user -d weatherdb

# Перевіряємо:
SELECT * FROM cities;
--  id | name   | country
-- ----+--------+---------
--   1 | Lviv   | Ukraine
--   2 | Kyiv   | Ukraine
--   3 | Warsaw | Poland
-- (3 rows)

\q
```

**Дані вижили!** Pod був видалений і відтворений, але PVC `postgres-data-postgres-0` залишився і PostgreSQL підхопив дані звідти.

### Що відбулось покроково

```
1. kubectl delete pod postgres-0
   → API Server: Pod видалено з etcd
   → kubelet: контейнер зупинено, файлова система контейнера видалена
   
   Але: PVC postgres-data-postgres-0 ЗАЛИШАЄТЬСЯ (він не є частиною Pod'у)

2. StatefulSet Controller помічає: desired=1, actual=0
   → Створює новий postgres-0
   → Scheduler призначає на вузол

3. kubelet запускає новий контейнер
   → К8s підключає ТОЙ САМИЙ PVC postgres-data-postgres-0
   → PostgreSQL знаходить /var/lib/postgresql/data/pgdata — не порожня директорія!
   → PostgreSQL стартує в режимі "відновлення" і підключає існуючу базу

4. postgres-0 Ready → дані доступні
```

---

## 12. ДЕМО: DNS для окремих Pod'ів

### Перевіряємо DNS-імена зсередини кластеру

```bash
# Запускаємо тимчасовий Pod з curl і nslookup:
kubectl run dns-test \
  --image=curlimages/curl:latest \
  --restart=Never \
  --rm \
  -it \
  -- sh

# Всередині Pod'у:

# Перевіряємо headless DNS — повертає IP Pod'у напряму:
nslookup postgres-headless
# Server:  10.96.0.10
# Name:    postgres-headless.default.svc.cluster.local
# Address: 10.244.1.5    ← IP postgres-0 напряму (не ClusterIP!)

# Підключаємось до конкретного Pod'у через стабільне DNS-ім'я:
nslookup postgres-0.postgres-headless
# Name:    postgres-0.postgres-headless.default.svc.cluster.local
# Address: 10.244.1.5    ← завжди postgres-0, навіть після рестарту

# Порівняємо з client Service (ClusterIP):
nslookup postgres-svc
# Name:    postgres-svc.default.svc.cluster.local
# Address: 10.96.88.50   ← ClusterIP для балансування

exit
```

### Підключення до PostgreSQL через psql client Pod

```bash
# Запускаємо psql client і підключаємось до postgres через ClusterIP Service:
kubectl run psql-client \
  --image=postgres:16-alpine \
  --restart=Never \
  --rm \
  -it \
  --env="PGPASSWORD=workshop-pg-password" \
  -- psql -h postgres-svc -U weather_user -d weatherdb

# Або через конкретний Pod (headless):
kubectl run psql-client \
  --image=postgres:16-alpine \
  --restart=Never \
  --rm \
  -it \
  --env="PGPASSWORD=workshop-pg-password" \
  -- psql -h postgres-0.postgres-headless -U weather_user -d weatherdb

# Перевіряємо:
SELECT current_database(), inet_server_addr();
\q
```

---

## 13. Коли StatefulSet, коли Deployment?

### Вибір між StatefulSet і Deployment

```
Питання 1: Додаток зберігає стан на диску?
  НІ  → Deployment (WeatherApi, nginx, REST API)
  ТАК → Питання 2

Питання 2: Всі екземпляри взаємозамінні?
  ТАК → Deployment з PVC (кожен Pod монтує спільний ReadWriteMany диск)
  НІ  → StatefulSet (PostgreSQL, Kafka, Redis Cluster)

Питання 3: Потрібне стабільне мережеве ім'я або порядок запуску?
  ТАК → StatefulSet
  НІ  → Deployment
```

### Приклади

| Сервіс | Тип | Причина |
|--------|-----|---------|
| WeatherApi | Deployment | Stateless REST API |
| nginx | Deployment | Stateless proxy |
| PostgreSQL | StatefulSet | Стан на диску, реплікація |
| Redis (single) | Deployment | Можна перезапустити (cache) |
| Redis Cluster | StatefulSet | Потрібна стабільна ідентичність |
| RabbitMQ | StatefulSet | Черги не повинні зникати |
| Kafka | StatefulSet | Ordered topics, persistent logs |
| Elasticsearch | StatefulSet | Shards, реплікація |

### Примітка про Redis

Redis як **кеш** (eviction: allkeys-lru) — можна Deployment: дані можна втратити, це нормально для кешу.
Redis як **persistent store** (AOF/RDB persistence) — StatefulSet: дані важливі.

---

## 14. Типові помилки

### Помилка 1: Забути serviceName

```yaml
spec:
  # serviceName: відсутній!
  replicas: 3
```

Kubernetes відхилить StatefulSet: `spec.serviceName: Required value`.

Без serviceName Pod'и не отримають DNS записів `pod-name.service-name.namespace.svc.cluster.local`.

### Помилка 2: Видалити StatefulSet і думати що PVC видаляться теж

```bash
kubectl delete statefulset postgres
# StatefulSet видалено, Pod'и видалено
# АЛЕ:
kubectl get pvc
# postgres-data-postgres-0   Bound    1Gi   ← PVC ЖИВИЙ
# postgres-data-postgres-1   Bound    1Gi   ← і цей теж
```

PVC залишаються після видалення StatefulSet. Це і захист (від випадкової втрати), і потенційна проблема (займають місце на диску і в Storage квоті).

Якщо хочеш видалити все включно з даними:
```bash
kubectl delete statefulset postgres
kubectl delete pvc -l app=postgres    # або конкретні імена
```

### Помилка 3: Використати Deployment для PostgreSQL в production

```yaml
# НЕ РОБІТЬ ТАК:
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  template:
    spec:
      volumes:
        - name: data
          emptyDir: {}    # порожній диск, зникає при рестарті!
```

`emptyDir` — тимчасовий диск, що існує тільки поки Pod живий. Будь-який рестарт = втрата всієї бази. Навіть з PVC але Deployment — при rolling update може виникнути ситуація де два Pod'и намагаються монтувати один RWO volume (лише один може).

### Помилка 4: PostgreSQL не стартує через непорожню директорію (kind)

```bash
kubectl logs postgres-0
# FATAL: data directory "/var/lib/postgresql/data" has wrong ownership
# або:
# initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
```

Причина: kind's local-path provisioner створює директорію і там є `lost+found`. PostgreSQL відмовляється ініціалізуватись в непорожній директорії.

Виправлення: завжди встановлюй `PGDATA` в піддиректорію:
```yaml
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata   # піддиректорія, не корінь mount
```

### Помилка 5: Масштабувати StatefulSet до нуля очікуючи що PVC видаляться

```bash
kubectl scale statefulset postgres --replicas=0
# Pod'и зникають, але PVC залишаються!
# При масштабуванні назад — ті самі дані
```

Це поведінка за задумом, але часто дивує. Якщо потрібно "почати з нуля" — треба явно видалити PVC.

### Помилка 6: RollingUpdate без урахування порядку для кластерних баз

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 1    # оновлюємо тільки Pod'и від 1 і вище, залишаємо postgres-0 незмінним
```

При оновленні кластерної БД (3 вузли: 1 master + 2 replica) потрібно:
1. Спочатку оновити репліки (postgres-2, postgres-1)
2. Виконати failover (postgres-1 стає master)
3. Тільки потім оновити старий master (postgres-0)

`partition` в StatefulSet дозволяє контролювати це. Без нього K8s оновить all pods від N до 0 — ризик.

---

## 15. Підсумок і вправи

### Що ми вивчили

**PV і PVC** — абстракція над сховищем. PV = реальний диск. PVC = запит на диск. K8s автоматично знаходить відповідний PV або запитує новий у provisioner'а.

**StorageClass** — рецепт автоматичного provisioning. У kind: `standard` (local-path). У AWS: `gp2/gp3` (EBS). При появі PVC — provisioner сам створює диск.

**StatefulSet** — для stateful додатків. Кожен Pod має стабільне ім'я (`postgres-0`), стабільний DNS (`postgres-0.postgres-headless`), власний PVC (`postgres-data-postgres-0`).

**VolumeClaimTemplates** — автоматично створюють PVC для кожного Pod'у. PVC переживають видалення Pod'ів і навіть видалення StatefulSet.

**Headless Service** (`clusterIP: None`) — дає кожному Pod'у StatefulSet унікальний DNS запис.

### Команди уроку — шпаргалка

```bash
# StatefulSet:
kubectl get statefulset
kubectl describe statefulset postgres
kubectl scale statefulset postgres --replicas=3
kubectl rollout status statefulset postgres

# PVC і PV:
kubectl get pvc
kubectl describe pvc postgres-data-postgres-0
kubectl get pv
kubectl get storageclass

# Підключення до Pod'у:
kubectl exec -it postgres-0 -- psql -U weather_user -d weatherdb

# DNS перевірка (зсередині кластеру):
kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -it -- sh
# nslookup postgres-0.postgres-headless

# Видалення (PVC залишаються!):
kubectl delete statefulset postgres
kubectl delete pvc -l app=postgres    # видалити PVC вручну
```

### Вправи

**Вправа 1 — Легка:**
Після розгортання PostgreSQL виконай `kubectl get pvc` і переконайся що PVC `postgres-data-postgres-0` існує. Видали Pod `postgres-0` і спостерігай як він відновлюється. Зайди в psql і переконайся що таблиця `cities` і дані збереглись.

**Вправа 2 — Середня:**
Масштабуй StatefulSet до 0 репліків (`kubectl scale statefulset postgres --replicas=0`). Перевір що PVC залишились. Масштабуй назад до 1. Зайди в psql і переконайся що дані збереглись після повної зупинки і старту.

**Вправа 3 — Складна:**
Додай другий Pod в StatefulSet (`--replicas=2`) і спостерігай за порядком запуску через `kubectl get pods --watch`. Перевір що `postgres-1` стартував тільки після того як `postgres-0` став Ready. Зайди в `postgres-1` і переконайся що це окремий PostgreSQL примірник (своя база, без даних з postgres-0). Поясни: чому реплікація між ними не відбулась автоматично — що для цього потрібно додатково?

### Питання для роздумів

- Якщо `reclaimPolicy: Delete` для StorageClass — що відбувається з реальним диском (наприклад, AWS EBS) при видаленні PVC? Коли це безпечно і коли небезпечно?
- Headless Service повертає DNS-записи для NOT Ready Pod'ів якщо встановлено `publishNotReadyAddresses: true`. Навіщо це потрібно при ініціалізації PostgreSQL кластеру з реплікацією?
- Як оновити образ PostgreSQL в StatefulSet (наприклад, з 15 на 16) без втрати даних? Якими кроками ти б це зробив в production?

---

## Наступний урок

**Урок 8: Namespace і RBAC — Ізоляція і контроль доступу**

До цього все що ми робили жило в namespace `default`. У реальних компаніях різні команди і середовища (dev, staging, production) ізолюють через Namespaces. Але ізоляція без контролю доступу — не захист. RBAC (Role-Based Access Control) дозволяє точно визначити хто і що може робити в кластері. У наступному уроці:
- Namespaces як логічне розділення кластеру
- ServiceAccount — ідентичність Pod'у всередині кластеру
- Role і ClusterRole — набір дозволів
- RoleBinding — хто отримує які дозволи
- Демо: Pod що може читати секрети в своєму namespace, але не в чужому

---

*Урок підготовлено для Kubernetes Workshop. Версія K8s: 1.29+*
