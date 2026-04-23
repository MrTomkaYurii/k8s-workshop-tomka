# Урок 2: Deployment — Самовідновлювальний відряд Pod'ів

> **Рівень:** Початківець (потрібен Урок 1)
> **Тривалість:** ~60 хвилин
> **Що потрібно:** Запущений кластер з Уроку 1
> **Що отримаєш:** Deployment з трьома репліками, живе демо самовідновлення, rolling update

---

## Зміст

1. [Проблема: чому голого Pod'у недостатньо](#1-проблема)
2. [ReplicaSet — хранитель кількості](#2-replicaset)
3. [Deployment — менеджер оновлень](#3-deployment)
4. [Reconciliation loop — серце Kubernetes](#4-reconciliation-loop)
5. [Розбір deployment.yaml поле за полем](#5-розбір-deploymentyaml)
6. [Практика: створюємо Deployment](#6-практика)
7. [ДЕМО: вбиваємо Pod — він воскресає](#7-демо-самовідновлення)
8. [Масштабування: більше реплік за одну команду](#8-масштабування)
9. [Стратегії оновлення: RollingUpdate і Recreate](#9-стратегії-оновлення)
10. [Типові помилки](#10-типові-помилки)
11. [Підсумок і вправи](#11-підсумок-і-вправи)

---

## 1. Проблема

В Уроці 1 ми бачили: видалили Pod — він зник назавжди. В реальному сервісі це катастрофа. Будь-яке падіння контейнера, перезавантаження вузла або ручне видалення — і сервіс недоступний.

Але є ще три проблеми, які голий Pod не вирішує навіть якщо він є.

### Проблема 1: немає самовідновлення

```
[Pod впав] --> нічого не відбувається --> сервіс недоступний
```

Хтось повинен помітити що Pod впав і запустити новий. Голий Pod нікому не підзвітний.

### Проблема 2: немає масштабування

Якщо на сервіс прийшло більше запитів ніж один Pod може обробити — ти нічого не можеш зробити "по-K8s". Можна лише вручну запустити ще один Pod з тим самим іменем — але K8s не дасть, імена унікальні.

### Проблема 3: немає безпечного оновлення

Щоб оновити образ у голому Pod'і, треба:
1. Видалити старий Pod — сервіс падає
2. Запустити новий з новим образом — сервіс піднімається

Між кроками 1 і 2 є простій. В production так не можна.

### Що нам потрібно

Нам потрібен об'єкт, який:
- стежить за кількістю запущених Pod'ів
- якщо Pod'ів менше ніж потрібно — запускає нові
- якщо Pod'ів більше ніж потрібно — видаляє зайві
- вміє оновлювати Pod'и поступово, без простою

Цей об'єкт називається **ReplicaSet**. А об'єкт, який управляє ReplicaSet'ами під час оновлень — **Deployment**.

---

## 2. ReplicaSet

**ReplicaSet** (набір реплік) — контролер який гарантує що в кластері завжди запущено рівно N копій Pod'ів.

### Як ReplicaSet знаходить свої Pod'и

ReplicaSet не зберігає список "своїх" Pod'ів всередині себе. Натомість він шукає Pod'и за **мітками** (labels) через **selector**.

```
ReplicaSet:
  selector:
    matchLabels:
      app: weather-api    <-- шукаю Pod'и з цією міткою

Pod 1: labels: { app: weather-api }  --> ReplicaSet вважає своїм
Pod 2: labels: { app: weather-api }  --> ReplicaSet вважає своїм
Pod 3: labels: { app: other-app }    --> ReplicaSet ігнорує
```

Кожні кілька секунд ReplicaSet Controller запитує API Server: "Скільки Pod'ів з міткою `app: weather-api` зараз запущено?"

- Якщо менше ніж `replicas` — створює нові Pod'и за шаблоном `template`
- Якщо більше — видаляє зайві (але спочатку ті, що найновіші або на перевантажених вузлах)
- Якщо рівно — нічого не робить

### Чому ми не пишемо ReplicaSet напряму

Можна. Але тоді ти втрачаєш механізм оновлень. ReplicaSet сам по собі не вміє плавно переходити від одного образу до іншого. Якщо змінити `template.spec.containers.image` в ReplicaSet — існуючі Pod'и не перестворяться, бо ReplicaSet бачить що кількість вірна.

Саме тому ми використовуємо **Deployment**, який створює нові ReplicaSet'и при оновленнях і поступово переключає трафік між ними.

---

## 3. Deployment

**Deployment** — декларативний опис того як розгорнути і оновити Pod'и.

Ключове слово — **декларативний**. Ти описуєш **бажаний стан**, а не команди "зроби ось це". Kubernetes сам вирішує як досягти цього стану.

```
Ти говориш:               Kubernetes робить:
"Хочу 3 копії             Перевіряє поточний стан.
 образу weather-api:1.0"  Якщо є 1 Pod → запускає ще 2.
                          Якщо є 5 Pod'ів → видаляє 2.
                          Якщо є 3 Pod'и → нічого.
```

### Ієрархія об'єктів

```
Deployment
  └── ReplicaSet (v1.0)   <-- поточна
        ├── Pod 1
        ├── Pod 2
        └── Pod 3

Після оновлення образу до v2.0:

Deployment
  ├── ReplicaSet (v1.0)   <-- стара (поступово спустошується)
  │     ├── Pod 1  <-- видаляється
  │     └── Pod 2  <-- видаляється
  └── ReplicaSet (v2.0)   <-- нова (поступово наповнюється)
        ├── Pod 3
        ├── Pod 4
        └── Pod 5
```

Deployment зберігає **історію** ReplicaSet'ів. Це дозволяє зробити rollback: "поверни мені стару версію" — Deployment просто масштабує стару ReplicaSet назад.

---

## 4. Reconciliation Loop

Перш ніж практикуватись, важливо зрозуміти головний принцип роботи Kubernetes — **reconciliation loop** (цикл узгодження).

### Принцип: desired state vs actual state

```
Desired State           Actual State
(що записано в etcd)    (що реально запущено)
        |                       |
        |<------- різниця ------>|
                    |
                    v
           Controller аналізує різницю
           і виконує дії щоб її усунути
```

Це відбувається **безперервно**, кожні кілька секунд. Ніяких "eventів" або "тригерів" для більшості операцій — просто постійна перевірка.

### Приклад: вбили Pod

```
Стан до:
  Desired: replicas=3
  Actual: Pod-1 running, Pod-2 running, Pod-3 running  --> рівно 3, все добре

Ти видаляєш Pod-2:
  Actual: Pod-1 running, Pod-3 running  --> тільки 2!

ReplicaSet Controller помічає різницю:
  Desired: 3
  Actual: 2
  Дія: створити 1 Pod

Новий стан:
  Actual: Pod-1 running, Pod-3 running, Pod-4 running  --> знову 3
```

Ось чому Kubernetes "самовідновлюється" — це не магія, це просто нескінченний цикл порівняння.

### Приклад: вузол впав

```
Worker Node 2 перестає відповідати...

Node Controller чекає 5 хвилин.
Потім позначає Pod'и на цьому вузлі як Unknown.

ReplicaSet Controller бачить:
  Desired: 3
  Actual: 1 running + 2 unknown = не можна довіряти
  Дія: запустити 2 нових Pod'и на інших вузлах
```

---

## 5. Розбір deployment.yaml

Відкрий файл `k8s/02-deployment/deployment.yaml`. Розберемо кожне поле.

```yaml
apiVersion: apps/v1   # Deployment живе в групі apps, версія v1
kind: Deployment
```

Чому `apps/v1`, а не `v1`? Deployment — "вищорівневий" об'єкт, він доданий пізніше ніж Pod і живе в іншій API групі. Аналогічно: `apps/v1` — StatefulSet, DaemonSet; `batch/v1` — Job, CronJob.

```yaml
metadata:
  name: weather-api
  namespace: default
  labels:
    app: weather-api
```

Мітки на самому Deployment — для пошуку Deployment'у. Вони не впливають на те, які Pod'и він контролює. Це часта плутанина у початківців.

```yaml
spec:
  replicas: 3
```

Бажана кількість Pod'ів. Якщо видалити це поле — за замовчуванням буде 1. Змінюється командою або правкою файлу + `kubectl apply`.

```yaml
  selector:
    matchLabels:
      app: weather-api
```

Критично важлива частина. Deployment (через ReplicaSet) шукатиме Pod'и з точно такими мітками. Значення `selector.matchLabels` **обов'язково** повинно збігатись з мітками в `template.metadata.labels`. Якщо не збігається — K8s відхилить об'єкт.

```yaml
  template:
    metadata:
      labels:
        app: weather-api
        version: "1.0"
    spec:
      containers:
        - name: weather-api
          image: nginx:alpine
```

`template` — це шаблон Pod'у. Все що тут написано — ReplicaSet використовуватиме для створення кожного нового Pod'у. Зверни увагу: `template` не має поля `name` — імена Pod'ів генеруються автоматично (deployment-name + replicaset-hash + random).

```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

Стратегія оновлення. Детально розберемо в секції 9.

---

## 6. Практика

Переконайся що кластер запущений:

```bash
# Перевірити поточний контекст
kubectl config current-context
# Очікувано: kind-workshop

# Переконатись що вузли готові
kubectl get nodes
# Всі три вузли повинні бути Ready
```

Якщо кластер не запущений — створи його:

```bash
kind create cluster --name workshop --config k8s/00-cluster/kind-config.yaml
```

### Крок 1: Застосовуємо Deployment

```bash
kubectl apply -f k8s/02-deployment/deployment.yaml
# Виведе: deployment.apps/weather-api created
```

### Крок 2: Спостерігаємо за запуском

```bash
# Спостерігаємо в реальному часі (-w = --watch)
kubectl get pods -w

# Побачимо щось подібне:
# NAME                           READY   STATUS              RESTARTS   AGE
# weather-api-7d6b8f9c4-xk2pt   0/1     ContainerCreating   0          2s
# weather-api-7d6b8f9c4-9nqr7   0/1     ContainerCreating   0          2s
# weather-api-7d6b8f9c4-m8vbw   0/1     ContainerCreating   0          2s
# weather-api-7d6b8f9c4-xk2pt   1/1     Running             0          8s
# weather-api-7d6b8f9c4-9nqr7   1/1     Running             0          9s
# weather-api-7d6b8f9c4-m8vbw   1/1     Running             0          10s
```

Натисни Ctrl+C щоб вийти з режиму watch.

### Крок 3: Розуміємо імена Pod'ів

```
weather-api  -  7d6b8f9c4  -  xk2pt
     |               |            |
 Deployment     ReplicaSet    Унікальний
   name           hash        суфікс Pod'у
```

Якщо зробити rolling update — другий сегмент (ReplicaSet hash) зміниться, бо буде створено новий ReplicaSet.

### Крок 4: Перевіряємо ReplicaSet

```bash
# Бачимо ReplicaSet що створив Deployment
kubectl get replicasets
# або скорочено:
kubectl get rs

# NAME                       DESIRED   CURRENT   READY   AGE
# weather-api-7d6b8f9c4     3         3         3       1m
```

`DESIRED` — скільки ReplicaSet хоче Pod'ів.
`CURRENT` — скільки Pod'ів існує.
`READY` — скільки Pod'ів пройшли readiness перевірку.

```bash
# Перевіряємо сам Deployment
kubectl get deployments
# або:
kubectl get deploy

# NAME          READY   UP-TO-DATE   AVAILABLE   AGE
# weather-api   3/3     3            3           2m
```

`UP-TO-DATE` — скільки Pod'ів запущено з актуальною конфігурацією.
`AVAILABLE` — скільки Pod'ів готові приймати трафік.

### Крок 5: Детальна інформація про Deployment

```bash
kubectl describe deployment weather-api
```

Зверни увагу на секцію `Events` — там видно як Deployment масштабував ReplicaSet:

```
Events:
  Normal  ScalingReplicaSet  2m  deployment-controller
    Scaled up replica set weather-api-7d6b8f9c4 to 3
```

### Крок 6: Де запущені Pod'и

```bash
# Показати Pod'и з інформацією про вузол
kubectl get pods -o wide

# NAME                           READY   STATUS    IP           NODE
# weather-api-7d6b8f9c4-xk2pt   1/1     Running   10.244.1.3   workshop-worker
# weather-api-7d6b8f9c4-9nqr7   1/1     Running   10.244.2.4   workshop-worker2
# weather-api-7d6b8f9c4-m8vbw   1/1     Running   10.244.1.5   workshop-worker
```

Scheduler намагається розподілити Pod'и рівномірно між вузлами. З двома worker nodes і трьома Pod'ами розподіл буде нерівний (2+1), але Scheduler робить найкраще що може.

---

## 7. ДЕМО: Самовідновлення

Це ключовий момент уроку. Порівняємо з тим що було в Уроці 1.

### В Уроці 1 (голий Pod)

```bash
# Що ми бачили:
kubectl delete pod weather-pod
# --> Pod зник назавжди
kubectl get pods
# --> No resources found
```

### Зараз (Pod під Deployment)

```bash
# Запам'ятовуємо імена Pod'ів
kubectl get pods
# NAME                           READY   STATUS
# weather-api-7d6b8f9c4-xk2pt   1/1     Running
# weather-api-7d6b8f9c4-9nqr7   1/1     Running
# weather-api-7d6b8f9c4-m8vbw   1/1     Running

# Видаляємо один Pod (замінити ім'я на реальне з твого кластеру)
kubectl delete pod weather-api-7d6b8f9c4-xk2pt
```

Одразу після видалення відкрий другий термінал:

```bash
# В окремому терміналі спостерігаємо
kubectl get pods -w
```

Ти побачиш:

```
NAME                           READY   STATUS        RESTARTS
weather-api-7d6b8f9c4-xk2pt   1/1     Terminating   0         <-- видаляється
weather-api-7d6b8f9c4-9nqr7   1/1     Running       0
weather-api-7d6b8f9c4-m8vbw   1/1     Running       0
weather-api-7d6b8f9c4-r9kl2   0/1     Pending       0         <-- новий!
weather-api-7d6b8f9c4-r9kl2   1/1     Running       0         <-- запустився
```

Pod відновився. Зверни увагу — це **інший** Pod (суфікс `r9kl2` замість `xk2pt`). Це не той самий Pod, що "воскрес" — це новий Pod, створений ReplicaSet Controller'ом.

### Що відбулось покроково

```
1. kubectl delete pod weather-api-...-xk2pt
   --> API Server позначає Pod як "видалено" в etcd

2. ReplicaSet Controller помічає:
   desired=3, actual=2 (тільки два Pod'и живі)

3. ReplicaSet Controller робить запит до API Server:
   "Створи новий Pod за шаблоном template"

4. Scheduler призначає Pod на вузол

5. kubelet на вузлі запускає контейнер

6. Новий Pod з'являється зі статусом Running
   desired=3, actual=3 -- баланс відновлено
```

Весь цей процес займає 5-15 секунд залежно від розміру образу та навантаження.

### Перевіряємо що Pod'ів знову три

```bash
kubectl get pods
# Три Pod'и, один з новим суфіксом -- це норма
```

---

## 8. Масштабування

Масштабування в Kubernetes — зміна кількості реплік.

### Imperative масштабування (швидко, для дебагу)

```bash
# Збільшити до 5 реплік
kubectl scale deployment weather-api --replicas=5

# Перевірити
kubectl get pods
# Буде 5 Pod'ів
```

### Declarative масштабування (правильно, для production)

Відредагуй `deployment.yaml`: змінити `replicas: 3` на `replicas: 5`, потім:

```bash
kubectl apply -f k8s/02-deployment/deployment.yaml
```

Навіщо declarative? Бо зміна в командному рядку не зберігається в git. Через тиждень ніхто не знатиме чому в production 5 Pod'ів замість 3, написаних у файлі. Командний рядок використовуй тільки для тимчасових змін під час дебагу.

### Масштабування до нуля

```bash
# Зупинити всі Pod'и але зберегти Deployment
kubectl scale deployment weather-api --replicas=0

kubectl get pods
# No resources found -- Pod'и зупинені, але Deployment існує

# Повернути
kubectl scale deployment weather-api --replicas=3
```

Масштабування до нуля корисне коли хочеш зупинити сервіс але зберегти його конфігурацію. Наприклад, нічна зупинка dev-середовища для економії ресурсів.

### Перевірка статусу масштабування

```bash
# Стан Deployment під час масштабування
kubectl rollout status deployment weather-api

# Виведе:
# Waiting for deployment "weather-api" rollout to finish: 2 of 5 updated replicas are available...
# deployment "weather-api" successfully rolled out
```

---

## 9. Стратегії оновлення

Kubernetes підтримує дві стратегії оновлення Deployment'у.

### RollingUpdate (за замовчуванням)

Поступова заміна: спочатку запускається кілька нових Pod'ів, потім видаляється стільки ж старих.

```
До оновлення:        [v1] [v1] [v1]

Крок 1 -- maxSurge=1:  [v1] [v1] [v1] [v2]    (4 Pod'и на секунду)
Крок 2:                [v1] [v1] [v2]          (видалили 1 старий)
Крок 3:                [v1] [v1] [v2] [v2]     (запустили ще 1 новий)
Крок 4:                [v1] [v2] [v2]          (видалили ще 1 старий)
...і так далі поки не залишилось тільки [v2]
```

Параметри:
- `maxSurge: 1` — максимум скільки додаткових Pod'ів може бути одночасно (`replicas + maxSurge`)
- `maxUnavailable: 0` — скільки Pod'ів можна вимкнути одночасно

При `maxUnavailable: 0` — сервіс ніколи не має менше ніж `replicas` Pod'ів. Ніякого простою.

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1         # в числах або відсотках ("25%")
    maxUnavailable: 0   # 0 = нульовий простій
```

### Recreate

Спочатку видаляє ВСІ Pod'и, потім створює нові. Є простій.

```
До:    [v1] [v1] [v1]
Після: []   []   []    <-- простій
Після: [v2] [v2] [v2]
```

Коли використовувати Recreate:
- Сервіс не може мати дві версії одночасно (наприклад, змінилась схема БД несумісно)
- Тебе не турбує короткий простій (dev-середовище)

```yaml
strategy:
  type: Recreate   # немає додаткових параметрів
```

### Практика: оновлення образу

Зміни образ у `deployment.yaml` з `nginx:alpine` на `nginx:1.27` (нова версія):

```bash
# Варіант 1: через файл (правильно)
# Відредагуй deployment.yaml: image: nginx:1.27
kubectl apply -f k8s/02-deployment/deployment.yaml

# Варіант 2: через командний рядок (для швидких тестів)
kubectl set image deployment/weather-api weather-api=nginx:1.27

# Спостерігаємо за rolling update
kubectl rollout status deployment weather-api
```

### Перегляд і відкат

```bash
# Історія оновлень
kubectl rollout history deployment weather-api

# Виведе:
# REVISION  CHANGE-CAUSE
# 1         <none>
# 2         <none>

# Деталі конкретної ревізії
kubectl rollout history deployment weather-api --revision=1

# Відкат до попередньої версії
kubectl rollout undo deployment weather-api

# Відкат до конкретної ревізії
kubectl rollout undo deployment weather-api --to-revision=1
```

Поле `CHANGE-CAUSE` буде заповнено якщо додати анотацію `kubernetes.io/change-cause`:

```bash
kubectl annotate deployment weather-api \
  kubernetes.io/change-cause="оновлення на nginx 1.27"

kubectl rollout history deployment weather-api
# REVISION  CHANGE-CAUSE
# 2         оновлення на nginx 1.27
```

---

## 10. Типові помилки

### Помилка 1: selector не збігається з template labels

```yaml
# НЕПРАВИЛЬНО -- K8s відхилить цей об'єкт:
spec:
  selector:
    matchLabels:
      app: weather-api   # шукаємо за цією міткою
  template:
    metadata:
      labels:
        app: weather     # але ця мітка інша!
```

Помилка: `selector does not match template labels`

Виправлення: `selector.matchLabels` повинен бути підмножиною `template.metadata.labels`.

### Помилка 2: зміна selector після створення

```bash
# Спробуєш змінити selector у вже існуючого Deployment:
kubectl apply -f deployment.yaml
# Error: spec.selector: Invalid value: ... field is immutable
```

Selector незмінний після створення. Якщо треба змінити — видали Deployment і створи заново.

### Помилка 3: образ з тегом latest

```yaml
image: weather-api:latest   # НЕ рекомендується

image: weather-api:1.2.0    # правильно -- конкретна версія
```

З `:latest` неможливо зробити rollback бо обидві ревізії мають "однаковий" образ. Також ImagePullPolicy за замовчуванням для `:latest` — `Always`, що уповільнює запуск.

### Помилка 4: deploy зависає, Pod'и не стартують

```bash
kubectl rollout status deployment weather-api
# Waiting for deployment "weather-api" rollout to finish...
# (чекає вічно)
```

Діагностика:

```bash
# Дивимось на Pod'и
kubectl get pods
# Можливо: ImagePullBackOff, CrashLoopBackOff

# Дивимось на events
kubectl get events --sort-by='.lastTimestamp'

# Або describe на конкретний Pod
kubectl describe pod weather-api-...-xxxxx
```

Відмінити зависання:

```bash
# Повернутись до попередньої версії
kubectl rollout undo deployment weather-api
```

### Помилка 5: "забули" про PodDisruptionBudget

При масштабуванні до нуля або видаленні Deployment в production, якщо є PodDisruptionBudget (PDB) — операція може зависнути. PDB захищає від того щоб занадто багато Pod'ів вимкнулись одночасно. Якщо `maxUnavailable: 0` в PDB і ти хочеш видалити всі Pod'и — K8s не дасть. Вивчимо в Уроці 8.

---

## 11. Підсумок і вправи

### Що ми вивчили

**ReplicaSet** постійно порівнює бажану кількість Pod'ів з реальною і виправляє різницю. Це основа самовідновлення.

**Deployment** управляє ReplicaSet'ами і забезпечує оновлення без простою через RollingUpdate. Зберігає історію ревізій для rollback.

**Reconciliation loop** — фундаментальний принцип Kubernetes: безперервне порівняння бажаного і реального стану.

### Команди уроку — шпаргалка

```bash
# Deployment
kubectl apply -f deployment.yaml           # створити/оновити
kubectl get deployments                    # список
kubectl describe deployment weather-api   # детально
kubectl delete deployment weather-api     # видалити (і всі Pod'и)

# Масштабування
kubectl scale deployment weather-api --replicas=5
kubectl rollout status deployment weather-api

# Оновлення і відкат
kubectl set image deployment/weather-api weather-api=nginx:1.27
kubectl rollout history deployment weather-api
kubectl rollout undo deployment weather-api
kubectl rollout undo deployment weather-api --to-revision=1

# ReplicaSet
kubectl get replicasets
kubectl describe rs weather-api-7d6b8f9c4
```

### Вправи

**Вправа 1 — Легка:**
Масштабуй Deployment до 6 реплік через файл (відредагуй `deployment.yaml` і застосуй). Переконайся що Pod'и розподілились між обома worker nodes.

**Вправа 2 — Середня:**
Зміни образ на `nginx:1.26` і поспостерігай за rolling update через `kubectl get pods -w` у другому терміналі. Подивись скільки Pod'ів існувало одночасно в пік оновлення. Потім зроби rollback.

**Вправа 3 — Складна:**
Спробуй створити `nginx:nonexistent` (неіснуючий тег). Подивись що відбувається: частина Pod'ів залишиться старою версією, нові матимуть `ImagePullBackOff`. Зроби rollback. Поясни чому сервіс залишався доступним під час цього "зламаного" оновлення.

### Питання для роздумів

- Що станеться якщо вручну видалити ReplicaSet що належить Deployment'у?
- Чому кількість записів у `rollout history` обмежена (за замовчуванням 10)?
- Як Deployment знає що Pod'и з новим образом "готові" приймати трафік, перш ніж видалити старі? (підказка: readinessProbe — Урок 5)

---

## Наступний урок

**Урок 3: Service — Стабільна адреса для мінливих Pod'ів**

Pod'и мають IP-адреси, але вони змінюються при кожному перестворенні. Як знайти Pod якщо його IP постійно змінюється? Як розподілити трафік між трьома репліками? Відповідь — Service. У наступному уроці:
- ClusterIP: доступ всередині кластеру
- NodePort: доступ ззовні для тестування
- Як Service знаходить Pod'и через labels
- DNS всередині кластеру: як Pod'и знаходять один одного по імені

---

*Урок підготовлено для Kubernetes Workshop. Версія K8s: 1.29+*
