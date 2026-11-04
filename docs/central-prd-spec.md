# Spec: PRD centralizado para varios workers de Ralph

Estado: definida · 2026-11-04

## 1. Objetivo

Sustituir el `prd.json` local por una API que comparten varios workers de Ralph sobre el mismo proyecto. Cada historia pasa por un pipeline de etapas (implementar, revisar spec, revisar código) y avanza mediante PR igual que en un equipo humano. Un worker coge una historia, la lleva por todas las etapas y, cuando la última revisión aprueba, mergea el PR. Cada etapa es una ejecución nueva del agente, con contexto limpio y el prompt de esa etapa.

Las historias nunca se paran a esperar a una persona. Cuando algo requiere una decisión humana, el agente hace una asunción, la declara y sigue. Las asunciones quedan pendientes de revisión, y una persona las revisa cuando puede.

La API solo guarda estado y aplica las reglas de transición. No sabe nada de git, de prompts ni de modelos.

### Fuera de alcance

- Usuarios, roles y permisos (hay un único token compartido).
- Notificaciones y webhooks. Las historias con asunciones sin revisar se consultan con `GET /stories?needsReview=true`.
- Borrar historias.
- Editar historias que ya han empezado (ver 5.5).
- Etapas en paralelo: el pipeline es estrictamente secuencial.
- Workers especializados: todos los workers pueden hacer todas las etapas y tienen permisos para mergear en GitHub.

## 2. Conceptos

| Concepto | Qué es |
|---|---|
| Proyecto | Un PRD: su pipeline y sus historias. |
| Pipeline | Lista ordenada de etapas por las que pasa cada historia. La primera es la de implementación. |
| Historia | Una user story del PRD. |
| Estado (`status`) | En qué punto de su ciclo de vida está una historia: `pending`, `in_progress` o `completed`. |
| Etapa (`stage`) | En qué etapa del pipeline está una historia. Indica qué prompt y qué modelo usa la siguiente ejecución. |
| Worker | Un proceso `ralph.sh` que coge una historia y la lleva por todas las etapas. Se identifica con un nombre libre, por ejemplo `mac-marc-4123`. |
| Claim | Reserva de una historia por parte de un worker mientras la lleva por el pipeline. Se renueva con cada run y caduca si el worker deja de registrarlos. |
| Run | Resultado de una ejecución de un worker sobre una historia. Los runs son el historial de la historia y nunca se modifican. |
| Asunción | Decisión que el agente ha tomado sin poder confirmarla y que una persona debería revisar. No detiene la historia. |

## 3. Convenciones de la API

- Base: `/api`. JSON en peticiones y respuestas, salvo `/progress` (`text/markdown`).
- Campos en `camelCase`.
- Fechas en ISO 8601 UTC: `2026-11-04T10:12:00Z`.
- Auth: cabecera `Authorization: Bearer <token>`, comparado con un token de configuración. Sin token o con uno incorrecto: `401`.
- Errores:

```json
{ "message": "Texto legible", "errors": { "campo": ["motivo"] } }
```

`errors` solo aparece en los `422`.

| Código | Cuándo |
|---|---|
| `200` | Lectura o modificación correcta. |
| `201` | Recurso creado. Incluye cabecera `Location`. |
| `204` | Borrado correcto. |
| `401` | Token ausente o incorrecto. |
| `404` | El proyecto, la historia, el claim o la asunción no existen. |
| `409` | La petición es válida pero el estado actual no la permite. |
| `422` | Body inválido. |

## 4. Modelo

### 4.1 Proyecto

```json
{
  "id": "01JC8Z...",
  "name": "MyApp",
  "description": "Task Priority System",
  "pipeline": ["implement", "review-spec", "review-code"],
  "maxRejections": 3,
  "claimTtlMinutes": 120,
  "counts": {
    "total": 5,
    "claimed": 2,
    "needsReview": 1,
    "byStatus": { "pending": 1, "in_progress": 3, "completed": 1 },
    "byStage": { "implement": 2, "review-spec": 1, "review-code": 1 }
  },
  "createdAt": "2026-11-04T09:00:00Z"
}
```

- `id`: lo genera el servidor.
- `pipeline`: al menos una etapa. Nombres únicos con el formato `^[a-z0-9-]+$`. El merge no es una etapa: lo hace el worker (7.4).
- `maxRejections`: cuántas veces puede volver una historia a la primera etapa por un rechazo. Entero ≥ 0. Por defecto, `3`. Ver 5.2.
- `claimTtlMinutes`: entero ≥ 1. Por defecto, `120`. Tiene que cubrir la etapa más larga, más la espera al CI en la última etapa (7.4).
- `counts`: calculado y solo de lectura. `byStage` cuenta solo las historias `pending` e `in_progress`. `needsReview` cuenta historias con alguna asunción sin revisar.

### 4.2 Historia

```json
{
  "id": "US-002",
  "title": "Display priority indicator on task cards",
  "description": "As a user, I want to see task priority at a glance.",
  "acceptanceCriteria": ["Each task card shows colored priority badge", "Typecheck passes"],
  "priority": 2,
  "model": "med",
  "notes": "",
  "dependsOn": ["US-001"],
  "status": "in_progress",
  "stage": "review-code",
  "pr": "https://github.com/mbernet/myapp/pull/12",
  "rejections": 1,
  "needsReview": true,
  "claim": { "id": "01JC9A...", "worker": "vps-1-881", "expiresAt": "2026-11-04T12:30:00Z" },
  "completedAt": null,
  "assumptions": [],
  "runs": []
}
```

- `id`: la clave del PRD (`US-002`). Única dentro del proyecto. Es la que se usa en las URL.
- `model`: opcional. Si existe, prevalece sobre el modelo del prompt de la etapa (ver 7.2).
- `status`: estado de la historia (ver 4.3).
- `stage`: etapa actual del pipeline. Al crear, la primera. En `completed`, `null`.
- `pr`: `null` hasta que un run lo informa.
- `rejections`: número de veces que la historia ha vuelto a la primera etapa por un `changes_requested`.
- `needsReview`: calculado. `true` si alguna asunción no está revisada.
- `claim`: el claim activo o `null`. Un claim caducado se muestra como `null`.
- `completedAt`: la fecha del run que dejó la historia en `completed`, o `null`.
- `assumptions` y `runs`: ordenados por fecha. Solo se incluyen en el detalle de la historia y en la respuesta del claim, no en el listado.

### 4.3 Estados

| `status` | Significado | `stage` |
|---|---|---|
| `pending` | No ha empezado: no tiene ningún run. | La primera del pipeline. |
| `in_progress` | Ha empezado y aún no ha terminado. | La actual. |
| `completed` | Ha pasado todas las etapas: el PR está mergeado. | `null`. |

Cada campo responde a una pregunta distinta. `status` dice en qué punto de su ciclo de vida está la historia; `stage`, qué etapa le toca ejecutar; `claim`, qué worker la lleva; `needsReview`, si una persona tiene algo que revisar. Una historia puede estar `completed` y tener `needsReview: true`.

### 4.4 Run

```json
{
  "id": "01JC9F...",
  "stage": "review-code",
  "worker": "vps-1-881",
  "result": "changes_requested",
  "body": "Falta el test del filtro vacío.",
  "createdAt": "2026-11-04T11:02:00Z"
}
```

Valores de `result`:

| `result` | Etapa | Efecto |
|---|---|---|
| `done` | Primera etapa | Avanza. |
| `approved` | Cualquier etapa menos la primera | Avanza. |
| `changes_requested` | Cualquier etapa menos la primera | Vuelve a la primera etapa, salvo que se haya alcanzado el límite (5.2). |
| `merge_failed` | Solo la última etapa | Vuelve a la primera etapa sin contar como rechazo. Lo registra el worker, no el agente (7.4). |

`body` es markdown libre. En la primera etapa es el informe de progreso, con el formato actual de `progress.txt`. En las revisiones es el feedback. En `merge_failed`, el motivo del fallo: ficheros en conflicto o checks del CI que han fallado.

### 4.5 Asunción

```json
{
  "id": "01JCA2...",
  "runId": "01JC9F...",
  "stage": "implement",
  "text": "No está claro si el filtro debe persistir entre sesiones. He asumido que no.",
  "reviewed": false,
  "reviewedAt": null,
  "createdAt": "2026-11-04T10:12:00Z"
}
```

- La crea el servidor a partir de un run (6.9) o al forzar un avance por límite de rechazos (5.2).
- `text` es lo único que escribe el agente. Debe decir qué no estaba claro y qué ha decidido.
- `reviewed` solo lo cambia una persona (6.10).

### 4.6 Claim

```json
{
  "id": "01JC9A...",
  "worker": "vps-1-881",
  "expiresAt": "2026-11-04T12:30:00Z",
  "story": { "...": "historia completa, con runs y asunciones" }
}
```

- El claim es de la historia, no de una etapa: dura todo el pipeline.
- Una historia tiene como mucho un claim. Un claim nuevo sustituye al anterior caducado.
- Un claim está activo mientras `expiresAt > now`. `expiresAt` es la hora del último run (o de la creación) más `claimTtlMinutes`. Por eso el TTL solo tiene que cubrir la etapa más larga.
- Si un worker muere, el claim caduca y otro worker retoma la historia en la etapa en la que estaba.

## 5. Reglas

### 5.1 Elegibilidad para un claim

Una historia se puede asignar a un worker si se cumplen las tres condiciones:

1. `status` es `pending` o `in_progress`.
2. No tiene claim activo.
3. Todas las historias de `dependsOn` están `completed`, es decir, con el PR mergeado. Que tengan asunciones sin revisar no importa.

Entre las elegibles, el orden es:

1. Primero las `in_progress`: son historias abandonadas, cuyo claim caducó. Así se termina lo empezado antes de abrir trabajo nuevo.
2. Después las `pending`.
3. Dentro de cada grupo, la de menor `priority` y, si hay empate, la de menor `id`.

La elección y la creación del claim son atómicas: dos peticiones simultáneas nunca obtienen la misma historia.

### 5.2 Transiciones

Siendo `P` el pipeline y `P[0]` la primera etapa:

| Situación | Run | Resultado |
|---|---|---|
| En `P[i]`, sin ser la última | `done` / `approved` | `in_progress`, en `P[i+1]`. |
| En la última etapa | `done` / `approved` | `completed`, `stage` a `null` y se fija `completedAt`. El worker solo lo registra después de mergear (7.4). |
| En `P[i]` con `i > 0`, y `rejections < maxRejections` | `changes_requested` | `rejections + 1`. `in_progress`, en `P[0]`. |
| En `P[i]` con `i > 0`, y `rejections == maxRejections` | `changes_requested` | Avance forzado: se trata como `approved` y se crea una asunción. |
| En la última etapa | `merge_failed` | `in_progress`, en `P[0]`. `rejections` no cambia. |

Una historia `pending` pasa a `in_progress` con su primer run. Si el pipeline tiene una sola etapa, ese run es `done` y la historia pasa directamente a `completed`.

**Avance forzado.** Cuando se alcanza el límite, la historia no se para. El run se guarda tal cual, con `result: "changes_requested"`, para que el historial sea fiel. La historia avanza como si se hubiera aprobado, y el servidor crea una asunción con el texto `"Avanza sin aprobar en {stage} por límite de rechazos ({maxRejections}): {body}"`. Así la persona que revise ve exactamente qué no convencía al revisor. Con `maxRejections: 3`, la historia puede volver a implementarse tres veces; el cuarto rechazo ya no la devuelve.

Si el avance forzado ocurre en la última etapa, el servidor responde con la historia todavía `in_progress` en esa etapa y con `forcedApproval: true` en la respuesta del run. El worker mergea (7.4) y registra después el run `approved`. Así una historia nunca pasa a `completed` sin que su PR esté mergeado.

Al registrar un run:

- Si la historia sigue `pending` o `in_progress`, el claim se renueva (`expiresAt` = ahora + `claimTtlMinutes`) y el mismo worker continúa con la siguiente etapa.
- Si pasa a `completed`, el claim se borra.

### 5.3 Asunciones

- Cualquier run, de cualquier etapa, puede declarar asunciones. No cambian la transición.
- Las asunciones no bloquean nada: ni el avance de la historia, ni el merge, ni las historias que dependen de ella.
- Una persona revisa las historias con `needsReview: true` y marca cada asunción como revisada. Si la asunción era incorrecta y la historia ya está `completed`, la corrección se hace creando una historia nueva.
- Los agentes de las etapas siguientes reciben las asunciones de la historia en `{{assumptions}}` (7.2). Un revisor puede así darlas por buenas o pedir cambios.

### 5.4 Validación de historias

Se aplica al crear el proyecto, al añadir una historia y al editar `dependsOn`:

- Cada id de `dependsOn` existe en el mismo proyecto.
- Ninguna historia depende de sí misma.
- No hay ciclos.
- Los `id` de las historias son únicos.

Si alguna falla, la respuesta es `422`.

### 5.5 Edición de historias

Una historia solo se puede editar si está `pending` y no tiene un claim activo. Así nunca queda un PR ni feedback que no correspondan a la spec.

Si no se cumple, la respuesta es `409`. Las historias `in_progress` o `completed` se cambian creando una historia nueva.

Campos editables: `title`, `description`, `acceptanceCriteria`, `priority`, `model`, `notes` y `dependsOn`. Los demás (`id`, `status`, `stage`, `pr`, `rejections`, `runs`, `assumptions`) solo los cambia el servidor.

## 6. Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/projects` | Crear proyecto. |
| `GET` | `/projects/{projectId}` | Ver proyecto con contadores. |
| `GET` | `/projects/{projectId}/stories` | Listar historias. |
| `GET` | `/projects/{projectId}/stories/{storyId}` | Ver historia con runs y asunciones. |
| `POST` | `/projects/{projectId}/stories` | Añadir una historia. |
| `PATCH` | `/projects/{projectId}/stories/{storyId}` | Editar una historia pendiente. |
| `POST` | `/projects/{projectId}/claims` | Pedir una historia. |
| `DELETE` | `/projects/{projectId}/claims/{claimId}` | Liberar un claim. |
| `POST` | `/projects/{projectId}/stories/{storyId}/runs` | Registrar un run. |
| `PATCH` | `/projects/{projectId}/stories/{storyId}/assumptions/{assumptionId}` | Marcar una asunción como revisada. |
| `GET` | `/projects/{projectId}/progress` | Progress en markdown. |

### 6.1 `POST /projects`

El body tiene la forma del `prd.json` actual, más el pipeline y la configuración:

```json
{
  "name": "MyApp",
  "description": "Task Priority System",
  "pipeline": ["implement", "review-spec", "review-code"],
  "maxRejections": 3,
  "claimTtlMinutes": 120,
  "userStories": [
    {
      "id": "US-001",
      "title": "Add priority field to database",
      "description": "...",
      "acceptanceCriteria": ["..."],
      "priority": 1,
      "model": "low",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
```

- Obligatorios: `name`, `pipeline` y `userStories` (al menos una). En cada historia: `id`, `title` y `priority`.
- Se ignoran los campos de estado del `prd.json` antiguo (`passes`, `branchName`).
- `201`, con `Location: /api/projects/{projectId}`. El body es el proyecto (4.1).
- `422` si la validación falla (5.4 o formato).

### 6.2 `GET /projects/{projectId}`

`200` con el proyecto (4.1). `404` si no existe.

### 6.3 `GET /projects/{projectId}/stories`

- Filtros opcionales, combinables: `?status=in_progress`, `?stage=review-code` y `?needsReview=true`.
- `200` con `{ "data": [historia sin runs ni asunciones, ...] }`, ordenado por `priority` e `id`.

### 6.4 `GET /projects/{projectId}/stories/{storyId}`

`200` con la historia completa (4.2), con runs y asunciones. `404` si no existe.

### 6.5 `POST /projects/{projectId}/stories`

El body es una historia con la misma forma que en `userStories` (6.1).

- La historia se crea `pending`, en la primera etapa del pipeline.
- Puede depender de cualquier historia del proyecto, también de las que ya están `completed`.
- `201`, con `Location: /api/projects/{projectId}/stories/{storyId}`. El body es la historia (4.2).
- `422` si el `id` ya existe o si la validación falla (5.4).

Añadir una historia a un proyecto donde todo estaba `completed` hace que `POST /claims` vuelva a devolver trabajo. Los workers que ya hayan terminado por `complete` hay que relanzarlos.

### 6.6 `PATCH /projects/{projectId}/stories/{storyId}`

El body contiene solo los campos que cambian (ver los editables en 5.5):

```json
{ "acceptanceCriteria": ["...", "Typecheck passes"], "dependsOn": ["US-001", "US-006"] }
```

- `200` con la historia completa.
- `409` si la historia no es editable (5.5). El `message` indica el motivo: ya ha empezado o tiene un claim activo.
- `422` si un campo no es editable o si la validación falla (5.4).

### 6.7 `POST /projects/{projectId}/claims`

```json
{ "worker": "vps-1-881" }
```

El servidor elige la historia según 5.1. El worker no indica etapa: la recibe en `story.stage`.

- `201`, con `Location: /api/projects/{projectId}/claims/{claimId}`. El body es el claim (4.6) con la historia completa.
- `409` si no hay ninguna historia elegible. El body indica qué debe hacer el worker:

```json
{ "message": "No eligible story", "reason": "waiting", "counts": { "...": "como en 4.1" } }
```

| `reason` | Significado | Qué hace el worker |
|---|---|---|
| `complete` | Todas las historias están `completed`. No llegará más trabajo. | Termina. |
| `waiting` | Hay historias `pending` o `in_progress`, pero ninguna elegible ahora mismo: tienen claim o dependencias sin terminar. | Espera y vuelve a intentarlo. |

- `422` si falta `worker`.

### 6.8 `DELETE /projects/{projectId}/claims/{claimId}`

Libera el claim sin registrar ningún run. El worker lo usa cuando una ejecución falla. La historia se queda en su etapa y otro worker puede retomarla.

- `204`.
- `404` si el claim no existe o ya ha caducado.

### 6.9 `POST /projects/{projectId}/stories/{storyId}/runs`

```json
{
  "claimId": "01JC9A...",
  "worker": "vps-1-881",
  "stage": "implement",
  "result": "done",
  "body": "- Implementado el filtro...",
  "pr": "https://github.com/mbernet/myapp/pull/12",
  "assumptions": [
    "No está claro si el filtro debe persistir entre sesiones. He asumido que no."
  ]
}
```

- Obligatorios: `claimId`, `worker`, `stage` y `result`.
- `pr` es opcional. Si se envía, sustituye el `pr` de la historia.
- `assumptions` es opcional: una lista de textos. Cada uno crea una asunción (4.5) asociada al run.
- El servidor aplica la transición (5.2) y renueva o borra el claim.
- `201` con `{ "run": run, "story": historia completa }`. El worker mira `story.status` y `story.stage` para saber si sigue y con qué etapa.
- `409` en estos casos:
  - `claimId` no es el claim de la historia. Pasa cuando el claim caducó y otro worker ya la ha retomado: el worker antiguo debe abandonar la historia.
  - La historia está `completed`.
  - `stage` no coincide con la etapa actual de la historia.
- `422` si `result` no es válido para esa etapa (4.4).
- En la última etapa, si el run es un `changes_requested` que provoca avance forzado, la respuesta incluye `"forcedApproval": true` y la historia sigue en esa etapa (5.2).

Un claim caducado que nadie ha sustituido sigue siendo válido: si el worker registra el run tarde, se acepta y el claim se renueva.

### 6.10 `PATCH /projects/{projectId}/stories/{storyId}/assumptions/{assumptionId}`

La usa una persona al revisar.

```json
{ "reviewed": true }
```

- `200` con la asunción. El servidor fija `reviewedAt`.
- `reviewed: false` la vuelve a dejar pendiente y borra `reviewedAt`.
- `422` si el body contiene algo distinto de `reviewed`.

### 6.11 `GET /projects/{projectId}/progress`

`200`, `Content-Type: text/markdown`. Se construye así:

- Incluye las historias `completed`, ordenadas por `completedAt`.
- De cada historia, toma el último run `done` de la primera etapa.

```markdown
## 2026-11-04T10:12:00Z - US-001
<body del run>
---
```

No incluye historias que no estén `completed`, porque su código todavía no está en main. Tampoco incluye los runs de intentos rechazados: el implementador los recibe en `{{runs}}` cuando reintenta, y se pueden consultar en el detalle de la historia.

## 7. Worker (`ralph.sh`)

### 7.1 Ciclo

`ralph.sh`, configurado con `RALPH_API_URL`, `RALPH_API_TOKEN` y `RALPH_PROJECT_ID`. Sin `RALPH_API_URL` funciona como ahora, con `prd.json` local.

1. `POST /claims`. Si responde `complete`, termina. Si responde `waiting`, espera y lo vuelve a intentar.
2. Con la historia recibida, repite por cada etapa:
   1. Hace `git fetch` y lee el prompt de `story.stage` desde `origin/main` (7.2).
   2. Prepara la rama:
      - En la primera etapa: crea `ralph/{storyId}` desde `origin/main`, o la reutiliza si viene de un rechazo.
      - En el resto: hace checkout de la rama del PR.
   3. Descarga `GET /progress` y lo guarda como `progress.txt` local.
   4. Lanza un agente nuevo, con contexto limpio, el prompt renderizado y el modelo de la etapa.
   5. Si el agente termina bien:
      - En la primera etapa: hace push de la rama y crea o actualiza el PR.
      - En la última etapa, si el agente aprueba: mergea antes de registrar el run (7.4). Si el merge falla, registra `merge_failed` en lugar del resultado del agente.
      - Registra el run con el resultado, el body y las asunciones que ha escrito el agente (7.3), y recibe la historia actualizada.
      - Si la respuesta trae `forcedApproval: true`, mergea (7.4) y registra un run `approved`, o `merge_failed` si el merge falla.
      - Si el run tenía asunciones, las comenta en el PR. Así se ven donde se revisa el código.
   6. Si la historia sigue `in_progress`, vuelve al paso 2.1 con la nueva etapa. Si está `completed`, vuelve al paso 1.
3. Si el agente falla: `DELETE /claims/{claimId}` y vuelve al paso 1.
4. Si el run responde `409` porque el claim ya no es suyo: abandona la historia y vuelve al paso 1.

El run se registra solo después de que el push haya ido bien. La API nunca debe dar por hecho algo que no está en git.

La revisión la hace el mismo worker que implementó. Lo que la hace independiente es el contexto limpio y el prompt distinto. Para más distancia, el prompt de la revisión puede fijar otro modelo en su frontmatter.

### 7.2 Prompts por etapa

- El prompt de la etapa `S` está en `.ralph/stages/S.md` del repo del proyecto, y siempre se lee de `origin/main`. Así un PR no puede cambiar el prompt con el que se revisa a sí mismo.
- Si no existe, el worker usa `prompts/S.md` de Ralph.
- El frontmatter opcional fija el modelo: `model: low | med | max`. Si la historia tiene `model`, prevalece el de la historia.
- Todos los prompts deben indicar al agente que nunca se detenga a esperar a una persona: si algo requiere una decisión humana, hace la asunción más razonable, la declara y continúa.
- El prompt de la primera etapa debe cubrir el caso en que el último run es `merge_failed`: integrar `origin/main` en la rama, resolver los conflictos respetando la intención de las dos partes (el progress de la historia que ya está en main explica la suya), arreglar el CI si ese era el motivo, ejecutar los tests y hacer push.

Variables disponibles en el prompt:

| Variable | Valor |
|---|---|
| `{{storyId}}`, `{{title}}`, `{{description}}` | Campos de la historia. |
| `{{acceptanceCriteria}}` | Lista en markdown. |
| `{{pr}}` | URL del PR o vacío. |
| `{{runs}}` | Historial de runs de la historia en markdown, incluido el feedback de las revisiones. |
| `{{assumptions}}` | Asunciones de la historia en markdown, indicando las que ya están revisadas. |
| `{{rejections}}`, `{{maxRejections}}` | Cuántas veces ha vuelto la historia a la primera etapa, y el límite. Así el revisor sabe si su rechazo la devolverá o forzará el avance. |
| `{{branch}}` | `ralph/{storyId}`. |

### 7.3 Salida del agente

El agente deja un fichero `ralph-result.json` en la raíz del worktree:

```json
{
  "result": "done",
  "body": "- Implementado el filtro...",
  "assumptions": ["No está claro si el filtro debe persistir entre sesiones. He asumido que no."]
}
```

- `result`: `done`, `approved` o `changes_requested`. `merge_failed` nunca lo escribe el agente.
- `body`: el `body` del run, en markdown.
- `assumptions`: opcional.

El fichero no se commitea. Los Codebase Patterns siguen yendo en `CLAUDE.md`, dentro del PR.

### 7.4 Git y merge

- Una rama por historia: `ralph/{storyId}`, creada desde `main`. El PR va contra `main`.
- El merge no es una etapa ni lo hace un agente. Lo hace `ralph.sh` cuando la última etapa aprueba, antes de registrar ese run.

Procedimiento de merge:

```
git fetch
git merge origin/main      # sobre ralph/{storyId}; sin rebase, para no hacer force push
git push
gh pr checks --watch       # espera al CI
gh pr merge --squash
```

| Qué pasa | Qué hace `ralph.sh` |
|---|---|
| Todo va bien | Registra el run `approved`. La historia pasa a `completed`. No hace falta volver a revisar: la rama solo se ha puesto al día con main, y si eso rompe algo lo detecta el CI. |
| `git merge` da conflictos | `git merge --abort` y registra `merge_failed`. En el body pone los ficheros en conflicto y las historias mergeadas desde que se creó la rama. |
| El CI falla, o `gh pr merge` falla | Registra `merge_failed`. En el body pone los checks que han fallado y un extracto del log. |

Después de un `merge_failed`, la historia vuelve a la primera etapa. El agente resuelve el problema (7.2) y la historia repasa todas las revisiones, porque el código ha cambiado. Cuando la última revisión vuelve a aprobar, se repite este procedimiento.

Las protecciones de rama de GitHub deben exigir que el CI pase antes de mergear.

## 8. Decisiones cerradas

- **Sin bloqueos:** las historias nunca esperan a una persona. Lo que requiere una decisión humana se resuelve con una asunción declarada, y la historia sigue.
- **Límite de rechazos:** al alcanzar `maxRejections`, el siguiente rechazo fuerza el avance y crea una asunción con el motivo.
- **Revisión humana:** no hay avisos. Las historias con asunciones sin revisar se consultan con `GET /stories?needsReview=true` y se ven también en los comentarios del PR.
- **Cambios en el PRD:** se pueden añadir historias en cualquier momento y editar las `pending` sin claim activo. No se pueden borrar historias ni editar las que ya han empezado.
- **Progress:** solo incluye el último run de implementación de cada historia `completed`.
- **Merge sin agente:** lo hace `ralph.sh` cuando la última revisión aprueba. Si falla, la historia vuelve a implementar con `merge_failed`, que no cuenta como rechazo.
- **Un worker por historia:** el worker lleva la historia desde la implementación hasta el merge, con un agente nuevo en cada etapa. Si el worker desaparece, otro la retoma en la etapa en la que estaba.
- **Estado y etapa:** son dos campos separados. `status` es el ciclo de vida; `stage`, la etapa del pipeline.

## 9. Riesgos conocidos

- **CI que falla siempre.** `merge_failed` no tiene límite. Si el agente no consigue arreglar el CI, la historia da vueltas indefinidamente entre implementar, revisar y mergear. Los conflictos no tienen este problema, porque integrar main los resuelve. Si llega a pasar, se puede añadir un límite propio para `merge_failed`.
