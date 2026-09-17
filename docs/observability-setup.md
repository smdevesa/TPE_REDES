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
