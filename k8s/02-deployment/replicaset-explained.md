# ReplicaSet: внутрішня механіка

Цей файл — довідник по ReplicaSet. Урок 2 використовує його як додатковий матеріал.

---

## Що таке ReplicaSet

ReplicaSet — контролер Kubernetes, що гарантує задану кількість ідентичних Pod'ів у кластері. Він постійно порівнює бажаний стан (`spec.replicas`) з реальним (кількість Pod'ів що відповідають `selector`) і виправляє різницю.

ReplicaSet створюється автоматично коли ти застосовуєш Deployment. Напряму ReplicaSet пишуть рідко.

---

## Selector і ownership

ReplicaSet не зберігає в собі список Pod'ів. Він знаходить їх через мітки.

Кожен Pod що ReplicaSet створив має анотацію `ownerReferences`:

```yaml
# kubectl get pod weather-api-7d6b8f9c4-xk2pt -o yaml
metadata:
  ownerReferences:
    - apiVersion: apps/v1
      kind: ReplicaSet
      name: weather-api-7d6b8f9c4
      uid: abc-123-...
      controller: true
      blockOwnerDeletion: true
```

Це двосторонній зв'язок:
- ReplicaSet знаходить Pod'и через selector (labels)
- Pod знає хто його власник через ownerReferences

Якщо вручну видалити `ownerReferences` у Pod'у — ReplicaSet "загубить" його і створить новий (бо побачить що реальних Pod'ів менше ніж потрібно).

---

## Adoption і orphaning

ReplicaSet може "усиновити" чужі Pod'и якщо їх мітки відповідають його selector.

Сценарій:

```bash
# Створюємо Pod вручну з міткою що збігається з ReplicaSet
kubectl run orphan --image=nginx:alpine --labels="app=weather-api"

# ReplicaSet бачить: є Pod з потрібною міткою, але replicas=3 вже виконано
# ReplicaSet видалить зайвий Pod (буде 4, а потрібно 3)
```

Це і є "усиновлення навпаки" -- ReplicaSet забирає контроль і відразу видаляє зайвий.

Якщо навпаки -- реплік менше ніж потрібно, а є безгоспні Pod'и з відповідними мітками -- ReplicaSet усиновить їх і рахуватиме своїми.

Практичний висновок: стежи щоб у різних Deployment'ів не перетинались мітки в selector.

---

## Як ReplicaSet реагує на зміни

### Зміна replicas

```bash
kubectl scale deployment weather-api --replicas=5
```

1. Deployment оновлює своє поле `spec.replicas`
2. Deployment Controller оновлює `spec.replicas` в ReplicaSet
3. ReplicaSet Controller бачить: actual=3, desired=5
4. Створює 2 нових Pod'и

### Зміна image в template

Зміна `image` в Deployment:

1. Deployment Controller створює **новий** ReplicaSet з новим шаблоном
2. Поступово збільшує `replicas` у новому ReplicaSet
3. Поступово зменшує `replicas` у старому ReplicaSet
4. Старий ReplicaSet залишається з `replicas=0` (для rollback)

ReplicaSet сам по собі **не** реагує на зміну `template.spec.containers.image`. Якщо змінити image напряму в ReplicaSet -- нові Pod'и будуть з новим образом, але існуючі не перезапустяться.

---

## ReplicaSet vs ReplicationController

`ReplicationController` -- застарілий попередник ReplicaSet. Відмінності:

| | ReplicationController | ReplicaSet |
|---|---|---|
| Selector | тільки рівність (`app: web`) | також set-based (`app in (web, api)`) |
| Статус | застарілий | актуальний |
| Deployment | не підтримує | основа для Deployment |

Не використовуй ReplicationController у нових проектах.

---

## Set-based selector

ReplicaSet підтримує складніші умови вибору:

```yaml
selector:
  matchLabels:
    app: weather-api        # рівність: app=weather-api

  matchExpressions:
    - key: environment
      operator: In
      values: ["dev", "staging"]   # environment IN (dev, staging)

    - key: tier
      operator: NotIn
      values: ["frontend"]         # tier NOT IN (frontend)

    - key: version
      operator: Exists             # мітка version існує (будь-яке значення)
```

Оператори: `In`, `NotIn`, `Exists`, `DoesNotExist`.

---

## Що відбувається при видаленні Deployment

```bash
kubectl delete deployment weather-api
```

За замовчуванням видаляється **каскадно**: Deployment → ReplicaSet → Pod.

Щоб видалити тільки Deployment, залишивши ReplicaSet і Pod'и:

```bash
kubectl delete deployment weather-api --cascade=orphan
```

Після цього Pod'и продовжать жити, але нікому не підзвітні. ReplicaSet залишиться, але без власника (Deployment видалено). Якщо вручну видалити Pod -- ReplicaSet ще існує і відновить його.

---

## Перегляд ReplicaSet

```bash
# Список ReplicaSet'ів (бачимо і старі з 0 реплік)
kubectl get replicasets
kubectl get rs

# NAME                       DESIRED   CURRENT   READY   AGE
# weather-api-7d6b8f9c4     3         3         3       10m
# weather-api-9f2a1b8c3     0         0         0       5m    <-- стара ревізія

# Детально
kubectl describe rs weather-api-7d6b8f9c4

# Pod'и конкретного ReplicaSet (через label selector)
kubectl get pods -l app=weather-api
```

---

## Чому ReplicaSet hash виглядає як "7d6b8f9c4"

Це hash від `template` -- Pod шаблону. Якщо змінити будь-що в шаблоні (образ, env, resources) -- hash зміниться і Deployment створить новий ReplicaSet.

Це дозволяє Deployment відрізняти Pod'и різних версій і керувати переходом між ними.
