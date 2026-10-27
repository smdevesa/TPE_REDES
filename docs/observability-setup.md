# How-to: Observabilidad de The Store (Grafana · Prometheus · Loki · Tempo)

Stack de observabilidad unificada para The Store, sin modificar el código de los
microservicios: **métricas** (Prometheus), **logs** (Promtail + Loki), **trazas**
(OpenTelemetry + Tempo), y **visualización y alertas** (Grafana + Discord).

Todo se instala con Helm en el namespace `observability` y queda definido en el repo:
nada se configura a mano en la interfaz de Grafana.

## Estructura

```
observability.sh                 # instala, prende/apaga y ejecuta la demo
.env.example                     # copiar a .env con el webhook de Discord
dist/kubernetes.yaml             # manifiestos de The Store (+ variables OTEL y probes)
observability/
├── values/                      # values de Helm de cada componente
│   ├── prometheus.yaml          #   scraping de los 5 servicios + kube-state-metrics + node-exporter
│   ├── loki.yaml                #   single binary, filesystem
│   ├── promtail.yaml            #   DaemonSet que envía stdout de los pods a Loki
│   ├── tempo.yaml               #   receptor OTLP HTTP :4318 / gRPC :4317
│   └── grafana.yaml             #   datasources, tracesToLogsV2, tableros y alertas por provisioning
└── grafana/
    ├── dashboards/              # tableros (JSON)
    │   ├── the-store-plataforma.json        # 3.3.4
    │   └── the-store-infraestructura.json   # 3.3.5
    └── alerting/                # Grafana Alerting (provisioning)
        ├── rules.yaml           #   reglas de alerta
        ├── contactpoints.yaml   #   contact point Discord
        ├── policies.yaml        #   política de notificación
        └── templates.yaml       #   formato del mensaje de Discord
```

## Prerrequisitos

- Docker, [Kind](https://kind.sigs.k8s.io/), `kubectl`, [Helm 3](https://helm.sh/docs/intro/install/) y `curl`
- El clúster de The Store creado: `./local.sh create-cluster` (ver README)

## 1. Webhook de Discord

1. En Discord: *Editar canal → Integraciones → Webhooks → Nuevo webhook → Copiar URL*.
2. `cp .env.example .env` y completar `DISCORD_WEBHOOK_URL=...`.

`.env` no se versiona. `observability.sh` lo carga en el Secret `grafana-discord`, y Grafana
lo lee como variable de entorno (`${DISCORD_WEBHOOK_URL}` en `contactpoints.yaml`).
Sin webhook, el stack se instala igual pero las alertas no llegan a Discord.

## 2. Instalar (una sola vez)

```bash
./observability.sh install
```

Lo que hace por dentro está detallado, comando por comando, en la sección
[Paso a paso manual](#paso-a-paso-manual-lo-que-hace-install-por-dentro).

**¿Cuándo hay que volver a correrlo?** Solo si:
- se creó un clúster nuevo (`./local.sh create-cluster` o `rebuild-cluster`);
- cambió el `.env` (webhook de Discord);
- cambió algún archivo de `observability/values/` o `dist/kubernetes.yaml`.

Si solo cambiaron tableros o alertas, alcanza con `./observability.sh reload-grafana`.

Correrlo de nuevo **no duplica nada**: `helm upgrade --install` y `kubectl apply` actualizan
lo existente, y tableros y alertas tienen un `uid` fijo. Grafana se reinicia y vuelve a cargar
todo desde el repo, así que se pierde lo que se haya creado a mano en su interfaz.

## 3. Uso diario

Una vez instalado, no hace falta reinstalar. Todo queda guardado en el clúster.

```bash
./observability.sh start    # prende el clúster (ya no arranca solo al prender la compu)
./observability.sh ui       # Grafana http://localhost:3000 (admin/admin) y Prometheus http://localhost:9090
./observability.sh stop     # lo apaga sin perder nada
```

| Comando | Qué hace |
|---|---|
| `start` / `stop` | `docker start/stop the-store-control-plane`: prende o apaga el nodo de Kind. |
| `status` | Pods, releases de Helm, targets de Prometheus y caos activo. |
| `ui` | `kubectl port-forward` a Grafana y Prometheus. Ctrl+C para cerrar. |
| `reset-data` | Borra métricas, logs, trazas, historial de alertas y datos en memoria de The Store (recrea esos pods). La configuración queda igual. |
| `traffic` / `chaos …` | Demo de los casos de uso, ver [demo.md](demo.md). |

The Store queda en http://localhost (ingress de Kind).

**Datos:** no hay volúmenes persistentes, que es lo que deja fuera de alcance la reentrega.
Métricas, logs y trazas sobreviven a `stop`/`start`. Se pierden si se recrea el clúster o el
pod del componente. Además, Prometheus guarda 2 días y Tempo alrededor de 24 h.

## 4. Cómo funciona cada pieza

### Trazas: OpenTelemetry → Tempo
Los microservicios ya traen OpenTelemetry. Se activa solo con variables de entorno en
`dist/kubernetes.yaml`, y cada servicio exporta sus spans por **OTLP/HTTP** a
`http://tempo.observability.svc:4318`.

| Variable | Para qué |
|---|---|
| `OTEL_SDK_DISABLED=false` | Solo Java (carts, orders, ui): el SDK viene apagado en `application.yml`. |
| `OTEL_SERVICE_NAME=<svc>` | Nombre del servicio en Tempo. En catalog (Go), su presencia es la que inicializa el tracer. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Receptor OTLP de Tempo. |
| `OTEL_METRICS_EXPORTER=none`, `OTEL_LOGS_EXPORTER=none` | Por OTLP solo viajan trazas: las métricas las scrapea Prometheus y los logs los recolecta Promtail. Sin esto, los servicios Java loguean un error 404 por minuto. |

Además, en el ConfigMap de checkout se agregó `RETAIL_CHECKOUT_ENDPOINTS_ORDERS=http://orders`.
Sin esa variable, checkout usa un servicio de órdenes simulado en memoria y el servicio
orders no recibe tráfico.

### Métricas: Prometheus (modelo pull)
| Job | Endpoint | Servicios |
|---|---|---|
| `the-store-spring` | `/actuator/prometheus` (Micrometer) | carts, orders, ui |
| `the-store-native` | `/metrics` | catalog (gin), checkout (NestJS) |
| `kubernetes-*` | kubelet/cAdvisor, kube-state-metrics, node-exporter | infraestructura |

Cada target recibe la etiqueta `service` (por ejemplo `carts.the-store.svc:80` → `service="carts"`).
Checkout solo expone métricas del runtime de Node, no de requests HTTP; su actividad se ve en trazas y logs.

### Logs: Promtail → Loki
Promtail corre como DaemonSet, lee `/var/log/pods` del nodo y envía a Loki con las etiquetas
`namespace`, `app`, `pod` y `container`.

### Correlación traza → logs (`tracesToLogsV2`)
En el datasource Tempo (`observability/values/grafana.yaml`), el atributo `service.name` del
span se mapea a la etiqueta `app` de Loki, con un margen de ±10 s. En la vista de un span,
el botón **Logs for this span** abre los logs de ese servicio en esa ventana de tiempo.

### Liveness probes
Se agregó una `livenessProbe` a cada deployment: `/actuator/health/liveness` en Java y
`/health` en Go y Node. Si un contenedor deja de responder (por ejemplo, por CPU saturada),
Kubernetes lo reinicia. Esto es lo que se observa en el caso 3.3.5.

## 5. Tableros

Carpeta **The Store** en Grafana:

- **The Store - Plataforma** (3.3.4): estado de los 5 servicios, alertas activas, RED
  (requests/s, % 5xx, latencia promedio), llamadas entre servicios (spans *client* de Tempo),
  trazas con error o de más de 1 s, y logs con error de Loki.
- **The Store - Infraestructura** (3.3.5): réplicas disponibles, reinicios, readiness de pods,
  CPU contra límite, % de *throttling*, memoria contra límite y métricas del nodo.

## 6. Alertas (Grafana Alerting → Discord)

| Regla | Condición (1 min) | Severidad |
|---|---|---|
| Servicio caído | `up == 0` | critical |
| Tasa de errores 5xx elevada | > 5 % de respuestas 5xx | critical |
| Latencia elevada | latencia promedio > 1 s | warning |
| CPU saturada (throttling) | > 50 % de períodos limitados | warning |
| Contenedor reiniciándose | algún reinicio en 5 min | critical |

La política envía todas las alertas al contact point `discord-equipo`, agrupadas por alerta y
servicio. El mensaje, definido en `templates.yaml`, incluye el servicio, la severidad, el
valor, la descripción, la hora y un link al panel del tablero. Cuando la alerta se resuelve,
llega un aviso de resolución.

## 7. Desinstalar

```bash
./observability.sh uninstall   # borra el namespace observability
```

## Paso a paso manual (lo que hace `install` por dentro)

`observability.sh` no tiene nada mágico: ejecuta estos comandos en este orden. Se pueden
correr a mano desde la raíz del repo para entender o depurar cada paso.

### 1. Repos de Helm y namespace
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
kubectl create namespace observability
```

### 2. Prometheus (métricas)
```bash
helm upgrade --install prometheus prometheus-community/prometheus --version 29.31.1 \
  -n observability -f observability/values/prometheus.yaml
```
Sin Alertmanager ni Pushgateway. Agrega los jobs `the-store-spring` y `the-store-native`, y
mantiene kube-state-metrics y node-exporter para el tablero de infraestructura.

### 3. Loki + Promtail (logs)
```bash
helm upgrade --install loki grafana/loki --version 7.3.0 \
  -n observability -f observability/values/loki.yaml
helm upgrade --install promtail grafana/promtail --version 6.17.1 \
  -n observability -f observability/values/promtail.yaml
```

### 4. Tempo (trazas)
```bash
helm upgrade --install tempo grafana/tempo --version 1.24.4 \
  -n observability -f observability/values/tempo.yaml
```

### 5. Configuración de Grafana: Secret y ConfigMaps
Grafana lee tableros y alertas de ConfigMaps, y el webhook de Discord de un Secret:
```bash
source .env
kubectl create secret generic grafana-discord -n observability \
  --from-literal=DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap grafana-dashboards -n observability \
  --from-file=observability/grafana/dashboards --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap grafana-alerting -n observability \
  --from-file=observability/grafana/alerting --dry-run=client -o yaml | kubectl apply -f -
```
`--dry-run=client -o yaml | kubectl apply -f -` permite crear el recurso o actualizarlo si ya existe.

### 6. Grafana
```bash
helm upgrade --install grafana grafana/grafana --version 10.5.15 \
  -n observability -f observability/values/grafana.yaml
kubectl rollout restart deploy/grafana -n observability   # para que relea los ConfigMaps
```
`grafana.yaml` define los 3 datasources, con `tracesToLogsV2` en Tempo. También monta
`grafana-dashboards` como proveedor de tableros y `grafana-alerting` en
`/etc/grafana/provisioning/alerting`, e inyecta el Secret como variable de entorno.

### 7. OpenTelemetry en The Store
```bash
kubectl apply -f dist/kubernetes.yaml -n the-store
```
Antes esto se hacía con `kubectl set env deployment/<svc> ...`, pero esos cambios se perdían
al recrear el clúster. Ahora las variables están en el manifiesto.

### 8. Verificar
```bash
kubectl get pods -n observability
kubectl port-forward -n observability svc/prometheus-server 9090:80   # http://localhost:9090/targets
kubectl port-forward -n observability svc/grafana 3000:80             # http://localhost:3000
```

## Cambios respecto de la versión anterior de esta guía

La base es la misma: mismos charts, datasources, `tracesToLogsV2` y variables OTEL. Lo que cambió:

| Cambio | Por qué |
|---|---|
| Los values pasaron de la raíz a `observability/values/`. Promtail tiene su archivo en vez de `--set`. | Orden: todo en un lugar. |
| Versiones de los charts fijadas (`--version`). | Que una reinstalación dé siempre lo mismo. |
| `helm upgrade --install --history-max 3` en vez de `helm install`. | Se puede repetir sin errores ni duplicados, y Helm guarda solo las últimas 3 revisiones. |
| Variables OTEL en `dist/kubernetes.yaml` en vez de `kubectl set env`. | Antes se perdían al recrear el clúster. |
| Nuevas `OTEL_METRICS_EXPORTER=none` y `OTEL_LOGS_EXPORTER=none`. | Los servicios Java intentaban mandar métricas a Tempo y logueaban un 404 por minuto. |
| `RETAIL_CHECKOUT_ENDPOINTS_ORDERS=http://orders` en el ConfigMap de checkout. | Sin esto checkout usaba un orders simulado y orders no recibía tráfico. |
| `livenessProbe` en los 5 deployments. | Para que la CPU saturada provoque reinicios, como pide el caso 3.3.5. |
| Prometheus: `prometheus-pushgateway.enabled: false`. | La clave anterior (`pushgateway`) estaba mal escrita y Pushgateway seguía corriendo. |
| Prometheus: etiqueta `service` por target, `scrape_interval` de 15 s y retención de 2 días. | Consultas y alertas por nombre de servicio. |
| Grafana: tableros y alertas por provisioning desde el repo; datasources no editables. | Antes el tablero estaba hecho a mano y se perdía al reiniciar Grafana. |
| Nuevo: reglas de alerta, contact point de Discord, política y plantilla del mensaje. | Casos 3.3.1 y 3.3.5, y el extra mile de Discord. |
| El nodo de Kind ya no se reinicia solo (`docker update --restart=no`). | Que el clúster se prenda solo cuando hace falta (`start`). |

## Problemas comunes

- **Un target figura DOWN en Prometheus:** revisar `kubectl get deploy -n the-store`.
  Un deployment escalado a 0 aparece como caído.
- **No llegan mensajes a Discord:** revisar `.env` y volver a correr `install`. Los errores
  aparecen en `kubectl logs -n observability deploy/grafana | grep discord`.
- **Quedó caos aplicado:** `./observability.sh chaos reset`.
