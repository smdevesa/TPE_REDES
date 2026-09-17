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