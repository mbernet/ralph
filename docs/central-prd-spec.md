# Spec: API central de tareas para Ralph

Estado: borrador · 2026-11-04 · Schema de tarea: [`task.schema.json`](task.schema.json)

## 0. Qué es un Ralph loop

Un Ralph loop es un script (`ralph.sh`) que lanza un agente de código una y otra vez hasta terminar un PRD. El PRD es un `prd.json` con una lista de user stories: cada una tiene título, descripción, criterios de aceptación, prioridad y un flag `passes`. Cada iteración arranca un agente nuevo, con contexto limpio, que lee el PRD, coge la historia pendiente de mayor prioridad, la implementa, pasa los checks del proyecto, hace commit, marca `passes: true` y escribe lo aprendido en `progress.txt`. El agente no recuerda nada entre iteraciones: su única memoria es git, el `prd.json` y el `progress.txt`. El bucle acaba cuando todas las historias pasan.

El patrón es de [Geoffrey Huntley](https://ghuntley.com/ralph/). Funciona porque cada historia es pequeña y el agente empieza cada vez sin el ruido de la anterior. Su límite es que todo vive en ficheros locales de un único checkout: un solo worker, sin revisión y sin PR.

Esta spec sustituye esos ficheros por una API. Las historias pasan a llamarse tareas, `passes` se convierte en un pipeline de etapas y `progress.txt` en los resúmenes de las tareas terminadas.

## 1. Objetivo

Sustituir el `prd.json` local por una API que comparten varios workers de Ralph sobre el mismo proyecto. Cada tarea pasa por un pipeline de etapas y acaba mergeada en `main` mediante PR, sin intervención humana salvo en casos graves.

Principio rector: máxima autonomía con el diseño más simple posible. La API guarda tareas, reparte trabajo y aplica las transiciones. No sabe nada de git, de prompts ni de modelos. Todo el contexto que necesita un agente vive en el JSON de la tarea; el PR no lleva nada que la API no tenga.

### Fuera de alcance

- Usuarios, roles y permisos. Un único token por despliegue.
- Notificaciones y webhooks.
- Borrar proyectos o tareas.
- Etapas en paralelo. El pipeline es una lista ordenada y cada tarea está en una sola etapa.
- Workers especializados. Todo worker puede ejecutar cualquier etapa.

## 2. Conceptos

| Concepto | Qué es |
|---|---|
| Proyecto | Un PRD: su descripción, su pipeline y sus tareas. |
| Pipeline | Lista ordenada de etapas que define cada proyecto. El servidor no sabe qué hace cada una; solo distingue la primera, las intermedias y la última. |
| Tarea | Una user story. Tres partes: `spec` (la escribe una persona), `state` (mínimo estado mutable) y `runs` (historial de solo añadir). |
| Etapa (`stage`) | En qué etapa del pipeline está la tarea, o `done` cuando ha salido por el final. |
| Worker | Un proceso `ralph.sh` con un checkout del repo. Se identifica con un nombre estable, por ejemplo `mac-marc`. |
| Claim | Reserva de una tarea por un worker para ejecutar **una** etapa. Caduca sola; no se libera a mano. Su `id` evita que un worker colgado escriba encima de otro. |
| Run | Resultado de una ejecución de un agente sobre una tarea. Inmutable. |
| Sick | Marca de que la tarea no avanza por medios normales. La siguiente ejecución la hace el agente `doctor`. |
| Doctor | Etapa de run, no de pipeline. Diagnostica una tarea `sick` y la devuelve al circuito o la deja para una persona. |

Lo que el servidor exige a un pipeline es poco: la primera etapa produce el PR y declara asunciones; las demás pueden rechazar y devolver la tarea a la primera; la última, al aprobar, cierra la tarea con un resumen. Todo lo demás es cosa de los prompts del proyecto, no de la API.

Los ejemplos de esta spec usan el pipeline `implement` → `review_functional` → `review_code` → `merge`: implementar; comprobar que el PR cumple los criterios de aceptación; revisar la calidad del código; actualizar la rama, esperar al CI, mergear y escribir el resumen. Un proyecto pequeño puede quedarse en `implement` → `review`, y otro añadir `qa_manual` o `security` donde le convenga.

## 3. Convenciones

- Base: `/api`. JSON en peticiones y respuestas, salvo el panel (9).
- Campos en `camelCase`. Fechas ISO 8601 en UTC con sufijo `Z`. Ids de claims y runs en ULID.
- Auth: `Authorization: Bearer <token>`. Sin token o incorrecto: `401`. El panel usa el mismo token; cómo lo pide al navegador se decide al implementarlo.
- Errores: `{ "error": "texto legible" }`.

| Código | Cuándo |
|---|---|
| `200` | Lectura o modificación correcta. |
| `201` | Recurso creado. |
| `401` | Token ausente o incorrecto. |
| `404` | Proyecto o tarea inexistente. |
| `409` | Petición válida pero el estado actual no la permite. |
| `422` | Body inválido contra el schema o las reglas de validación. |

## 4. Recursos

### 4.1 Proyecto

```json
{
  "id": "myapp",
  "description": "Task Priority System - Add priority levels to tasks",
  "pipeline": ["implement", "review_functional", "review_code", "merge"],
  "counts": { "total": 5, "done": 1, "claimed": 2, "sick": 0, "needsHuman": 0, "blocked": 0 }
}
```

- `id`: slug, `^[a-z0-9][a-z0-9-]{0,62}$`. Lo elige quien crea el proyecto.
- `description`: contexto del PRD que recibe cada agente.
- `pipeline`: al menos una etapa. Nombres únicos con el formato `^[a-z][a-z0-9_]{0,30}$`; `done` y `doctor` están reservados. El worker necesita un prompt por cada nombre (7).
- `counts`: calculado. `needsHuman` cuenta las tareas paradas a la espera de una persona (5.3). `blocked` cuenta esas más todas las que dependen de ellas, directa o transitivamente: ninguna avanzará sin intervención humana.

### 4.2 Tarea

Es exactamente el documento de `task.schema.json`. El schema no conoce el pipeline: `state.stage` y `runs[].stage` son nombres libres y el servidor valida que existan en el proyecto (más `done` y `doctor`). Las reglas que dependen de la posición de la etapa (5.2) también las aplica el servidor, no el schema.

```json
{
  "id": "US-002",
  "spec": {
    "title": "Display priority indicator on task cards",
    "description": "As a user, I want to see task priority at a glance.",
    "acceptanceCriteria": ["Each task card shows a colored priority badge", "Typecheck passes"],
    "priority": 2,
    "model": "med",
    "dependsOn": ["US-001"]
  },
  "state": {
    "stage": "review_code",
    "pr": "https://github.com/mbernet/myapp/pull/12",
    "sick": false,
    "claim": { "id": "01JC9A...", "worker": "vps-1", "expiresAt": "2026-11-04T12:30:00Z" },
    "summary": null
  },
  "runs": [
    {
      "id": "01JC9F...",
      "stage": "implement",
      "worker": "vps-1",
      "outcome": "pass",
      "endedAt": "2026-11-04T10:12:00Z",
      "body": "- Added PriorityBadge component...\n- Tests: 12 passed",
      "assumptions": ["Not clear whether the badge shows on archived tasks. Assumed it does."]
    },
    {
      "id": "01JC9K...",
      "stage": "review_functional",
      "worker": "vps-1",
      "outcome": "pass",
      "endedAt": "2026-11-04T10:40:00Z",
      "body": "All criteria verified in the browser. Assumption about archived tasks is fine.",
      "assumptions": []
    }
  ]
}
```

- `spec` solo lo escribe una persona. `state` y `runs` solo los escribe el servidor.
- `state.claim` se muestra tal cual, también si ya ha caducado. Si está activo o no lo decide `expiresAt` frente a la hora actual.
- Todo lo demás se deriva de `runs` (ver 5.4).

### 4.3 Claim

```json
{ "id": "01JC9A...", "worker": "vps-1", "expiresAt": "2026-11-04T12:30:00Z" }
```

- Cubre una etapa. Registrar el run lo borra; para la etapa siguiente se vuelve a pedir trabajo.
- TTL fijo de 2 horas desde su creación. Tiene que cubrir la etapa más larga, incluida la espera al CI si la última etapa mergea, más algún reintento del worker (7).
- Una tarea tiene como mucho un claim. Un claim nuevo sustituye al caducado.
- No se libera a mano. Mientras dura, es del worker: si la ejecución falla sin resultado (rate limit, el CLI muere), el worker espera y reintenta la misma etapa con el mismo claim. Si el worker desaparece, el claim caduca y otro lo sustituye.

## 5. Reglas

### 5.1 Qué trabajo se reparte

Una tarea es elegible para un worker si:

1. `state.stage` no es `done`.
2. No tiene claim activo (`claim` es `null` o `expiresAt` ya ha pasado).
3. Todas las tareas de `dependsOn` están en `done`.
4. No está parada a la espera de una persona (5.3).

La etapa de run que recibe el worker es `doctor` si la tarea está `sick`; si no, `state.stage`.

Entre las elegibles, el servidor elige por grupos, en este orden:

1. **Propias:** tareas cuyo último run hizo el worker que pide. Ya tiene la rama en local.
2. **Nuevas:** tareas sin runs.
3. **Ajenas:** tareas cuyo último run hizo otro worker. Solo se reparten cuando no quedan propias ni nuevas.

Dentro de cada grupo: posición más avanzada en el pipeline primero (con el pipeline de ejemplo, `merge` > `review_code` > `review_functional` > `implement`), luego menor `priority` y luego menor `id`.

Elegir y reservar es una operación atómica: dos peticiones simultáneas nunca reciben la misma tarea.

### 5.2 Transiciones

Las transiciones dependen de la posición de la etapa en el pipeline del proyecto, no de su nombre. Siendo `P` el pipeline, `P[0]` la primera etapa y `P[n]` la última, cada run registrado aplica exactamente una fila y, en todos los casos, deja `claim` a `null`.

| Etapa del run | `outcome` | Efecto en `state` |
|---|---|---|
| `P[i]`, no la última | `pass` | `stage` → `P[i+1]`. En `P[0]`, además fija `pr`. |
| `P[n]` | `pass` | `stage` → `done`. Fija `summary`. Si el pipeline tiene una sola etapa, fija también `pr`. |
| `P[i]`, con `i > 0` | `reject` | `stage` → `P[0]`. Tercer rechazo: además `sick` → `true`. |
| `P[0]` | `reject` | No permitido (`422`). La primera etapa no tiene a quién devolver el trabajo. |
| Cualquier `P[i]` | `sick` | `sick` → `true`. |
| `doctor` | `pass` | `sick` → `false`. La tarea sigue en su `stage`. |
| `doctor` | `reject` | `sick` → `false`. `stage` → `P[0]`. Se descarta el intento y se empieza de nuevo sobre la misma rama. |
| `doctor` | `sick` | Sigue `sick`. Deja de repartirse hasta que intervenga una persona (5.3). |

Además, cualquier fila que ponga `sick` a `true` en una tarea que ya tiene dos runs `doctor` la deja parada a la espera de una persona (5.3): el doctor no vuelve a intervenir.

Notas:

- **Rechazos.** Un `reject` devuelve la tarea a `P[0]` conservando el PR: el implementador trabaja sobre la misma rama con el feedback en `runs`. Al tercer `reject` acumulado (contando todos los runs de la tarea) el servidor marca la tarea `sick` para cortar el bucle. El límite es una constante del servidor, `3`.
- **Sick.** Marca la tarea sin cambiar `stage`. El doctor ve en `runs` qué agente la marcó y por qué.
- **Done.** Solo se llega con un `pass` en la última etapa. Una tarea nunca está `done` sin `pr`, sin `summary` o `sick`. Que el PR esté mergeado al cerrar es responsabilidad del prompt de la última etapa, no del servidor.
- **Cambiar el pipeline.** `PUT /projects/{project}` puede añadir, quitar o reordenar etapas. El siguiente run de cada tarea usa el pipeline que haya en ese momento. Solo se rechaza (`409`) quitar o renombrar una etapa en la que hay alguna tarea no `done`.

### 5.3 Cuándo interviene una persona

La API nunca espera a nadie: cuando un agente no puede decidir, asume, lo declara en `assumptions` y sigue. Una tarea solo se para, y pasa a `needsHuman`, cuando está `sick` y se da una de estas dos:

- Su último run es un `doctor` con outcome `sick`: el doctor ha dicho que no puede.
- Ya tiene dos runs `doctor`: el doctor ya ha intervenido dos veces y la tarea ha vuelto a enfermar. Sin este tope, un doctor que cree curar sin curar y un agente que vuelve a marcar `sick` se alternan sin fin y sin que nadie lo vea.

Las tareas que dependen de una parada, directa o transitivamente, tampoco avanzarán. Entre todas forman `blocked` (4.1), y con ese número los workers saben cuándo no queda nada que hacer (6.5).

Una persona recupera una tarea parada sin endpoints especiales: la pide a dedo con `POST /work` indicando `task` (6.5) y registra un run `doctor` con `pass` (continúa donde estaba) o `reject` (vuelve a la primera etapa). Ese run cuenta como intervención del doctor, así que si la tarea vuelve a enfermar irá directa a la persona otra vez. Si hace falta cambiar la spec, la edita antes (5.5).

### 5.4 Qué se deriva de `runs`

El servidor no guarda contadores. Todo esto se calcula al vuelo:

| Dato | Cómo |
|---|---|
| Rechazos | Runs con `outcome: reject`. |
| Afinidad de un worker | `worker` del último run. |
| Asunciones | `assumptions` de los runs de la primera etapa. Están revisadas cuando les sigue un run de otra etapa con `pass`: el revisor las ve en el JSON y las da por buenas o rechaza. |
| Fecha de cierre | `endedAt` del run que dejó la tarea en `done`. |
| Necesita persona | `sick` y (el último run es `doctor` con `sick`, o hay dos runs `doctor`). |
| Bloqueadas | Las que necesitan persona más las que dependen de ellas, transitivamente. |
| Progreso del proyecto | `summary` de las tareas `done`, en orden de cierre. |

### 5.5 Validación y edición de `spec`

Al crear o editar una `spec`:

- Debe cumplir `#/$defs/spec` del schema.
- Cada id de `dependsOn` existe en el proyecto, no es la propia tarea y no forma ciclos.

Se puede editar la `spec` de cualquier tarea que no esté `done`; en `done` responde `409`. Editar una tarea en curso es seguro: la siguiente revisión comprueba el PR contra la spec nueva y lo devuelve a la primera etapa si ya no encaja.

## 6. Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| `PUT` | `/projects/{project}` | Crear o actualizar un proyecto. |
| `GET` | `/projects/{project}` | Ver proyecto con contadores. |
| `PUT` | `/projects/{project}/tasks/{task}` | Crear o editar la `spec` de una tarea. |
| `GET` | `/projects/{project}/tasks` | Listar tareas completas. |
| `GET` | `/projects/{project}/tasks/{task}` | Ver una tarea. |
| `POST` | `/projects/{project}/work` | Pedir trabajo (claim). |
| `POST` | `/projects/{project}/tasks/{task}/runs` | Registrar un run. |

### 6.1 `PUT /projects/{project}`

```json
{
  "description": "Task Priority System - Add priority levels to tasks",
  "pipeline": ["implement", "review_functional", "review_code", "merge"]
}
```

- Idempotente. `201` si lo crea, `200` si ya existía. Body: el proyecto (4.1).
- `409` si el pipeline nuevo quita o renombra una etapa en la que hay alguna tarea no `done` (5.2). El `error` dice qué etapa y qué tareas.
- `422` si falta `description` o `pipeline`, el id no es un slug válido, o el pipeline está vacío, repite nombres, usa un nombre reservado o uno con formato incorrecto (4.1).

### 6.2 `GET /projects/{project}`

`200` con el proyecto (4.1).

### 6.3 `PUT /projects/{project}/tasks/{task}`

El body es la `spec`:

```json
{
  "title": "Display priority indicator on task cards",
  "description": "As a user, I want to see task priority at a glance.",
  "acceptanceCriteria": ["Each task card shows a colored priority badge", "Typecheck passes"],
  "priority": 2,
  "model": "med",
  "dependsOn": ["US-001"]
}
```

- Idempotente. `201` si la crea, `200` si edita. Body: la tarea completa (4.2).
- Al crear, `state` es `{ "stage": <primera etapa del pipeline>, "pr": null, "sick": false, "claim": null, "summary": null }` y `runs` está vacío.
- `409` si la tarea está `done`.
- `422` si la spec no valida (5.5).

Importar un `prd.json` es un `PUT` por tarea. Añadir tareas a un proyecto terminado hace que `POST /work` vuelva a repartir trabajo; los workers que ya pararon hay que relanzarlos.

### 6.4 `GET /projects/{project}/tasks` y `GET /projects/{project}/tasks/{task}`

- Lista: `200` con `{ "tasks": [tarea, ...] }`, ordenadas por `priority` e `id`. Sin filtros ni paginación: las tareas son pocas y pequeñas, se filtra con `jq`.
- Detalle: `200` con la tarea.

### 6.5 `POST /projects/{project}/work`

```json
{ "worker": "vps-1" }
```

El servidor elige según 5.1, crea el claim y responde `200`:

```json
{
  "stage": "review_code",
  "claim": { "id": "01JC9A...", "worker": "vps-1", "expiresAt": "2026-11-04T12:30:00Z" },
  "task": { "...": "tarea completa (4.2)" },
  "project": { "id": "myapp", "description": "...", "pipeline": ["implement", "review_functional", "review_code", "merge"] },
  "progress": [
    { "id": "US-001", "title": "Add priority field to database", "summary": "...", "endedAt": "2026-11-04T09:50:00Z" }
  ]
}
```

- `stage` es la etapa de run que debe ejecutar el worker. Es `doctor` cuando la tarea está `sick`; si no, coincide con `task.state.stage`. El worker elige prompt y modelo a partir de `stage` y `task.spec.model`.
- `progress` son las tareas `done` en orden de cierre. Es el `progress.txt` de siempre, y con él el agente tiene todo el contexto en una sola llamada.

Si no hay nada elegible, `200` con:

```json
{
  "stage": null,
  "finished": false,
  "counts": { "total": 5, "done": 2, "claimed": 1, "sick": 1, "needsHuman": 1, "blocked": 2 }
}
```

`finished` es `true` cuando `done + blocked == total`: todo lo que no está hecho está parado o depende de algo parado, y no llegará más trabajo sin una persona. El worker termina. Si es `false`, espera y vuelve a pedir. `counts` se incluye para que una persona vea por qué.

**Pedir una tarea concreta.** Con `{ "worker": "marc", "task": "US-003" }` el servidor reserva esa tarea saltándose la elegibilidad de 5.1, salvo que esté `done` o tenga claim activo (`409`). Sirve para que una persona recupere una tarea parada (5.3) y para el `--story` de `ralph.sh`.

- `422` si falta `worker` o no es un id válido.

### 6.6 `POST /projects/{project}/tasks/{task}/runs`

```json
{
  "claimId": "01JC9A...",
  "outcome": "pass",
  "body": "- Added PriorityBadge component...\n- Tests: 12 passed",
  "assumptions": ["Not clear whether the badge shows on archived tasks. Assumed it does."],
  "pr": "https://github.com/mbernet/myapp/pull/12",
  "summary": null
}
```

- Obligatorios: `claimId`, `outcome`, `body`.
- El servidor completa el run con `id`, `endedAt`, y `stage` y `worker` sacados del claim. El cliente no puede declarar una etapa distinta de la que se le asignó.
- `assumptions`: solo en la primera etapa del pipeline. En otras etapas, vacío u omitido.
- `pr`: solo en la primera etapa. Obligatorio en un `pass` si `state.pr` es `null`; si ya hay PR, opcional y lo sustituye.
- `summary`: solo en la última etapa con `pass`, y obligatorio ahí. Es el resumen que verán los siguientes agentes en `progress`: qué se hizo y qué conviene saber del código.
- `outcome`: `reject` no se admite en la primera etapa (5.2).
- `201` con la tarea completa ya transicionada (5.2).
- `409` si `claimId` no es el claim actual de la tarea. Pasa cuando el claim caducó y otro worker ya la ha retomado: el worker antiguo descarta su resultado. Un claim caducado que nadie ha sustituido sigue siendo válido.
- `422` si el `outcome` no es válido para la etapa, o faltan o sobran `pr`, `summary` o `assumptions`.

## 7. Ciclo del worker

```
loop:
  r = POST /work { worker }
  if r.stage == null:
     if r.finished: exit
     sleep; continue
  loop:
     run agent(prompt[r.stage], model[r.stage, r.task.spec.model], context = r)
     if the agent produced a result:
        POST /tasks/{id}/runs { claimId, outcome, body, assumptions?, pr?, summary? }
        break
     wait = rate limit reset time if known, else backoff
     if now + wait + MARGIN >= r.claim.expiresAt: break   # the claim is about to stop being ours: drop the task
     sleep(wait)
  if no result was registered:
     sleep(rate limit reset time if known, else long backoff)   # don't ask for more work without quota
```

Cuando la ejecución no produce resultado, el worker no toca la API: el claim sigue siendo suyo, espera lo que marque el rate limit y reintenta la misma etapa. Así un worker limitado no devuelve la tarea al reparto para volver a recibirla por afinidad un segundo después.

Dos reglas locales, sin llamadas a la API, evitan que los reintentos hagan daño:

- **El claim manda.** El worker solo reintenta si, al despertar, le queda margen hasta `expiresAt` para terminar la etapa (`MARGIN`, una constante del worker: media hora). Pasado ese punto la tarea ya no es suya: otro worker puede tener un claim nuevo y estar en la misma rama, y un agente tardío haría push encima. El `409` de 6.6 es la última red, no la primera.
- **Sin cuota no se pide trabajo.** Si suelta una tarea sin resultado, el worker espera hasta el reset del rate limit (o un backoff largo si el fallo no es de cuota) antes de volver a `POST /work`. Si no, iría encadenando tareas, bloqueando cada una dos horas sin tocarla, y los workers que sí tienen cuota no podrían cogerlas.

La tarea soltada vuelve al reparto cuando su claim caduca. Un run registrado después de caducar sigue valiendo mientras nadie haya sustituido el claim (6.6). Los fallos de infraestructura no dejan rastro en `runs`; su sitio es el ledger de uso del propio worker.

El agente recibe el JSON de `POST /work` entero. De él saca la spec, el PR, el feedback de revisiones anteriores, las asunciones declaradas y el progreso del proyecto. No necesita leer el PR ni ningún fichero de estado.

Cómo devuelve el agente su resultado al worker queda fuera de la API. En `ralph.sh` lo escribe en un fichero JSON que el script valida y envía; el diseño está en [`worker-proposal.md`](worker-proposal.md).

El worker tiene un prompt por cada nombre de etapa del pipeline del proyecto, más uno para `doctor`. Si recibe una etapa para la que no tiene prompt, no registra nada y avisa: es un error de configuración del worker, no de la tarea. `project.pipeline` viene en la respuesta de `POST /work` para que pueda comprobarlo antes de empezar.

Ejemplo de vida de una tarea con un rechazo, con el pipeline de ejemplo:

| # | `stage` del run | worker | outcome | `state` después |
|---|---|---|---|---|
| 1 | `implement` | `vps-1` | `pass` | `review_functional`, pr #12 |
| 2 | `review_functional` | `vps-1` | `pass` | `review_code` |
| 3 | `review_code` | `mac-marc` | `reject` | `implement` |
| 4 | `implement` | `mac-marc` | `pass` | `review_functional` |
| 5 | `review_functional` | `mac-marc` | `pass` | `review_code` |
| 6 | `review_code` | `vps-1` | `pass` | `merge` |
| 7 | `merge` | `vps-1` | `pass` | `done`, summary fijado |

## 8. Decisiones tomadas y por confirmar

- **El pipeline lo define cada proyecto y el servidor solo mira posiciones.** Primera etapa: produce el PR, declara asunciones, no puede rechazar. Intermedias y última: pueden rechazar hacia la primera. Última: cierra con `summary`. Con eso el servidor no necesita saber qué es "revisar" ni "mergear", y un proyecto puede tener dos etapas y otro seis. El precio es que el schema de tarea ya no valida nombres ni reglas por etapa: lo hace el servidor contra el pipeline del proyecto.
- **Claim por etapa, no por pipeline.** Cada etapa pide trabajo de nuevo. La afinidad de 5.1 hace que en la práctica el mismo worker encadene las etapas, pero sin obligación: si muere, otro continúa sin esperar a que caduque nada más que un claim.
- **La afinidad ordena, no reserva.** Un worker sigue con sus tareas y solo coge las de otro cuando no hay nada nuevo. Si el worker de una tarea desaparece, la tarea espera hasta que se acaben las historias nuevas. Con un backlog grande, eso puede tardar.
- **TTL fijo de 2 h, límite de 3 rechazos y 2 intervenciones del doctor.** Constantes del servidor. Si hace falta, pasan a ser campos del proyecto; de momento no.
- **Sin endpoint de progreso.** Va dentro de `POST /work`. Una persona lo lee con `GET /tasks` y `jq`.
- **Sin renovación ni liberación de claim.** Un claim solo muere por run o por TTL. Liberarlo al vuelo provocaba un bucle: el worker con rate limit soltaba la tarea y la recibía otra vez por afinidad, sin pausa y sin rastro. Ahora el worker reintenta con su propio claim, y solo mientras `expiresAt` le deja margen. Si una etapa supera el TTL, otro worker puede retomarla y el run tardío recibe `409`. Es raro y el coste es repetir una etapa.
- **La parada es transitiva.** Una tarea parada arrastra a las que dependen de ella. `finished` en `POST /work` lo tiene en cuenta; si no, los workers reintentarían para siempre esperando a una dependencia que nunca cerrará.
- **Editar la spec de una tarea en curso está permitido.** El pipeline se autocorrige vía rechazo. Es más simple que bloquear.

## 9. Panel

Una vista de solo lectura, por proyecto, para que una persona vea de un vistazo cómo va el desarrollo y qué le toca a ella. Se actualiza sola, sin recargar a mano. Dónde se sirve y cómo se implementa se decide al hacerlo; esta sección solo fija qué muestra.

Cuatro columnas por estado, en este orden:

| Columna | Qué tareas | Criterio |
|---|---|---|
| Pendientes | Aún no han empezado. | `runs` está vacío. |
| En curso | Están en el pipeline. | Cualquier otra tarea no `done` que no esté parada. |
| Paradas | Necesitan a una persona. | `needsHuman`, o `blocked` por depender de una. |
| Hechas | PR mergeado. | `stage` es `done`. |

Cada tarjeta muestra el `id`, el título, la `priority` y, según el caso:

- La etapa actual, para las tareas en curso.
- El worker que la tiene reservada y hasta cuándo, si hay claim activo.
- Un enlace al PR, si lo hay.
- Marcas de atención: `sick`, número de rechazos, número de asunciones declaradas, y por qué está parada (diagnóstico del doctor, o id de la tarea que la bloquea).
- La fecha de cierre, para las hechas.

Las columnas se ordenan igual que el reparto de trabajo (5.1): etapa más avanzada primero, luego `priority`, luego `id`. Las hechas van por fecha de cierre, la más reciente arriba.

Encima de las columnas, el nombre y la descripción del proyecto y los `counts` de 4.1. Cada tarjeta enlaza a `GET /projects/{project}/tasks/{task}` para ver el JSON completo con sus runs; el panel no reproduce el historial, solo señala dónde mirar.

El panel no permite actuar: editar specs y rescatar tareas paradas se hace con la API (5.3, 6.3). Si con el uso hace falta algo más, se añade entonces.
