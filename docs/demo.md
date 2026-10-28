# Guion de demo: casos de uso de la Reentrega

Este es **el flujo a seguir** en la presentación, en el mismo orden que la PPT:
3.3.4 → 3.3.1 → 3.3.3 → 3.3.2 → 3.3.5. Duración: 15-20 minutos.

Cada paso tiene tres partes:
- ▶ **Hacer**: el comando o el click.
- 👀 **Se ve**: lo que tiene que aparecer en pantalla. Si no aparece, ir a [Si algo sale mal](#si-algo-sale-mal-en-vivo).
- 💬 **Decir**: la idea a transmitir, en una o dos frases.

**Tiempos que conviene saber de memoria**

| Qué | Cuánto tarda |
|---|---|
| Curvas de los paneles (calculan sobre el último minuto) | ~1 min en subir o bajar del todo |
| Alertas (se evalúan cada 30 s y deben sostenerse 1 min) | 1-2 min hasta *Firing* y Discord |
| Alerta **Contenedor reiniciándose** | inmediata |
| Caso CPU completo, hasta los reinicios | 3-4 min |

Mientras se espera una alerta, se explica el panel o la traza: nunca quedarse mirando la pantalla.

> Las horas de los mensajes de Discord están en **UTC** (3 horas más que la hora local de Argentina).

---

## 0 · Preparación (10 minutos antes, sin público)

▶ **Terminal 1** (queda para los comandos de caos):
```bash
./observability.sh start            # si el clúster estaba apagado
./observability.sh status           # verificar que todo esté sano
./observability.sh chaos reset      # por las dudas
./observability.sh reset-data       # opcional: borra datos de pruebas anteriores
```
👀 `status`: pods de `the-store` y `observability` en Running, los 5 targets en `-> UP` y la sección *Caos activo* sin límites de CPU.

▶ **Terminal 2** (no cerrarla):
```bash
./observability.sh ui               # Grafana http://localhost:3000 (admin/admin)
```

▶ **Terminal 3** (no cerrarla):
```bash
./observability.sh traffic 1800 3   # 30 min, 3 usuarios comprando
```
👀 `Generando tráfico contra http://localhost durante 1800s con 3 usuarios…` y la terminal queda ocupada. El tráfico tiene que estar corriendo **antes y durante** cada caos: sin requests no hay errores ni latencia que medir.

▶ Pestañas abiertas en el navegador, en este orden:
1. Grafana → Dashboards → The Store → **The Store - Plataforma**.
2. Grafana → **The Store - Infraestructura**.
3. El canal de **Discord**.
4. http://localhost (la tienda).

▶ Esperar **2 minutos** de tráfico normal.
👀 En *Plataforma*: 5 servicios en verde, *Alertas activas* vacía, *Errors* en 0 %, *Duration* en pocos ms.

> Si se corrió `reset-data`, el port-forward se corta: volver a correr `ui` en la terminal 2 y entrar de nuevo con admin/admin.

---

## 0.5 · Qué se desplegó (1 minuto)

▶ En la terminal 1:
```bash
kubectl get pods -n observability
```
👀 Grafana, Prometheus (server, kube-state-metrics, node-exporter), Loki, Promtail y Tempo, todos en Running.

💬 "Todo el stack se instaló con Helm en un namespace aparte, `observability`. A los microservicios no les cambiamos código: solo activamos OpenTelemetry con variables de entorno en el manifiesto. Grafana se configura entero desde archivos del repo: fuentes de datos, tableros, alertas y Discord."

---

## 1 · Caso 3.3.4 · Vista única de la plataforma

**Pestaña: The Store - Plataforma.**

**Paso 1.1 · Las cuatro preguntas.**
▶ Recorrer el tablero de arriba hacia abajo, señalando cada fila.
👀
- **Estado de los servicios:** ui, catalog, carts, orders y checkout en verde (UP).
- **Alertas activas:** vacía.
- **Rate:** catalog ~45, carts ~37, ui ~25, orders ~3 req/s.
- **Errors:** todos en 0 %. **Duration:** todos por debajo de 5 ms.
- **Llamadas salientes:** filas de ui, checkout, catalog y orders.
- **Trazas con error o lentas:** vacía o casi vacía.
- **Logs con error:** sin barras o casi.

💬 "El tablero se lee de arriba hacia abajo: ¿está todo vivo?, ¿qué está mal?, ¿dónde?, ¿por qué? Las métricas dicen qué, las trazas dónde y los logs por qué, en una sola pantalla."

**Paso 1.2 · El mapa de dependencias.**
▶ En *Llamadas salientes*, expandir una fila con la flecha de la izquierda.
👀 Destinos (`server.address` / `http.url`), base de datos (`db.system`) y código HTTP. Se ven: ui → catalog, carts y checkout; checkout → orders; catalog → sqlite; orders → h2.

💬 "Esto es el mapa real de quién llama a quién, sacado de las trazas, sin leer el código."

**Paso 1.3 · Una compra de punta a punta.**
▶ En *Llamadas salientes*, buscar una fila de **checkout** y hacer click en su **Trace ID**.
👀 La traza **`POST /checkout/payment`** (~15 ms) con 5 servicios:
- **ui** (Java) recibe el pago y llama a carts, catalog y checkout;
- **catalog** (Go) consulta su base (`gorm.Query`);
- **checkout** (Node.js) llama a **orders** (Java);
- orders hace los `INSERT` en su base de datos.

💬 "Una compra real atraviesa los cinco servicios y los tres lenguajes de la plataforma, y la vemos como una sola traza."

**Paso 1.4 · Cursor compartido.**
▶ Cerrar la traza y pasar el mouse por el gráfico *Rate*.
👀 Una línea vertical marca la misma hora en todos los gráficos del tablero.

💬 "Cuando pase algo, esto nos va a dejar cruzar métricas y logs en el mismo instante, sin sincronizar horarios a mano."

---

## 2 · Caso 3.3.1 · Degradación detectada por alerta

**Paso 2.1 · Provocar la falla.**
▶ En la terminal 1 (decir la hora en voz alta o anotarla):
```bash
./observability.sh chaos errors catalog 500     # POST /chaos/status/500 en catalog
```
👀 `POST catalog/chaos/status/500 -> HTTP 200`.

💬 "Usamos el endpoint de caos que ya trae catalog: a partir de ahora responde 500 a todo."

**Paso 2.2 · El panel lo muestra (≈ 30 s - 1 min).**
▶ Mirar *Errors · % de respuestas 5xx*. Click en **catalog** en la leyenda y Ctrl+click en **ui**.
👀 catalog sube a **~100 %** y ui a **~45 %**. En *Logs con error por servicio* aparecen barras.

💬 "Catalog falla y arrastra a ui: es una falla en cascada. Ui depende de catalog para listar productos y también para agregar al carrito, porque primero busca el producto."

**Paso 2.3 · La alerta (≈ 1-2 min).**
▶ Mirar *Alertas activas*.
👀 **Tasa de errores 5xx elevada** para catalog y ui, primero en *Pending* y después en *Firing*.

💬 "Pending significa que se está confirmando: la condición tiene que sostenerse un minuto, para no avisar por un pico aislado."

**Paso 2.4 · Discord.**
▶ Pasar a la pestaña de Discord.
👀 Dos mensajes (uno por servicio):
```
🔥 [ALERTA] Tasa de errores 5xx elevada · catalog
🔴 1 alerta(s) activa(s) en The Store
Servicio: catalog · Severidad: critical
catalog está respondiendo 100% de sus requests con error 5xx.
Umbral: 5% durante 1 minuto. Revisar trazas con error y logs del servicio en el tablero.
🕒 Desde hh:mm:ss UTC
📊 Ver panel
```

💬 "El tiempo de detección fue de 1 a 2 minutos desde que empezó la falla [comparar con la hora del paso 2.1, sumando 3 horas]. Y no hizo falta que nadie estuviera mirando el tablero."

**Paso 2.5 · Del mensaje al tablero.**
▶ Click en **📊 Ver panel**.
👀 Se abre Grafana en el panel *Errors* del tablero Plataforma.

⚠️ **No hacer reset.** El caso siguiente usa esta misma falla.

---

## 3 · Caso 3.3.3 · Causa raíz: de la traza a los logs exactos

Con la falla de catalog **todavía activa**.

**Paso 3.1 · Elegir la traza.**
▶ En *Trazas con error o lentas*, click en el **Trace ID** de una traza de **ui** con nombre **`GET /catalog`**.
👀 Se abre la cascada. Arriba, el span raíz `GET /catalog` de ui. Debajo, filas que dicen solo **GET**.

💬 "La alerta nos dijo qué. Ahora vamos a ver dónde."

**Paso 3.2 · Dónde falló.**
▶ Click en la fila **GET** que tiene el **"!" rojo**.
👀 En los atributos del span: `server.address = catalog` y `http.response.status_code = 500`. La otra llamada (a carts) da 200 y tiene debajo el span de carts. Debajo de la llamada a catalog **no hay span de catalog**.

💬 "Las filas GET son las llamadas que hace ui. La que falló va a catalog y recibe un 500. Catalog ni llegó a procesar el pedido: el error se produce en su entrada."

**Paso 3.3 · Los logs exactos.**
▶ En ese mismo span, click en el ícono **LOG** (a la derecha de la fila).
👀 Se abre Loki con la consulta ya armada. Aparece **la línea de este request**, con el mismo `trace_id`:
```
ERROR [trace_id=<el de esta traza> span_id=…] … 500 Server Error for HTTP GET "/catalog"
```

💬 "Grafana pasó de la traza a los logs con el ID de la traza. No son los logs de ese minuto: son los de este request en particular."

**Paso 3.4 · La excepción.**
▶ Pasar el mouse sobre la línea → **Show context**.
👀 Las líneas siguientes: `com.microsoft.kiota.ApiException: service returned status code500` y el stack trace.

💬 "Esto es lo que antes requería entrar al pod con `kubectl logs` y buscar a mano por horario."

**Paso 3.5 · El lado de catalog.**
▶ Volver al tablero. Pasar el mouse sobre *Últimos logs con error* y apretar `v` para agrandarlo.
👀 Líneas de catalog: `[GIN] … | 500 | … GET "/catalog/…"`. `Esc` para volver.

💬 "Sin abrir ningún pod y en tres clicks: qué servicio (catalog), qué llamada (ui → GET /catalog) y qué error (500 con su excepción)."

> **Pregunta probable: "¿por qué la excepción está en ui y no en catalog?"** El caos corta el request en la entrada de catalog, antes de que corra su código. Catalog solo registra la respuesta 500 en su log de acceso (`[GIN]`). Quien recibe el error y lo loguea con la excepción es ui, que es quien llamó. Es lo mismo que pasaría con una caída real.

**Paso 3.6 · Resolver.**
▶ En la terminal 1:
```bash
./observability.sh chaos reset
```
👀 La terminal muestra `DELETE …/chaos/status -> HTTP 200` por servicio y termina con `Listo.`. En ~1 min *Errors* baja a 0 %.

💬 Mientras baja: "Ahora vamos a ver qué pasa cuando no hay errores, pero el sitio anda lento."

**Seguir con el caso 3.3.2 sin esperar.** El mensaje de resolución llega en 1-2 minutos y se muestra en el paso 4.2:
```
✅ [RESUELTO] Tasa de errores 5xx elevada · catalog
🟢 1 alerta(s) resuelta(s)
… 🕒 Activa de hh:mm:ss a hh:mm:ss UTC
```

---

## 4 · Caso 3.3.2 · Cuello de botella

**Paso 4.1 · Provocar la demora.**
▶ En la terminal 1:
```bash
./observability.sh chaos latency catalog 2000   # POST /chaos/latency/2000 en catalog
```
👀 `POST catalog/chaos/latency/2000 -> HTTP 200`. Abrir http://localhost/catalog en la tienda: tarda varios segundos en cargar.

💬 "Ahora catalog demora 2 segundos cada respuesta. No hay errores: el sitio simplemente anda lento."

**Paso 4.2 · Discord: la resolución anterior.**
▶ Pasar a Discord.
👀 **✅ [RESUELTO] Tasa de errores 5xx elevada** para catalog y ui.

💬 "Grafana también avisa cuando el problema se resuelve, con el tiempo que estuvo activo."

**Paso 4.3 · Las métricas (≈ 1-2 min).**
▶ Volver al tablero, panel *Duration · latencia promedio*.
👀 ui y catalog suben a varios segundos (zona naranja). En *Alertas activas* y en Discord: **Latencia elevada** para catalog y para ui. *Errors* sigue en 0 %.

💬 "Las métricas dicen que ui y catalog están lentos. Pero no sabemos si ui es lento por sí mismo, por la red, por catalog o por la base de datos."

**Paso 4.4 · La traza lenta.**
▶ En *Trazas con error o lentas*, click en una traza **`GET /catalog`** de **~6 s**.
👀 Tres filas **GET** de ui → catalog de **2 s cada una**, una detrás de otra. Los spans de catalog debajo y su consulta a sqlite duran **~0 ms**. La llamada de ui → carts tarda pocos ms.

**Paso 4.5 · Descartar opciones (con la misma traza).**
💬 Ir señalando:
- "**Frontend:** casi todo el tiempo de ui está dentro de las llamadas a catalog; ui no demora por sí mismo."
- "**Red:** la llamada a carts va por la misma red y tarda milisegundos."
- "**Base de datos:** la consulta de catalog a sqlite tarda cero."
- "**Microservicio:** queda catalog, en la entrada, antes de procesar el pedido. Y como ui llama tres veces a catalog, una demora de 2 s se convierte en 6 s para el usuario."

**Paso 4.6 · Resolver.**
▶ En la terminal 1:
```bash
./observability.sh chaos reset
```
👀 Termina con `Listo.`. *Duration* vuelve a pocos ms en ~1 min y llega **✅ [RESUELTO] Latencia elevada** a Discord.

---

## 5 · Caso 3.3.5 · Incidente de infraestructura (CPU limitada)

**Paso 5.1 · El tablero de infraestructura en estado normal.**
▶ Pasar a la pestaña **The Store - Infraestructura**.
👀
- *Réplicas disponibles / deseadas* al 100 % y *Reinicios (última hora)* en 0.
- *Pods listos* todo en verde.
- *Uso de CPU por pod*: el uso, muy por debajo de la línea punteada (la CPU reservada, el request). No hay línea roja porque no hay límites.
- *Saturación · % de CPU throttling*: sin datos.
- *Nodo del clúster*: CPU y memoria del nodo.

💬 "Este tablero mira los recursos sobre los que corre la plataforma: deployments, pods y el nodo. Sirve cuando el sitio anda mal y no hay un error claro en la aplicación."

**Paso 5.2 · Limitar la CPU.**
▶ En la terminal 1:
```bash
./observability.sh chaos cpu carts 50           # límite (y request) de CPU = 50m en carts
```
👀 `Limitando la CPU de carts a 50m (el pod se recrea con el nuevo límite)`.

💬 "Le dejamos a carts la vigésima parte de un núcleo, como si alguien hubiera configurado mal un límite."

**Paso 5.3 · Saturación (≈ 1 min).**
▶ Aislar **carts** en la leyenda de *Uso de CPU por pod*.
👀 Aparece la **línea roja** del límite en 0,05 y el uso de carts queda pegado a ella. En *Saturación*, carts sube a **~90 %**.

💬 "Throttling es el tiempo en que el contenedor quiso más CPU de la que tiene permitida. Nueve de cada diez veces lo frenan."

**Paso 5.4 · Alertas y reinicios (≈ 2-4 min).**
▶ Mirar *Reinicios en el tiempo*, *Reinicios (última hora)* y *Pods listos*.
👀 En este orden:
1. **CPU saturada (throttling)** para el pod de carts (*Pending* → *Firing* → Discord).
2. Aparecen barras en *Reinicios en el tiempo* → **Contenedor reiniciándose** dispara **en el momento** y llega a Discord.
3. *Pods listos*: carts en rojo → **Servicio caído** para carts.

💬 "Con tan poca CPU, carts no llega a responder el chequeo de vida que hace Kubernetes, y Kubernetes lo reinicia. Esa alerta no espera un minuto porque un reinicio ya es un hecho."

**Paso 5.5 · El impacto en el usuario.**
▶ Click en el link **Plataforma** (arriba a la derecha; mantiene el rango de tiempo).
👀 *Errors* y *Duration* de ui suben: el carrito no responde.

💬 "Un problema de infraestructura termina siendo un problema del usuario. Con los dos tableros se ve la causa y el efecto."

**Paso 5.6 · Descartar la máquina.**
▶ Volver a *Infraestructura*, fila **Nodo del clúster**.
👀 CPU y memoria del nodo normales.

💬 "El nodo está bien: el problema es el límite de un pod, no el hardware. Se resuelve corrigiendo el deployment."

**Paso 5.7 · Resolver.**
▶ En la terminal 1:
```bash
./observability.sh chaos reset                  # quita el límite y vuelve a aplicar el manifiesto
```
👀 `carts: límite de CPU quitado` y, al rato, `Listo.`. La línea roja desaparece, carts vuelve a verde en ~1 min y llegan los **✅ [RESUELTO]** a Discord.

💬 Cierre: "Detectamos, ubicamos y explicamos cinco incidentes distintos sin entrar a ningún pod y sin modificar el código de la aplicación."

---

## Checklist: qué punto de la reentrega cubre cada paso

| Reentrega | Paso de la demo |
|---|---|
| 2.1 Trazas OTLP → Tempo, sin tocar código | 0.5 y 1.3 |
| 2.2 Métricas RED con Prometheus | 1.1, 2.2 y 4.3 |
| 2.3 Logs con Promtail → Loki | 3.3 a 3.5 |
| 2.4 `tracesToLogsV2`: de un span a sus logs | 3.3 |
| 3.1 Kind, 5 servicios, Java, Go y Node.js | 1.3 |
| 3.1 Namespace `observability` vía Helm | 0.5 |
| 3.1 Alertas reflejadas en los tableros | 2.3, 4.3 y 5.4 |
| 3.1 Extra mile: Discord, con servicio, link y resolución | 2.4, 2.5 y 4.2 |
| 3.3.1 Bajo tiempo de detección | 2.1 → 2.4 |
| 3.3.2 Frontend, red, microservicio o base de datos | 4.4 y 4.5 |
| 3.3.3 Logs sin consultar pods | 3.3 a 3.5 |
| 3.3.4 Una sola pantalla | Caso 1 completo |
| 3.3.5 Deployments, nodos, pods, CPU y reinicios | Caso 5 completo |

---

## Si algo sale mal en vivo

| Problema | Qué hacer |
|---|---|
| No sé qué quedó activo | `./observability.sh status` (targets, pods y límites de CPU) |
| Quiero volver todo a la normalidad | `./observability.sh chaos reset` |
| Los paneles están vacíos o no se mueven | Revisar que `traffic` siga corriendo en la terminal 3 |
| Grafana no carga (se cortó el port-forward) | Ctrl+C en la terminal 2 y volver a correr `ui` |
| Grafana no muestra tableros o alertas | `./observability.sh reload-grafana` y después volver a correr `ui` |
| La tabla de trazas parece vieja | Esperar un refresco (10 s) o pasar el rango a *Last 5 minutes* |
| No aparece la traza `GET /catalog` con error | Usar cualquier traza de ui con error: el span con "!" sigue yendo a catalog |
| La alerta tarda | Es normal hasta 2 min: seguir explicando el panel o la traza |
| No llega nada a Discord | Revisar que `.env` tenga el webhook y correr `./observability.sh install` |
