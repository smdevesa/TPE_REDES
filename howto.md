# How-to: observabilidad para The Store

Cómo replicar, desde cero, el stack de observabilidad del Grupo 5 sobre The Store:

| Señal | Herramienta | Cómo llega |
|---|---|---|
| Métricas | Prometheus | Prometheus va a buscarlas (pull) a `/actuator/prometheus` o `/metrics` de cada servicio |
| Logs | Promtail → Loki | Promtail lee el stdout de los pods en el nodo y los envía a Loki |
| Trazas | OpenTelemetry → Tempo | Cada servicio envía sus spans por OTLP/HTTP a Tempo (`:4318`) |
| Visualización y alertas | Grafana → Discord | Grafana consulta las tres fuentes y avisa por webhook |

No se modifica el código de los microservicios: todo se activa con configuración
(variables de entorno, probes y values de Helm). La configuración vive en el repo y no se toca
nada a mano en Grafana.

---

## 1. Requisitos

- Docker en ejecución.
- [Kind](https://kind.sigs.k8s.io/), `kubectl`, [Helm 3](https://helm.sh/docs/intro/install/) y `curl`.
- Puertos libres en la máquina: `80` y `443` (The Store), `3000` (Grafana) y `9090` (Prometheus).
- Un canal de Discord donde puedas crear un webhook. Es opcional: sin él, las alertas igual se ven en Grafana.

## 2. Crear el clúster y desplegar The Store

```bash
git clone <este repo> && cd TPE_REDES
./local.sh create-cluster --skip-tests
```

Crea el clúster Kind `the-store`, instala el ingress NGINX, construye las 5 imágenes, las carga
en Kind y aplica `dist/kubernetes.yaml` en el namespace `the-store`.

**Verificar:** http://localhost muestra la tienda y `kubectl get pods -n the-store` lista 5 pods `Running`.

## 3. Configurar el webhook de Discord

1. En Discord: *Editar canal → Integraciones → Webhooks → Nuevo webhook → Copiar URL*.
2. Crear el `.env` (no se versiona):
   ```bash
   cp .env.example .env
   # editar .env:  DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
   ```

## 4. Instalar el stack

```bash
./observability.sh install
```

Tarda unos minutos y se puede repetir sin duplicar nada. Hace, en orden:

| Paso | Comando (resumido) | Archivo de configuración |
|---|---|---|
| 1. Repos de Helm y namespace `observability` | `helm repo add …`, `kubectl create namespace observability` | — |
| 2. Prometheus `29.31.1` | `helm upgrade --install prometheus prometheus-community/prometheus` | `observability/values/prometheus.yaml` |
| 3. Loki `7.3.0` | `helm upgrade --install loki grafana/loki` | `observability/values/loki.yaml` |
| 4. Promtail `6.17.1` | `helm upgrade --install promtail grafana/promtail` | `observability/values/promtail.yaml` |
| 5. Tempo `1.24.4` | `helm upgrade --install tempo grafana/tempo` | `observability/values/tempo.yaml` |
| 6. Secret y ConfigMaps de Grafana | `kubectl create secret/configmap … \| kubectl apply -f -` | `.env`, `observability/grafana/dashboards/`, `observability/grafana/alerting/` |
| 7. Grafana `10.5.15` | `helm upgrade --install grafana grafana/grafana` + `rollout restart` | `observability/values/grafana.yaml` |
| 8. Instrumentar The Store | `kubectl apply -f dist/kubernetes.yaml -n the-store` | `dist/kubernetes.yaml` |

Los comandos completos, para correrlos a mano, están en
[docs/observability-setup.md](docs/observability-setup.md#paso-a-paso-manual-lo-que-hace-install-por-dentro).

## 5. Qué configura cada pieza

### Prometheus (`prometheus.yaml`)
- Dos jobs de scraping cada 15 s:
  - `the-store-spring` (`/actuator/prometheus`): carts, orders y ui.
  - `the-store-native` (`/metrics`): catalog y checkout.
- Un `relabel_config` toma el nombre del servicio de la dirección (`carts.the-store.svc:80`) y lo
  guarda en la etiqueta `service="carts"`. Tableros y alertas filtran por esa etiqueta.
- Mantiene kube-state-metrics y node-exporter para el tablero de infraestructura.
  Alertmanager y Pushgateway están apagados: las alertas las maneja Grafana.
- Sin volumen persistente, con retención de 2 días.

### Loki y Promtail (`loki.yaml`, `promtail.yaml`)
- Loki en modo `SingleBinary`, con almacenamiento en el filesystem del pod (`emptyDir`).
- Promtail corre como DaemonSet, lee `/var/log/pods` y envía a
  `http://loki.observability.svc:3100`. Cada línea lleva las etiquetas `namespace`, `app`, `pod` y `container`.

### Tempo (`tempo.yaml`)
- Recibe trazas por OTLP en `:4318` (HTTP) y `:4317` (gRPC), con almacenamiento local.

### Instrumentación de The Store (`dist/kubernetes.yaml`)
Cambios sobre el manifiesto original, en cada deployment:

| Cambio | Servicios | Para qué |
|---|---|---|
| `OTEL_SDK_DISABLED=false` | carts, orders, ui | El SDK de OpenTelemetry viene apagado en los servicios Java |
| `OTEL_SERVICE_NAME=<svc>` | todos | Nombre del servicio en las trazas. En catalog, además, es lo que enciende el tracer |
| `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc:4318` | todos | Destino de las trazas |
| `OTEL_METRICS_EXPORTER=none`, `OTEL_LOGS_EXPORTER=none` | todos | Por OTLP solo viajan trazas: las métricas y los logs tienen su propio camino |
| `LOGGING_PATTERN_LEVEL=%5p [trace_id=%X{trace_id} span_id=%X{span_id}]` | carts, orders, ui | Cada línea de log lleva el `trace_id`, lo que permite saltar de una traza a sus logs |
| `livenessProbe` (`/actuator/health/liveness` o `/health`) | todos | Kubernetes reinicia el contenedor si deja de responder (caso 3.3.5) |
| `RETAIL_CHECKOUT_ENDPOINTS_ORDERS=http://orders` en el ConfigMap de checkout | checkout | Sin esto, checkout usa un orders simulado y orders no recibe tráfico |

### Grafana (`grafana.yaml` + `observability/grafana/`)
- **Datasources:** Prometheus, Loki y Tempo, fijos en el archivo y no editables desde la interfaz.
- **De traza a logs** (`tracesToLogsV2` en el datasource Tempo): el `service.name` del span se mapea
  a la etiqueta `app` de Loki. El botón *Logs for this span* busca las líneas con ese `trace_id`,
  con un margen de ±5 s.
- **Tableros** (`dashboards/*.json`, cargados desde el ConfigMap `grafana-dashboards`):
  - *The Store - Plataforma*: estado de los servicios, tasa de requests, errores y latencia,
    llamadas entre servicios, trazas con error o lentas y logs con error.
  - *The Store - Infraestructura*: réplicas, readiness, reinicios, CPU contra límite,
    throttling, memoria y nodo.
- **Alertas** (`alerting/*.yaml`, cargadas desde el ConfigMap `grafana-alerting`). Se evalúan cada 30 s:

  | Alerta | Condición | Sostenida | Severidad |
  |---|---|---|---|
  | Servicio caído | `up < 1` | 1 min | critical |
  | Tasa de errores 5xx elevada | > 5 % de respuestas 5xx | 1 min | critical |
  | Latencia elevada | promedio > 1 s | 1 min | warning |
  | CPU saturada (throttling) | > 50 % de períodos limitados | 1 min | warning |
  | Contenedor reiniciándose | > 0 reinicios en 5 min | inmediata | critical |

  Todas van al contact point `discord-equipo`. El webhook entra como variable de entorno desde el
  Secret `grafana-discord`.

## 6. Verificar la instalación

```bash
./observability.sh status   # pods, releases de Helm, targets de Prometheus y caos activo
./observability.sh ui       # Grafana http://localhost:3000 (admin/admin) · Prometheus http://localhost:9090
```

En otra terminal, generar tráfico (sin requests no hay métricas ni trazas):

```bash
./observability.sh traffic 300 3   # 3 usuarios comprando durante 5 minutos
```

Checklist:
- [ ] `status` muestra los 5 servicios `-> UP`.
- [ ] En Grafana → *Dashboards → The Store* están los dos tableros, con datos.
- [ ] *Explore → Tempo* muestra trazas de `ui`, y desde un span, *Logs for this span* abre sus logs.
- [ ] *Alerting → Alert rules* lista las 5 reglas en estado *Normal*.

## 7. Probar los casos de uso

Con el tráfico corriendo:

| Caso | Comando | Qué se ve |
|---|---|---|
| 3.3.1 Errores | `./observability.sh chaos errors catalog 500` | % 5xx de catalog en ~100 %, alerta *Tasa de errores 5xx* y aviso en Discord |
| 3.3.2 Latencia | `./observability.sh chaos latency catalog 2000` | Latencia en varios segundos y alerta *Latencia elevada* |
| 3.3.3 Causa raíz | (con 3.3.1 activo) | Traza con error → span de catalog → *Logs for this span* |
| 3.3.4 Visión unificada | — | Tablero *Plataforma* |
| 3.3.5 Infraestructura | `./observability.sh chaos cpu carts 50` | Throttling, pod sin readiness, reinicios por liveness y sus alertas |
| Volver a la normalidad | `./observability.sh chaos reset` | Las alertas se resuelven y llega el aviso a Discord |

El guion detallado de la demo está en [docs/demo.md](docs/demo.md).

## 8. Uso diario

| Comando | Cuándo |
|---|---|
| `./observability.sh start` / `stop` | Prender o apagar el clúster sin perder nada |
| `./observability.sh reload-grafana` | Después de cambiar tableros, alertas o el `.env` |
| `./observability.sh install` | Después de cambiar `observability/values/` o `dist/kubernetes.yaml`, o con un clúster nuevo |
| `./observability.sh reset-data` | Borrar métricas, logs, trazas e historial de alertas para empezar de cero |
| `./observability.sh uninstall` | Borrar el namespace `observability` |

Los datos no tienen volumen persistente: sobreviven a `stop`/`start`, pero se pierden si se
recrea el pod o el clúster.

## 9. Problemas comunes

| Síntoma | Causa | Solución |
|---|---|---|
| Al prender el clúster, errores `Failed to export spans` / `UnknownHostException: tempo…` | Los servicios arrancan antes que el DNS y Tempo | Ninguna: desaparecen solos en ~30 s |
| Un servicio figura `DOWN` | El pod no está listo o quedó caos aplicado | `kubectl get pods -n the-store`; `./observability.sh chaos reset` |
| No llegan avisos a Discord | Webhook vacío o incorrecto en `.env` | Corregir `.env` y correr `./observability.sh reload-grafana`; revisar `kubectl logs -n observability deploy/grafana \| grep -i discord` |
| Tableros vacíos | No hay tráfico | `./observability.sh traffic` |
| Con `chaos cpu carts 50`, carts nunca vuelve | Con 50m no termina de arrancar antes de que la liveness probe lo reinicie: es el comportamiento esperado | `./observability.sh chaos reset` |
