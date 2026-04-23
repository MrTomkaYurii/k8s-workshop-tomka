# Урок 3: Service — Стабільна адреса для мінливих Pod'ів

> **Рівень:** Початківець (потрібні Уроки 1-2)
> **Тривалість:** ~75 хвилин
> **Що потрібно:** Deployment з Уроку 2 запущений
> **Що отримаєш:** ClusterIP і NodePort Services, розуміння DNS всередині кластеру

---

## Зміст

1. [Проблема: чому IP Pod'у марний](#1-проблема)
2. [Що таке Service і як він влаштований](#2-що-таке-service)
3. [Як Service знаходить Pod'и: Endpoints](#3-endpoints)
4. [Як трафік потрапляє до Pod'у: kube-proxy і iptables](#4-kube-proxy-і-iptables)
5. [DNS всередині кластеру: CoreDNS](#5-coreDNS)
6. [Типи Services](#6-типи-services)
7. [ClusterIP: внутрішня комунікація](#7-clusterip)
8. [NodePort: доступ ззовні для тестування](#8-nodeport)
9. [Практика: створюємо обидва Services](#9-практика)
10. [ДЕМО: curl зсередини кластеру](#10-демо-curl)
11. [Headless Service і коли він потрібен](#11-headless-service)
12. [Типові помилки](#12-типові-помилки)
13. [Підсумок і вправи](#13-підсумок-і-вправи)

---

## 1. Проблема

В Уроці 2 ми переконались що Deployment відновлює Pod'и автоматично. Але є прихована проблема, яку ми ще не вирішили.

### IP-адреса Pod'у є ефемерною

Кожен Pod отримує IP-адресу при створенні. Ця адреса унікальна в межах кластеру і дозволяє Pod'ам спілкуватися між собою безпосередньо. Але є одна принципова особливість: коли Pod видаляється і створюється новий (через рестарт, оновлення або вихід з ладу вузла), новий Pod отримує **іншу** IP-адресу.

```
До:   weather-api-pod-1  IP: 10.244.1.5   <-- клієнт знає цю адресу
      weather-api-pod-2  IP: 10.244.2.3
      weather-api-pod-3  IP: 10.244.1.8

Pod-1 впав, ReplicaSet створив Pod-4:
Після: weather-api-pod-4  IP: 10.244.1.11  <-- нова IP, клієнт не знає
       weather-api-pod-2  IP: 10.244.2.3
       weather-api-pod-3  IP: 10.244.1.8
```

Якщо WeatherWorker зберіг IP-адресу Pod'у WeatherApi і звертається до неї — після перестворення Pod'у зв'язок розірветься. IP `10.244.1.5` більше нікому не належить.

### Проблема балансування навантаження

Навіть якби IP були стабільними, залишається питання: до якого з трьох Pod'ів надсилати запит? Клієнт повинен знати про всі три IP-адреси і сам вирішувати розподіл. Це складно підтримувати і легко зламати.

### Що потрібно

Потрібен проміжний об'єкт, який:
- Має **стабільну** IP-адресу, що не змінюється протягом усього свого існування
- Автоматично знаходить живі Pod'и і направляє до них трафік
- Рівномірно розподіляє запити між репліками
- Виключає з балансування Pod'и, які ще не готові

Цей об'єкт називається **Service**.

---

## 2. Що таке Service і як він влаштований

**Service** — абстракція над набором Pod'ів. Він надає стабільну мережеву точку входу (IP + порт) і розподіляє трафік між усіма Pod'ами, що відповідають його selector.

### ClusterIP — віртуальна IP-адреса

Важлива деталь, яку часто не розуміють: **ClusterIP — це не реальна IP-адреса**. Жоден мережевий інтерфейс у кластері не має цієї адреси. Вона існує лише як правило маршрутизації в ядрі Linux кожного вузла.

Коли Pod надсилає пакет на ClusterIP, ядро перехоплює його ще до того як він потрапляє на мережеву картку, і перенаправляє на реальну IP-адресу одного з Pod'ів. Цей механізм реалізує компонент **kube-proxy** через правила **iptables** або **IPVS**. Детально розберемо в секції 4.

```
WeatherWorker Pod                  WeatherApi Pods
  (10.244.2.7)                     (10.244.1.5)
       |                           (10.244.2.3)
       |  "хочу надіслати пакет    (10.244.1.8)
       |   на 10.96.45.123:80"          ^
       |                               |
       v                               |
   iptables на вузлі                   |
   "10.96.45.123 -- це ClusterIP"     |
   "перенаправляю на 10.244.1.5"  ----+
```

Ця архітектура дає дві переваги:
1. ClusterIP ніколи не змінюється поки існує Service
2. Перенаправлення відбувається в ядрі, без додаткового мережевого стрибка (hop)

### Стабільність Service vs нестабільність Pod

```
Service:  weather-api-svc   IP: 10.96.45.123   PORT: 80   [ЗАВЖДИ]
                 |
           (перенаправляє на)
                 |
Pod'и:   10.244.1.5:80    <-- може змінитись
         10.244.2.3:80    <-- може змінитись
         10.244.1.8:80    <-- може змінитись
```

Клієнт знає тільки про `10.96.45.123:80`. Pod'и можуть змінюватись скільки завгодно — клієнт цього не помітить.

---

## 3. Endpoints

### Як Service дізнається про Pod'и

Service не зберігає список Pod'ів у собі. Замість цього існує окремий об'єкт — **Endpoints** (або сучасніший **EndpointSlice**).

Endpoints — це просто список IP-адрес і портів Pod'ів що зараз живі і відповідають selector Service'у.

```bash
# Подивимось Endpoints нашого майбутнього Service'у
kubectl get endpoints weather-api-svc

# NAME              ENDPOINTS                                      AGE
# weather-api-svc   10.244.1.5:80,10.244.2.3:80,10.244.1.8:80   5m
```

### Хто оновлює Endpoints

**Endpoints Controller** (частина Controller Manager) постійно стежить за Pod'ами і оновлює Endpoints:

```
Щоразу як змінюється стан Pod'ів:
  Endpoints Controller запитує всі Pod'и що відповідають selector Service'у
  Відбирає тільки ті, що:
    1. Мають статус Running
    2. Пройшли readinessProbe (якщо є)
    3. Не в стані Terminating
  Записує їхні IP:порт у об'єкт Endpoints
```

Це критично важлива деталь: **Pod що не пройшов readinessProbe не потрапляє в Endpoints** і не отримує трафік. Саме так Kubernetes гарантує що трафік іде тільки на готові Pod'и. Якщо pod тільки стартує і ще не готовий — він просто відсутній в Endpoints.

### EndpointSlice: масштабована версія Endpoints

У великих кластерах (тисячі Pod'ів) оновлення одного великого Endpoints об'єкту стає вузьким місцем. Кожне оновлення передається на всі вузли кластеру через API Server.

**EndpointSlice** вирішує це: замість одного великого об'єкту — кілька менших (по 100 записів). При зміні одного Pod'у оновлюється тільки один Slice, а не весь список.

```bash
# Подивитись EndpointSlices
kubectl get endpointslices

# NAME                   ADDRESSTYPE   PORTS   ENDPOINTS   AGE
# weather-api-svc-abc12  IPv4          80      3           5m
```

З Kubernetes 1.21+ EndpointSlices є за замовчуванням. Endpoints існують для зворотної сумісності.

---

## 4. kube-proxy і iptables

Це найтехнічніша секція уроку, але вона пояснює чому Service взагалі працює.

### Роль kube-proxy

**kube-proxy** — компонент що запущений на кожному вузлі кластеру як DaemonSet. Він стежить за змінами в Endpoints і оновлює мережеві правила на вузлі.

Є три режими роботи kube-proxy:

| Режим | Опис | Коли використовується |
|-------|------|-----------------------|
| iptables | Правила в netfilter/iptables ядра Linux | За замовчуванням у більшості кластерів |
| IPVS | IP Virtual Server — оптимізований для великих кластерів | Потрібно явно увімкнути |
| userspace | Застарілий, трафік проходить через процес kube-proxy | Не використовується |

### Режим iptables: як це працює

iptables — фреймворк фільтрації пакетів у ядрі Linux. kube-proxy додає до нього ланцюжки правил (chains) для кожного Service.

Коли Pod надсилає пакет на ClusterIP, відбувається наступне:

```
Пакет від Pod'у
    |
    v
PREROUTING chain (iptables)
    |
    v
KUBE-SERVICES chain  <-- kube-proxy додав це правило
    |
    | "IP == 10.96.45.123 і PORT == 80?"
    v
KUBE-SVC-WEATHERAPI chain
    |
    | "Вибираємо один з Pod'ів випадково (round-robin через probability)"
    | 33% --> KUBE-SEP-POD1  -->  DNAT на 10.244.1.5:80
    | 33% --> KUBE-SEP-POD2  -->  DNAT на 10.244.2.3:80
    | 33% --> KUBE-SEP-POD3  -->  DNAT на 10.244.1.8:80
    v
Пакет пішов на реальну IP Pod'у
```

**DNAT** (Destination NAT) — заміна адреси призначення в заголовку пакету. Ядро запам'ятовує це перетворення і автоматично робить зворотне (SNAT) для відповіді.

Щоразу як Endpoints Controller оновлює Endpoints — kube-proxy перегенеровує ці iptables правила на всіх вузлах. Тому зміни в Pod'ах відображаються в трафіку з невеликою затримкою (зазвичай менше секунди).

### Режим IPVS: чому він кращий для великих кластерів

У кластері з 10,000 сервісів iptables буде мати десятки тисяч правил. Перевірка кожного правила при кожному пакеті лінійно масштабується — O(n). При 10,000 сервісах це помітна затримка.

IPVS використовує хеш-таблиці — перевірка O(1) незалежно від кількості сервісів. Також підтримує більше алгоритмів балансування: Round Robin, Least Connections, Source Hashing та інші.

```bash
# Перевірити режим kube-proxy (у kind за замовчуванням iptables)
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
```

### Що відбувається при додаванні нового Pod'у

```
1. ReplicaSet створює новий Pod
2. kubelet запускає контейнер на вузлі
3. Pod отримує IP від CNI plugin (Flannel, Calico, etc.)
4. readinessProbe починає перевірки
5. Pod проходить readinessProbe
6. Endpoints Controller помічає новий Ready Pod
7. Endpoints Controller додає IP Pod'у в Endpoints об'єкт
8. kube-proxy на всіх вузлах отримує оновлення
9. kube-proxy оновлює iptables правила
10. Новий Pod починає отримувати трафік
```

Між кроком 5 і кроком 10 є невелика затримка. Якщо Pod вбити відразу після того як він пройшов readiness — частина запитів може потрапити на вже мертвий Pod. Тут і допомагає `terminationGracePeriodSeconds`: Pod отримує SIGTERM, лише потім видаляється з Endpoints.

---

## 5. CoreDNS

Запам'ятовувати IP-адресу Service'у незручно. Kubernetes вирішує це через DNS.

### Що таке CoreDNS

**CoreDNS** — DNS-сервер що запущений всередині кластеру (як Deployment у namespace `kube-system`). Кожен Pod у кластері автоматично налаштований використовувати CoreDNS для розпізнавання імен.

```bash
# CoreDNS запущений як Deployment
kubectl get deployment coredns -n kube-system

# NAME      READY   UP-TO-DATE   AVAILABLE
# coredns   2/2     2            2
```

### DNS-імена Services

Кожен Service отримує DNS-ім'я за схемою:

```
<service-name>.<namespace>.svc.cluster.local
```

Для нашого сервісу `weather-api-svc` у namespace `default`:

```
weather-api-svc.default.svc.cluster.local
```

Це повне ім'я (FQDN). Але всередині кластеру можна використовувати скорочення:

```
# З того ж namespace (default):
weather-api-svc                          # скорочено
weather-api-svc.default                  # з namespace
weather-api-svc.default.svc             # з суфіксом svc
weather-api-svc.default.svc.cluster.local  # повне ім'я

# З іншого namespace (наприклад, з monitoring):
weather-api-svc.default                  # мінімум
weather-api-svc.default.svc.cluster.local  # повне
```

### Як Pod розпізнає ім'я

Кожен Pod має файл `/etc/resolv.conf` що налаштований кластером автоматично:

```bash
# Зайди в будь-який Pod і перевір:
kubectl exec -it <pod-name> -- cat /etc/resolv.conf

# Побачиш:
nameserver 10.96.0.10              # IP ClusterIP Service'у CoreDNS
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

`nameserver 10.96.0.10` — це IP самого CoreDNS (теж Service!). Коли Pod запитує `weather-api-svc`, DNS resolver додає суфікси зі списку `search` і запитує CoreDNS:

```
weather-api-svc  -->  weather-api-svc.default.svc.cluster.local  -->  10.96.45.123
```

CoreDNS отримує запит, знаходить Service з таким іменем і відповідає його ClusterIP.

### DNS для Pod'ів (не тільки Services)

CoreDNS також надає DNS-записи для Pod'ів, але за іншою схемою:

```
<pod-ip-з-дефісами>.<namespace>.pod.cluster.local
# Наприклад: 10-244-1-5.default.pod.cluster.local --> 10.244.1.5
```

Ця схема незручна для використання напряму. DNS-адреси Pod'ів корисні лише для Headless Services (секція 11).

### SRV записи

Окрім A-записів (IP-адреса), CoreDNS надає SRV-записи з інформацією про порти:

```
_http._tcp.weather-api-svc.default.svc.cluster.local
```

SRV-записи використовуються рідко, але деякі сервіс-меші (Istio, Linkerd) спираються на них.

---

## 6. Типи Services

Kubernetes має чотири типи Services, кожен для свого сценарію.

### ClusterIP (за замовчуванням)

Service доступний тільки всередині кластеру. Отримує внутрішню IP-адресу з діапазону `serviceSubnet`.

```
Ззовні кластеру:   недоступно
Всередині кластеру: доступно через ClusterIP або DNS-ім'я
```

Використовується для: внутрішньої комунікації між мікросервісами.

### NodePort

Розширює ClusterIP, додатково відкриваючи порт на кожному вузлі кластеру. Доступний ззовні через `<будь-який вузол IP>:<nodePort>`.

```
Ззовні кластеру:   <node-ip>:30080
Всередині кластеру: <cluster-ip>:80 або DNS
```

Діапазон NodePort: 30000-32767 (фіксований, змінюється в конфігурації kube-apiserver).

Використовується для: локального тестування, швидкого доступу ззовні у dev-середовищі. У production зазвичай використовують Ingress поверх ClusterIP.

### LoadBalancer

Розширює NodePort, додатково запитує у хмарного провайдера (AWS, GCP, Azure) створення зовнішнього балансувальника. Отримує зовнішню IP-адресу.

```
Ззовні кластеру:   <external-ip>:80  (хмарний Load Balancer)
Всередині:         ClusterIP або DNS
```

Використовується для: production розгортання у хмарі коли потрібен прямий L4 доступ ззовні без Ingress.

У kind LoadBalancer не працює з коробки (немає хмари). Потрібен MetalLB або cloud-provider-kind.

### ExternalName

Особливий тип: не створює ClusterIP, а замість цього повертає CNAME на зовнішнє ім'я. Корисний щоб посилатись на зовнішні сервіси через K8s DNS.

```yaml
kind: Service
spec:
  type: ExternalName
  externalName: my-database.us-east-1.rds.amazonaws.com
```

Тепер всередині кластеру можна звертатись до `my-database.default.svc.cluster.local` і отримати CNAME на RDS. Якщо БД переїде на інший хост — змінюєш тільки ExternalName у Service, не чіпаючи код.

### Порівняння типів

```
ExternalName:  CNAME --> зовнішній хост
ClusterIP:     внутрішня VIP --> Pod'и
NodePort:      <вузол>:<порт> --> ClusterIP --> Pod'и
LoadBalancer:  <external-ip> --> NodePort --> ClusterIP --> Pod'и
```

Кожен наступний тип розширює попередній, а не замінює.

---

## 7. ClusterIP

### Навіщо ClusterIP якщо Pod'и і так можуть спілкуватися напряму

Pod'и в Kubernetes можуть звертатися один до одного безпосередньо за IP. Тоді навіщо Service?

Відповідь: балансування і стабільність. Якщо WeatherWorker звертається напряму до IP Pod'у WeatherApi і цей Pod видалено — з'єднання рветься. Через Service — Worker зберігає стабільну адресу і ReplicaSet може вільно перестворювати Pod'и.

Але є ще одна причина: **health filtering**. Service через Endpoints автоматично виключає нездорові Pod'и. При прямому зверненні за IP — можна потрапити на Pod що ще завантажується або вже помирає.

### Структура ClusterIP Service

```yaml
apiVersion: v1
kind: Service
spec:
  type: ClusterIP     # за замовчуванням, можна не писати
  selector:
    app: weather-api  # знайти Pod'и з цією міткою
  ports:
    - port: 80        # порт на якому слухає Service (ClusterIP:80)
      targetPort: 80  # порт на який перенаправляти в Pod'і
      protocol: TCP
```

Різниця між `port` і `targetPort`:

```
Клієнт:              Service:          Pod:
:любий порт  -->  ClusterIP:port  -->  PodIP:targetPort

Наприклад:
:52341       -->  10.96.45.123:80  --> 10.244.1.5:8080
```

Клієнт підключається до `ClusterIP:80`, Service перенаправляє на `PodIP:8080`. Порти можуть не збігатись. Це корисно якщо Pod слухає на нестандартному порті, а Service надає стандартний.

### Посилання на порт за іменем

Якщо у Pod'і оголошені іменовані порти — Service може посилатись на ім'я замість числа:

```yaml
# У Pod:
ports:
  - name: http
    containerPort: 8080

# У Service:
ports:
  - port: 80
    targetPort: http   # посилання на ім'я, а не на число
```

Перевага: якщо Pod перейде на порт 9090, достатньо змінити `containerPort` у Pod'і. Service автоматично оновить targetPort через ім'я.

---

## 8. NodePort

### Як NodePort відкриває доступ ззовні

NodePort розширює ClusterIP тим, що відкриває порт на **кожному вузлі** кластеру. Коли запит приходить на цей порт — kube-proxy перенаправляє його в ClusterIP, а далі — на Pod.

```
Зовнішній клієнт
       |
       | HTTP 192.168.64.2:30080
       v
   Worker Node 2
   (IP: 192.168.64.2)
       |
   iptables: NodePort 30080 --> ClusterIP:80
       |
   kube-proxy --> один з Pod'ів
```

Запит може прийти на **будь-який** вузол кластеру — навіть якщо на ньому немає жодного Pod'у цього Service'у. kube-proxy все одно перенаправить його на правильний Pod.

### externalTrafficPolicy

За замовчуванням (`externalTrafficPolicy: Cluster`) трафік що прийшов на вузол може бути перенаправлений на Pod **на іншому вузлі**. Це додає мережевий стрибок і змінює вихідну IP-адресу клієнта (SNAT).

```yaml
externalTrafficPolicy: Local
```

З `Local` — трафік що прийшов на вузол направляється тільки на Pod'и **цього ж** вузла. Якщо на вузлі немає Pod'ів — запити відхиляються (не перенаправляються на інший вузол). Перевага: зберігається вихідна IP-адреса клієнта (корисно для логів і rate limiting). Недолік: нерівномірне балансування якщо Pod'и розподілені нерівно.

### Коли використовувати NodePort

NodePort зручний для:
- Локального тестування (kind, minikube)
- Швидкого доступу до сервісу під час розробки
- Середовищ де немає Ingress Controller

У production зазвичай:
- Ingress Controller (Nginx, Traefik) отримує трафік через NodePort або LoadBalancer
- Всі інші Services — ClusterIP
- NodePort напряму відкритий ззовні — рідкість

---

## 9. Практика

### Переконайся що Deployment запущений

```bash
kubectl get deployment weather-api
# READY повинно бути 3/3

kubectl get pods
# Три Pod'и зі статусом Running
```

Якщо немає — застосуй з Уроку 2:

```bash
kubectl apply -f k8s/02-deployment/deployment.yaml
```

### Крок 1: Застосовуємо ClusterIP Service

```bash
kubectl apply -f k8s/03-service/clusterip.yaml
# service/weather-api-svc created
```

### Крок 2: Перевіряємо Service

```bash
kubectl get services
# або скорочено:
kubectl get svc

# NAME              TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
# kubernetes        ClusterIP   10.96.0.1      <none>        443/TCP   2d
# weather-api-svc   ClusterIP   10.96.45.123   <none>        80/TCP    30s
```

Перший рядок — `kubernetes` — це Service для доступу до API Server зсередини Pod'ів. Він існує завжди.

### Крок 3: Перевіряємо Endpoints

```bash
kubectl get endpoints weather-api-svc

# NAME              ENDPOINTS                                      AGE
# weather-api-svc   10.244.1.5:80,10.244.2.3:80,10.244.1.8:80   1m
```

Якщо ENDPOINTS порожній або показує `<none>` — перевір чи збігаються мітки в selector Service'у і labels Pod'ів:

```bash
# Мітки Pod'ів:
kubectl get pods --show-labels

# Selector Service'у:
kubectl describe service weather-api-svc | grep Selector
```

### Крок 4: Детальна інформація про Service

```bash
kubectl describe service weather-api-svc
```

Виведе:

```
Name:              weather-api-svc
Namespace:         default
Labels:            app=weather-api
Selector:          app=weather-api
Type:              ClusterIP
IP Family Policy:  SingleStack
IP Families:       IPv4
IP:                10.96.45.123
IPs:               10.96.45.123
Port:              http  80/TCP
TargetPort:        80/TCP
Endpoints:         10.244.1.5:80,10.244.2.3:80,10.244.1.8:80
Session Affinity:  None
Events:            <none>
```

### Крок 5: Застосовуємо NodePort Service

```bash
kubectl apply -f k8s/03-service/nodeport.yaml
# service/weather-api-nodeport created

kubectl get services
# NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
# weather-api-svc        ClusterIP   10.96.45.123    <none>        80/TCP         5m
# weather-api-nodeport   NodePort    10.96.88.201    <none>        80:30080/TCP   30s
```

У стовпці `PORT(S)` бачимо `80:30080/TCP` — це означає "порт Service'у 80, NodePort 30080".

### Крок 6: Перевірка NodePort у kind

У kind вузли — це Docker контейнери. Щоб дістатись до NodePort:

```bash
# Знаходимо IP будь-якого вузла
kubectl get nodes -o wide

# NAME                     STATUS   ROLES    INTERNAL-IP
# workshop-control-plane   Ready    control-plane   172.19.0.2
# workshop-worker          Ready    <none>          172.19.0.3
# workshop-worker2         Ready    <none>          172.19.0.4

# Звертаємось через NodePort (використай реальний IP з твого кластеру)
curl http://172.19.0.3:30080
```

Якщо в `kind-config.yaml` налаштований `extraPortMappings` з hostPort 30000 — можна через localhost:

```bash
curl http://localhost:30000
```

---

## 10. ДЕМО: curl зсередини кластеру

Цей ДЕМО-момент показує DNS і ClusterIP в дії.

### Крок 1: Запускаємо тимчасовий Pod для тестування

```bash
# Запускаємо busybox Pod, автоматично видаляється після виходу (--rm)
kubectl run curl-test \
  --image=curlimages/curl:latest \
  --restart=Never \
  --rm \
  -it \
  -- sh

# Опинились всередині контейнера
```

Прапорці:
- `--restart=Never` — не Deployment, а голий Pod (для тимчасових задач)
- `--rm` — видалити Pod після завершення сесії
- `-it` — інтерактивний термінал
- `-- sh` — команда що запуститься в контейнері

### Крок 2: Перевіряємо DNS (всередині Pod'у)

```sh
# Перевіряємо /etc/resolv.conf
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search default.svc.cluster.local svc.cluster.local cluster.local

# Розпізнаємо ім'я Service'у через DNS
nslookup weather-api-svc
# Server:    10.96.0.10
# Address:   10.96.0.10:53
# Name:      weather-api-svc.default.svc.cluster.local
# Address:   10.96.45.123
```

CoreDNS розпізнав скорочене ім'я `weather-api-svc` до повного FQDN і повернув ClusterIP.

### Крок 3: Робимо HTTP запит до Service'у

```sh
# Через DNS-ім'я (рекомендований спосіб)
curl -s http://weather-api-svc/
# Отримаємо відповідь від nginx (або нашого API пізніше)

# Через повне DNS-ім'я
curl -s http://weather-api-svc.default.svc.cluster.local/

# Через ClusterIP (не рекомендується -- IP може відрізнятись)
curl -s http://10.96.45.123/
```

### Крок 4: Перевіряємо балансування

```sh
# Зробимо кілька запитів і подивимось на заголовки
for i in 1 2 3 4 5 6; do
  curl -s -I http://weather-api-svc/ | grep Server
done
```

З nginx відповіді однакові — щоб побачити балансування, потрібно щоб кожен Pod повертав свій hostname. Це буде видно краще коли запустимо наш WeatherApi.

### Крок 5: Перевіряємо що Service знаходить правильні Pod'и

```sh
# Можна перевірити endpoints зсередини через API (якщо є curl)
# Але простіше подивитись зовні:
exit
```

Після `exit` Pod автоматично видалиться (через `--rm`).

```bash
# Зовні: стежимо за запитами до Service
kubectl get endpoints weather-api-svc -w
```

Видалимо один Pod і спостерігатимемо:

```bash
# В окремому терміналі:
kubectl delete pod weather-api-7d6b8f9c4-xk2pt

# У терміналі з watch побачимо:
# weather-api-svc   10.244.2.3:80,10.244.1.8:80        <-- Pod виключений з Endpoints
# weather-api-svc   10.244.2.3:80,10.244.1.8:80,10.244.1.11:80  <-- новий Pod доданий
```

---

## 11. Headless Service

### Що таке Headless Service

Headless Service — це Service з `clusterIP: None`. Він не отримує ClusterIP і не виконує балансування. Замість цього DNS-запит повертає список IP-адрес всіх Pod'ів напряму.

```yaml
spec:
  clusterIP: None   # headless
  selector:
    app: my-app
```

### DNS поведінка headless vs звичайного Service

```
Звичайний ClusterIP:
  nslookup weather-api-svc  -->  10.96.45.123  (один IP, ClusterIP)

Headless:
  nslookup weather-api-headless  -->  10.244.1.5
                                      10.244.2.3
                                      10.244.1.8
                                      (всі IP Pod'ів напряму)
```

### Коли потрібен Headless Service

Для **stateful** додатків де кожна репліка унікальна і клієнт повинен підключатись до конкретного Pod'у, а не до довільного.

Приклад: PostgreSQL кластер з replication. Є master і дві репліки. Записи — тільки на master, читання — на репліки. Клієнт повинен знати хто є master.

**StatefulSet + Headless Service** вирішує це: кожен Pod отримує стабільне DNS-ім'я:

```
postgres-0.postgres-headless.default.svc.cluster.local  --> Pod 0 (master)
postgres-1.postgres-headless.default.svc.cluster.local  --> Pod 1 (replica)
postgres-2.postgres-headless.default.svc.cluster.local  --> Pod 2 (replica)
```

Клієнт може підключатись до конкретного Pod'у за стабільним DNS-іменем. Детально розберемо в Уроці 7 (StatefulSet).

### Headless без selector

Headless Service без `selector` взагалі не знаходить Pod'ів автоматично. Endpoints треба створювати вручну. Це корисно для посилання на зовнішні сервіси (поза кластером):

```yaml
# Service без selector:
kind: Service
spec:
  clusterIP: None

---
# Ручні Endpoints:
kind: Endpoints
metadata:
  name: external-db        # ім'я повинно збігатись з Service
subsets:
  - addresses:
      - ip: 192.168.1.100  # IP зовнішньої бази даних
    ports:
      - port: 5432
```

Тепер `external-db.default.svc.cluster.local` буде DNS-іменем для зовнішньої БД.

---

## 12. Типові помилки

### Помилка 1: Selector не збігається — Endpoints порожній

```bash
kubectl get endpoints my-service
# NAME         ENDPOINTS   AGE
# my-service   <none>      5m
```

Причина: мітки в Service.spec.selector не відповідають жодному Pod'у.

Діагностика:

```bash
# Які мітки у Pod'ів?
kubectl get pods --show-labels

# Який selector у Service?
kubectl get service my-service -o yaml | grep -A5 selector

# Знайти Pod'и що відповідають selector вручну:
kubectl get pods -l app=weather-api
```

### Помилка 2: Port vs TargetPort переплутані

```yaml
# НЕПРАВИЛЬНО -- Pod слухає на 8080, але Service очікує з'єднання на 80
ports:
  - port: 80
    targetPort: 80    # помилка: Pod слухає на 8080, не 80
```

```yaml
# ПРАВИЛЬНО:
ports:
  - port: 80
    targetPort: 8080  # Pod слухає на 8080, Service перенаправляє
```

### Помилка 3: Звернення до NodePort через ClusterIP ззовні

ClusterIP доступний тільки всередині кластеру. Спроба звернутись ззовні просто зависне:

```bash
# Це не спрацює (ClusterIP недоступний ззовні):
curl http://10.96.45.123:80   # з машини поза кластером

# Правильно:
curl http://<node-ip>:30080   # NodePort
# або:
curl http://localhost:80       # якщо kind налаштований з extraPortMappings
```

### Помилка 4: Pod не потрапляє в Endpoints через readinessProbe

```bash
kubectl get endpoints my-service
# ENDPOINTS: <none>

# Але Pod'и є:
kubectl get pods
# STATUS: Running

# Причина: readinessProbe провалюється
kubectl describe pod <pod-name>
# Events: Readiness probe failed: ...
```

Pod запущений (`Running`), але не "готовий" (`READY: 0/1`) — тому не потрапляє в Endpoints. Вирішення: виправити readinessProbe або перевірити чому додаток не відповідає на health endpoint.

### Помилка 5: SessionAffinity і балансування

За замовчуванням Service балансує запити без прив'язки до клієнта. Якщо додаток зберігає стан в пам'яті — різні запити від того самого клієнта можуть потрапляти на різні Pod'и і "не бачити" один одного.

```yaml
spec:
  sessionAffinity: ClientIP    # прив'язати клієнта до одного Pod'у
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600     # зберігати прив'язку 1 годину
```

Але правильне рішення: робити Pod'и **stateless**, а стан зберігати в Redis або БД. Не покладайся на sessionAffinity.

---

## 13. Підсумок і вправи

### Ключові ідеї

**IP Pod'у ефемерний** — Pod створився знову і отримав нову IP. Service — це стабільна точка доступу з незмінним ClusterIP і DNS-іменем.

**Service — це не процес** — це набір iptables правил в ядрі кожного вузла. kube-proxy слідкує за Endpoints і оновлює ці правила. Ніякий додатковий мережевий стрибок через "проксі-процес" не відбувається.

**Endpoints — зв'язок між Service і Pod'ами** — Endpoints Controller стежить за Pod'ами і оновлює список IP:порт. Service направляє трафік тільки на Pod'и в Endpoints (тобто тільки на Ready Pod'и).

**DNS всередині кластеру** — CoreDNS дозволяє звертатись до Service'ів за іменем, а не за IP. Скорочені імена (`my-svc`) автоматично розгортаються до FQDN (`my-svc.default.svc.cluster.local`).

### Команди уроку — шпаргалка

```bash
# Service
kubectl apply -f service.yaml
kubectl get services                  # список
kubectl get svc                       # скорочено
kubectl describe service weather-api-svc
kubectl delete service weather-api-svc

# Endpoints
kubectl get endpoints
kubectl get ep                        # скорочено
kubectl get endpoints weather-api-svc -w   # стежити

# Діагностика зсередини кластеру
kubectl run curl-test --image=curlimages/curl:latest \
  --restart=Never --rm -it -- sh
# всередині: curl http://weather-api-svc/
# всередині: nslookup weather-api-svc

# DNS перевірка
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl exec -it <pod> -- nslookup weather-api-svc
```

### Вправи

**Вправа 1 — Легка:**
Переконайся що видалення Pod'у відображається в Endpoints. Запусти `kubectl get endpoints weather-api-svc -w` в одному терміналі. В іншому видали один Pod. Подивись як Endpoints змінюються і відновлюються.

**Вправа 2 — Середня:**
Зміни `replicas: 3` на `replicas: 1` в Deployment і застосуй. Перевір як змінились Endpoints. Поверни до 3 реплік.

**Вправа 3 — Складна:**
Створи другий Deployment з образом `nginx:1.26` і мітками `app: weather-api-v2`. Спробуй направити Service до цього Deployment'у, змінивши selector. Що станеться з Endpoints? Потім поверни оригінальний selector.

**Питання для роздумів:**
- Що відбудеться якщо видалити Service? Pod'и залишаться запущеними?
- Чому ClusterIP не є реальним мережевим інтерфейсом і чому це добре?
- Якщо Pod проходить livenessProbe але провалює readinessProbe — що відбудеться? Чи отримуватиме він трафік? Чи буде він перезапущений?

---

## Наступний урок

**Урок 4: ConfigMap і Secret — Конфігурація без перебудови образу**

Зараз конфігурація нашого додатку "зашита" прямо в YAML-файл Deployment'у — рядки env з `value: "Development"`. Якщо потрібно змінити URL бази даних або пароль — треба редагувати Deployment і перезапускати Pod'и.

У наступному уроці:
- Що таке ConfigMap і навіщо відокремлювати конфігурацію від образу
- Що таке Secret, як K8s зберігає чутливі дані і де межа безпеки (спойлер: base64 — не шифрування)
- Три способи передати конфігурацію в Pod: env, envFrom, Volume
- Як оновлення ConfigMap автоматично оновлює файли в Pod'і (але не env vars)

---

*Урок підготовлено для Kubernetes Workshop. Версія K8s: 1.29+*
