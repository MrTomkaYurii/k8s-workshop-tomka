# Kubernetes Workshop — WeatherApi на Kubernetes

Практичний воркшоп з Kubernetes для .NET розробників.  
Мова: Ukrainian. Рівень: від нуля до production-ready.

---

## Про воркшоп

Ми будуємо один реальний додаток — **WeatherApi** — і поступово переносимо його на Kubernetes, вивчаючи кожну концепцію на практиці. Кожен урок вирішує конкретну проблему і будує на попередньому.

**Стек:** .NET 9, ASP.NET Core, PostgreSQL, Redis  
**Кластер:** kind (Kubernetes IN Docker) — локально, без хмари  
**Підхід:** спочатку пояснюємо ПРОБЛЕМУ, потім показуємо рішення

---

## Структура воркшопу

| Урок | Тема | Що вивчаємо |
|------|------|-------------|
| [01](lessons/lesson-01-cluster-and-pods.md) | Кластер і Pod'и | kind, kubectl, перший Pod |
| 02 | Deployment | ReplicaSet, самовідновлення, rolling update |
| 03 | Services | ClusterIP, NodePort, DNS всередині кластеру |
| 04 | Config і Secrets | ConfigMap, Secret, env vars з K8s |
| 05 | Health Checks | liveness, readiness, CrashLoopBackOff демо |
| 06 | Resources | requests/limits, OOMKilled демо |
| 07 | StatefulSet | PostgreSQL, PVC, дані переживають смерть Pod'у |
| 08 | RBAC | Namespace, ServiceAccount, Role |
| 09 | Ingress | nginx ingress, routing, TLS |
| 10 | HPA | Автомасштабування, метрики, load generator |
| 11 | Jobs | db-migration Job, CronJob |
| 12 | Rolling Update | blue/green, rollback в одну команду |
| 13 | Observability | Prometheus, Grafana, structured logging |
| 14 | Helm | Chart нашого додатку, values, templates |

---

## Швидкий старт

### 1. Перевір середовище

```bash
chmod +x scripts/00-setup.sh
./scripts/00-setup.sh
```

### 2. Створи кластер

```bash
kind create cluster \
  --name workshop \
  --config k8s/00-cluster/kind-config.yaml
```

### 3. Перевір що все працює

```bash
kubectl get nodes
# Очікувано: 3 вузли зі статусом Ready
```

### 4. Відкрий урок 1

Читай [lessons/lesson-01-cluster-and-pods.md](lessons/lesson-01-cluster-and-pods.md) і виконуй команди по черзі.

---

## Структура директорій

```
k8s-workshop/
├── README.md                  ← ти тут
├── lessons/                   ← покрокові уроки для початківців
│   ├── lesson-01-cluster-and-pods.md
│   └── ...
├── k8s/                       ← Kubernetes YAML маніфести
│   ├── 00-cluster/            ← конфігурація kind кластеру
│   ├── 01-pod/                ← урок 1: голий Pod
│   └── ...
├── src/                       ← вихідний код додатку
│   ├── WeatherApi/
│   └── WeatherWorker/
└── scripts/                   ← допоміжні shell скрипти
    ├── 00-setup.sh            ← перевірка середовища
    └── ...
```

---

## Вимоги

- Docker Desktop (4GB+ RAM для Docker)
- kind v0.23+
- kubectl v1.29+
- helm v3.14+

Скрипт `scripts/00-setup.sh` перевірить і встановить все необхідне.

---

## Видалення кластеру

```bash
kind delete cluster --name workshop
```
