# Guion de demo: casos de uso de la Reentrega

Tiempos aproximados medidos en el clúster local. Las alertas usan `for: 1m` y se evalúan
cada 30 s, así que cada una tarda entre **1 y 2 minutos** en dispararse.

## Preparación (antes de la presentación)

```bash
./observability.sh start            # si el clúster estaba apagado
./observability.sh status           # los 5 targets en UP y sin caos activo
./observability.sh chaos reset      # por las dudas
./observability.sh reset-data       # opcional: borra datos de pruebas anteriores
```

En otra terminal:

```bash
./observability.sh ui               # Grafana :3000, Prometheus :9090
```

Y en una tercera, tráfico durante toda la demo:

```bash
./observability.sh traffic 1800 3   # 30 min, 3 usuarios comprando
```

Dejar abiertos: el tablero **The Store - Plataforma**, el canal de Discord y http://localhost.

---

## 3.3.4 · Vista única de la plataforma (empezar por acá)
Recorrer el tablero **The Store - Plataforma**:
1. Estado de los 5 servicios (`up`) y alertas activas (vacío).
2. RED: requests/s, % 5xx y latencia por servicio.
3. Llamadas salientes: spans *client* de Tempo (ui → catalog, carts, checkout; checkout → orders; catalog y orders → su base de datos).
4. Trazas con error o lentas, y logs con error de Loki.

## 3.3.1 · Degradación detectada por alerta
```bash
./observability.sh chaos errors catalog 500     # POST /chaos/status/500
```
- En el tablero, el panel *Errors* de catalog sube a ~100 % y ui también sube (efecto cascada).
- *Alertas activas* pasa a Pending y después a Firing.
- **Discord** recibe "🔥 [ALERTA] Tasa de errores 5xx elevada · catalog", con el link al panel.

Se usa catalog porque sus métricas (`gin_requests_total`) registran el 500 inyectado. En
carts y orders, el filtro de caos corre antes que el de métricas de Spring y el error no
aparece en sus propias métricas (sí en ui y en las trazas).

## 3.3.3 · Causa raíz: de la traza a los logs (sin `kubectl logs`)
Con el caos del punto anterior todavía activo:
1. Panel *Trazas con error o lentas*: hacer click en una traza de ui con error.
2. En la cascada, el span *client* de ui hacia `catalog` aparece con status 500.
3. En el span, **Logs for this span** abre Loki filtrado por `{app="..."}` en esa ventana de tiempo (`tracesToLogsV2`).
4. Mostrar el log de error correlacionado.

```bash
./observability.sh chaos reset
```
- Discord recibe "✅ [RESUELTO] …".

## 3.3.2 · Cuello de botella
```bash
./observability.sh chaos latency catalog 2000   # POST /chaos/latency/2000
```
- El panel *Duration* sube; la alerta **Latencia elevada** dispara para ui.
- En *Trazas con error o lentas*, abrir una traza `GET /catalog` de ~6 s: tiene 3 spans
  *client* de ui → catalog de 2 s cada uno, y los spans *server* de catalog de ~0 ms.
- Conclusión: la demora está en la entrada de catalog (su capa HTTP), no en el frontend,
  en otro servicio ni en la base de datos.

```bash
./observability.sh chaos reset
```

## 3.3.5 · Incidente de infraestructura (CPU limitada)
Abrir el tablero **The Store - Infraestructura**.
```bash
./observability.sh chaos cpu carts 50           # límite (y request) de CPU = 50m
```
Secuencia observada (≈ 3-4 min):
1. El pod se recrea con el nuevo límite; *Uso de CPU vs. límite* queda pegado al límite.
2. *Saturación · % de CPU throttling* sube a ~90 % → alerta **CPU saturada**.
3. La aplicación no termina de arrancar a tiempo, falla la liveness probe y Kubernetes la
   reinicia → *Reinicios* sube → alerta **Contenedor reiniciándose**.
4. *Pods listos* en rojo → **Servicio caído** para carts, y errores en ui (cascada).

Resolución:
```bash
./observability.sh chaos reset                  # quita el límite y restaura el manifiesto
```

---

## Si algo sale mal en vivo
- `./observability.sh status` muestra qué está caído y si hay límites de CPU activos.
- `./observability.sh chaos reset` deja todo como al principio.
- Si Grafana no muestra tableros: `./observability.sh reload-grafana`.
