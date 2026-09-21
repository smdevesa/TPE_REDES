# Observability Setup: Prometheus + Grafana

## Prerrequisitos

- [Helm 3](https://helm.sh/docs/intro/install/) instalado
- Un clúster Kubernetes funcionando (Kind, EKS, Minikube, etc.)
- `kubectl` configurado y apuntando al clúster correcto

## 1. Crear el namespace

```bash
kubectl create namespace observability
```

## 2. Agregar repos de Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

Para verificar que los repos se agregaron correctamente:

```bash
helm repo list
```

## 3. Instalar Prometheus

Desde la raíz del repo:

```bash
helm install prometheus prometheus-community/prometheus \
  --namespace observability \
  --values prometheus-values.yaml
```

`prometheus-values.yaml` configura:
- Desactiva alertmanager y pushgateway
- Sin persistent volume
- Scrapea los servicios de la app:
  - **Spring Boot** (`/actuator/prometheus`): `carts`, `orders`, `ui`
  - **Nativos** (`/metrics`): `catalog`, `checkout`

## 4. Instalar Grafana

Desde la raíz del repo:

```bash
helm install grafana grafana/grafana \
  --namespace observability \
  --values grafana-values.yaml
```

`grafana-values.yaml` configura:
- Conecta automáticamente a Prometheus como datasource
- Password admin: `admin`
- Username: `admin`
- Sin persistent volume

## 5. Verificar

```bash
kubectl get pods -n observability
```

Deberías ver algo como:

```
NAME                                             READY   STATUS    RESTARTS   AGE
prometheus-server-xxxxx                          1/1     Running   0          1m
grafana-xxxxx                                    1/1     Running   0          1m
```

## 6. Acceder a Grafana

Port-forward para acceder desde tu máquina:

```bash
kubectl port-forward -n observability svc/grafana 3000:80
```

Abrí http://localhost:3000 en el browser.

Credenciales:
- **Usuario:** `admin`
- **Contraseña:** `admin`

Desde Grafana podés consultar las métricas de Prometheus que ya están siendo scraheadas de los servicios del clúster.

## 7. Acceder a Prometheus

```bash
kubectl port-forward -n observability svc/prometheus-server 9090:80
```

Abrí http://localhost:9090 para ver la UI de Prometheus y verificar que los targets estén activos. Podes acceder a http://localhost:9090/targets

## 8. Instalar Loki + Promtail (logs)

Agrega centralización de logs a lo ya instalado.

### 8.1. Instalar Loki (Loki single-binary)

```bash
helm install loki grafana/loki \
  --namespace observability \
  --values loki-values.yaml
```

`loki-values.yaml` (ya está en el repo) configura:
- Modo single-binary (`deploymentMode: SingleBinary`)
- Almacenamiento en filesystem con `emptyDir` (sin persistent volume)
- `auth_enabled: false`
- Componentes auxiliares desactivados (cachés, canary, gateway) para ahorrar RAM en Kind

### 8.2. Instalar Promtail

```bash
helm install promtail grafana/promtail \
  --namespace observability \
  --set "config.clients[0].url=http://loki.observability.svc:3100/loki/api/v1/push"
```

- Promtail corre como **DaemonSet** (un pod por nodo), lee los logs de los contenedores (`/var/log/containers/*.log`) y los pushea a Loki.
- El `--set` indica a dónde pushear (`loki.observability.svc:3100`).

### 8.3. Verificar

```bash
kubectl get pods -n observability
```

Deberías ver algo como:

```
NAME                                             READY   STATUS    RESTARTS   AGE
loki-0                                           1/1     Running   0          1m
promtail-xxxxx                                   1/1     Running   0          1m
```

Sanity check en Grafana → **Explore** → datasource **Loki**:

```
{namespace="the-store"}
```

Deberías ver las líneas de log de los servicios (catalog, cart, orders, checkout, ui).

## 9. Upgrade de Grafana si ya estaba levantado con solo Prometheus

Si Grafana ya se había instalado **antes** de agregar Loki (solo con el paso 4), el datasource de **Loki no se agrega solo**: hay que upgradear la release para que tome el datasource nuevo.

`grafana-values.yaml`:** agregar el datasource Loki al archivo:

```yaml
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-server.observability.svc:80
        isDefault: true
        editable: true
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.observability.svc:3100
        editable: true
```

Y upgradear:

```bash
helm upgrade grafana grafana/grafana \
  --namespace observability \
  --values grafana-values.yaml
```

## 10. Instalar Tempo (traces)

Agrega trazabilidad (distributed tracing) a lo ya instalado. La stack queda: **Prometheus** (métricas), **Loki** (logs) y **Tempo** (traces).

### 10.1. Instalar Tempo (single-binary)

```bash
helm install tempo grafana/tempo \
  --namespace observability \
  --values tempo-values.yaml
```

`tempo-values.yaml` (ya está en el repo) configura:
- Almacenamiento en filesystem local (`backend: local`) sin persistent volume
- Receivers OTLP habilitados: HTTP en `:4318` y gRPC en `:4317`
- Sin persistencia

### 10.2. Verificar

```bash
kubectl get pods -n observability
kubectl get svc tempo -n observability
```

Deberías ver algo como:

```
NAME                  READY   STATUS    RESTARTS   AGE
tempo-xxxxx           1/1     Running   0          1m
```

Y el service `tempo` exponiendo los puertos `3200` (frontend), `4317` (OTLP gRPC) y `4318` (OTLP HTTP).

## 11. Conectar los microservicios a Tempo

Una vez instalado, cada servicio debe exportar sus trazas por **OTLP HTTP** al receiver de Tempo (`tempo.observability.svc:4318`). Esto se hace seteando variables de entorno en los Deployments con `kubectl set env` (la release hace un rolling update).

### 11.1. Microservicios Java (orders, carts, ui)

Los servicios Java traen el SDK de OpenTelemetry **apagado por defecto** (`otel.sdk.disabled: true` en `application.yml`). Estas env lo desbloquean y apuntan a Tempo:

```bash
kubectl set env deployment/carts -n the-store \
  OTEL_SDK_DISABLED=false \
  OTEL_SERVICE_NAME=carts \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc:4318

kubectl set env deployment/orders -n the-store \
  OTEL_SDK_DISABLED=false \
  OTEL_SERVICE_NAME=orders \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc:4318

kubectl set env deployment/ui -n the-store \
  OTEL_SDK_DISABLED=false \
  OTEL_SERVICE_NAME=ui \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc:4318
```

### 11.2. Microservicio Go (catalog)

En `catalog` la presencia de `OTEL_SERVICE_NAME` es el gatillo que inicializa el tracer (`main.go`). Sin esa variable, no exporta trazas:

```bash
kubectl set env deployment/catalog -n the-store \
  OTEL_SERVICE_NAME=catalog \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc:4318
```

### 11.3. Microservicio Node (checkout)

`checkout` ya inicializa el SDK de OpenTelemetry siempre; estas env fijan el nombre del servicio y redirigen el exporter a Tempo:

```bash
kubectl set env deployment/checkout -n the-store \
  OTEL_SERVICE_NAME=checkout \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc:4318
```