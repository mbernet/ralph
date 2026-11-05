# Ralph sobre la API central: diseño del worker

Estado: implementado · 2026-11-05 · Spec de la API: [`central-prd-spec.md`](central-prd-spec.md) · OpenAPI: `{host}/api/ralph/docs?api-docs.json`

Este documento fue la propuesta de cambios y se ha implementado tal cual, salvo lo que recoge la sección 7. El uso está en el [`README`](../README.md); las convenciones del script, en [`AGENTS.md`](../AGENTS.md).

## 1. Qué se mantiene

La filosofía de Ralph no cambia. Cambia dónde vive la memoria.

- Un agente nuevo por iteración, con contexto limpio.
- Una sola unidad de trabajo por iteración. Antes era una historia; ahora es una etapa de una tarea.
- El script decide qué se hace y con qué modelo. El agente solo hace el trabajo.
- El agente nunca decide que el bucle ha terminado ni elige tarea.
- Bash 3.2, `jq` y `curl`. Sin dependencias nuevas salvo `gh`.
- El pacing de la ventana de 5 h y 7 d, el ledger, los logs y el `--dry-run` siguen como están.

| Hoy | Con la API |
|---|---|
| `prd.json` y el flag `passes` | `POST /work` y el `outcome` de cada run |
| Selección por `priority` con `jq` | La hace el servidor |
| `progress.txt` | El `body` de cada run y el `summary` final; llegan en `progress` |
| Sección "Codebase Patterns" | `summary` de las tareas hechas, más los `CLAUDE.md` del repo |
| `notes` para bloqueos | `outcome: sick` con el motivo en `body` |
| `branchName` del PRD | Una rama por tarea: `ralph/<id>` |
| `<promise>COMPLETE</promise>` | `finished` en la respuesta de `POST /work` |
| Un prompt único | Un prompt por etapa del pipeline, más `doctor` |
| Commits sobre una rama compartida | PR por tarea; el merge es una etapa |

## 2. Decisiones que propongo

### 2.1 Solo modo API

`ralph.sh` deja de leer `prd.json` y `progress.txt`. Mantener los dos modos obliga a duplicar la selección, el prompt, el resultado y el bucle, que es casi todo el script. El modo de ficheros sigue disponible en el historial de git y en el Ralph original.

### 2.2 El agente entrega su resultado en un fichero

Es el hueco principal que deja la spec. Propongo que el agente escriba un JSON en una ruta que le da el prompt:

```json
{
  "outcome": "pass",
  "body": "- Added PriorityBadge component...\n- Tests: 12 passed",
  "assumptions": ["Not clear whether the badge shows on archived tasks. Assumed it does."],
  "pr": "https://github.com/acme/myapp/pull/12",
  "summary": null
}
```

- La ruta es `.ralph/logs/<run>/iter-NN.result.json`: fuera del árbol que el agente commitea y archivada con el resto de logs de la iteración.
- El script lo valida con `jq` antes de enviarlo, con las mismas reglas por posición que el servidor, y le añade `claimId`.
- Es el equivalente directo de lo que el agente hace hoy: editar `passes` y escribir en `progress.txt`.

Descarto leerlo del mensaje final: un `body` en markdown con saltos de línea y bloques de código es frágil de extraer, y hoy `ralph.sh` ya aplana ese texto. El fichero además funciona igual con `claude` y con `amp`.

### 2.3 Todo el contexto va inyectado en el prompt

La respuesta entera de `POST /work` se guarda en `iter-NN.work.json` y se añade al prompt bajo `## This Iteration`. El agente no llama a la API: el script lanza el agente sin `RALPH_API_TOKEN` en su entorno.

### 2.4 Prompts por etapa

```
prompts/
  _common.md            reglas compartidas y contrato del resultado
  implement.md
  review_functional.md
  review_code.md
  merge.md
  doctor.md
```

El prompt de una iteración es `_common.md` + `<stage>.md` + el bloque inyectado. Al arrancar, el script pide el proyecto y comprueba que hay un fichero por cada etapa de `pipeline` y uno para `doctor`; si falta alguno, no empieza. Un proyecto con otro pipeline solo añade o quita ficheros.

Qué pide cada uno, con el pipeline de ejemplo:

| Prompt | Hace | Resultado |
|---|---|---|
| `implement` | Crea o retoma `ralph/<id>` desde `main`. Si hay rechazos en `runs`, aplica ese feedback. Implementa, pasa los checks, hace commit, push y abre el PR si no existe. Si algo no está claro, asume y lo declara. | `pass` con `pr`, `assumptions` y el informe en `body`. `sick` si está bloqueado. |
| `review_functional` | Baja la rama del PR y verifica cada criterio de aceptación, en navegador si toca. Valora las asunciones. No modifica código. | `pass`, `reject` con feedback accionable, o `sick`. |
| `review_code` | Revisa el diff: calidad, patrones del repo, tests. No modifica código. | Igual. |
| `merge` | Actualiza la rama con `main`, espera al CI, mergea y escribe el `summary`: qué se hizo y qué conviene saber. | `pass` con `summary`. `reject` si los conflictos exigen reimplementar. `sick` si el CI no pasa por causas ajenas. |
| `doctor` | Lee `runs`, diagnostica y arregla lo que tenga arreglo. | `pass`, `reject` o `sick`. |

`CLAUDE.md` y `prompt.md` dejan de ser el prompt del bucle. La parte de "actualiza los `CLAUDE.md` cercanos con lo aprendido" se conserva en `implement.md`: esos cambios viajan en el PR.

### 2.5 Tiers de modelo

- El tier `max` pasa a llamarse `high`, como en la API. `RALPH_MODEL_MAX` se sigue aceptando como alias de `RALPH_MODEL_HIGH`.
- El tier de la tarea vale para todas sus etapas. El doctor usa siempre `high`, configurable con `RALPH_DOCTOR_TIER`.

### 2.6 Importar un PRD

El skill `ralph` sigue escribiendo un fichero que una persona puede leer y corregir antes de lanzar nada, y un comando nuevo lo sube:

```
./ralph.sh --import prd.json
```

Formato nuevo del fichero:

```json
{
  "project": "myapp",
  "description": "Task Priority System - Add priority levels to tasks",
  "pipeline": ["implement", "review_functional", "review_code", "merge"],
  "tasks": {
    "US-001": { "title": "...", "description": "...", "acceptanceCriteria": ["..."], "priority": 1, "model": "low", "dependsOn": [] }
  }
}
```

El comando hace `PUT` del proyecto y luego de cada tarea, en orden de dependencias. Es idempotente: volver a importar edita las specs, y las tareas ya `done` se informan y se saltan.

Cambios en el skill que impone la API:

- **`priority` ya no es el orden.** La API solo admite de 1 a 5. Pasa a ser importancia, y el orden lo dan `dependsOn` y el id.
- **`dependsOn` explícito** en cada tarea.
- `model` es `low`, `med` o `high`.
- Desaparecen `passes`, `notes` y `branchName`. La API rechaza propiedades desconocidas.

## 3. Cambios en `ralph.sh`

### 3.1 Configuración

| Variable | Qué es |
|---|---|
| `RALPH_API_URL` | Base de la API, por ejemplo `http://localhost:8090/api/ralph`. |
| `RALPH_API_TOKEN` | Token del despliegue. |
| `RALPH_PROJECT` | Slug del proyecto. |
| `RALPH_WORKER` | Nombre estable del worker. Por defecto, el hostname en minúsculas. |
| `RALPH_CLAIM_MARGIN_S` | Margen antes de `expiresAt` para reintentar. Por defecto, 1800. |
| `RALPH_IDLE_S` | Espera cuando no hay trabajo elegible. Por defecto, 60. |

Se leen del entorno o de un `.ralph/env` ignorado por git, para que el token nunca entre en el repo.

### 3.2 Regiones

| Región | Cambio |
|---|---|
| `config`, `args` | Variables nuevas. `--story` se traduce a `task` en `POST /work`. Se añade `--import`. Desaparece `--no-inject`. |
| `preflight` | Exige `curl` y `gh`. Comprueba token, proyecto y un prompt por etapa. Sustituye a `validate_prd`. |
| `session` | Se eliminan el archivado por rama, `.last-branch` y `init_progress`. Queda `prune_logs`. |
| `prd` → `api` | Se sustituye entera. Un único punto de salida HTTP y tres operaciones: pedir trabajo, registrar run, leer proyecto. |
| `model` | `high` en lugar de `max`. Tier del doctor. |
| `prompt` | Compone `_common.md`, el prompt de la etapa y el JSON de trabajo. |
| `result` | Se elimina `is_complete`. Se añade la lectura y validación del fichero de resultado. |
| `iteration` | Reintentos acotados por el claim en vez de por número. Registro del run. |
| `main` | Bucle nuevo (3.3). Resúmenes con `counts`. |
| `dry-run` | Respuestas de la API simuladas con fixtures. Escenarios nuevos: `reject`, `sick`, `nowork`, `conflict`. |
| `stream`, `usage`, `pace`, `ui` | Sin cambios de fondo. |

### 3.3 Bucle

```
for ITER in 1..MAX_ITERATIONS:
  pace_decide / pace_enforce                    # unchanged: throttle, wait for reset, or stop
  work = POST /work { worker, task? }
  if work.stage == null:
     if work.finished: stop (complete or blocked)
     sleep RALPH_IDLE_S; continue                # does not consume an iteration
  resolve tier and model from work.stage and work.task.spec.model
  loop:
     run the agent with prompts/<stage>.md and the work JSON
     classify the outcome of the process (3.4)
     valid result file  -> POST /runs, break
     retryable          -> if now + wait + MARGIN >= claim.expiresAt: drop the task, break
                           sleep(wait)
```

- Al soltar una tarea por falta de margen, el bucle vuelve arriba y el pacing que ya existe espera al reset de la ventana o para. Así se cumple la regla de no pedir trabajo sin cuota sin escribir nada nuevo.
- `MAX_ITERATIONS` pasa a contar ejecuciones del agente, no historias. Con el pipeline de ejemplo, una tarea sin rechazos son cuatro.

### 3.4 Qué se hace con cada resultado

| Qué pasó | Acción |
|---|---|
| El agente acabó y el fichero de resultado es válido | `POST /runs`. |
| `POST /runs` devuelve `409` | Se descarta el resultado: otro worker tiene la tarea. Se sigue con el bucle. |
| El agente acabó sin fichero válido | Un reintento. Si se repite, run `sick` escrito por el script con el motivo. |
| Límite de turnos o de presupuesto | Igual: un reintento y después `sick`. Es señal de tarea sobredimensionada y debe verla el doctor. |
| Rate limit | Se conserva el claim, se espera al reset y se reintenta mientras quede margen. |
| El proceso muere sin resultado | Un reintento. Si se repite, el worker aborta como hoy y el claim caduca solo. |
| Fallo de autenticación del CLI | El worker termina. Dormir no lo arregla. |
| La API no responde | Reintento con backoff. No es culpa de la tarea. |
| `401` o `404` de proyecto | El worker termina: es un error de configuración. |

### 3.5 Git

El script sigue sin hacer git: lo hace el agente según su prompt. Dos comprobaciones nuevas, porque ahora un worker cambia de rama entre iteraciones:

- En `preflight`: el remoto es de GitHub y `gh` está autenticado. La API solo acepta URLs de PR de `github.com`.
- Antes de cada etapa: si el árbol está sucio por una ejecución anterior que murió, el script lo guarda en un stash etiquetado y avisa. No borra nada.

Cada worker debe trabajar en un clon propio, no en la copia de trabajo de una persona.

### 3.6 Lo que se ve

- Cabecera de iteración: tarea, etapa, tier y modelo.
- Resumen de iteración: `US-002 · review_code → pass → merge`, y la barra de progreso con `done/total` más `needsHuman` y `blocked`.
- Estados finales: `complete`, `blocked` (lista las tareas que esperan a una persona), `exhausted` e `incomplete`.
- El ledger gana `task`, `stage` y `outcome` por fila.

## 4. Resto del repo

| Fichero | Cambio |
|---|---|
| `CLAUDE.md`, `prompt.md` | Se sustituyen por `prompts/`. |
| `skills/ralph/SKILL.md` | Formato nuevo, `dependsOn`, `priority` de 1 a 5, tier `high`, y el paso de importar. Se elimina la sección de archivado. |
| `skills/prd/SKILL.md` | Sin cambios. |
| `prd.json.example` | Ejemplo en el formato nuevo. |
| `AGENTS.md`, `README.md` | Convenciones y uso nuevos. |
| `.gitignore` | Fuera `prd.json`, `progress.txt` y `.last-branch`. |
| `tests/window.test.sh`, `tests/replay.sh` | Sin cambios. |
| `tests/api.test.sh` | Nuevo. Sustituye el punto de salida HTTP por fixtures. |
| `flowchart/` | Queda desfasado. Se actualiza aparte. |

## 5. Orden de trabajo

Cada paso deja el script funcionando y se hace con tests primero.

1. Cliente de la API, configuración y `preflight`.
2. `--import` y el skill, para poder cargar un proyecto de prueba.
3. Contrato del resultado: lectura, validación y registro del run.
4. Bucle nuevo con reintentos acotados por el claim.
5. Prompts por etapa.
6. Resúmenes, ledger y fixtures del `--dry-run`.
7. Documentación.

## 6. Comprobado contra la API en local

- La definición OpenAPI coincide con la spec: mismos siete endpoints, mismos esquemas y mismas reglas por posición.
- El token funciona. Sin token responde `401` y un proyecto inexistente `404`, ambos con la forma `{ "error": "..." }`.
- Prueba de punta a punta con el script ya implementado y un agente de pega: `--import` de un proyecto de dos tareas y pipeline de dos etapas, y el bucle completo sobre él. Resultado: las dos tareas en `done`, un rechazo que devuelve la tarea a la primera etapa, la segunda tarea repartida solo cuando su dependencia cerró y con el `summary` de la primera en `progress`, y el worker terminando solo con código `0`.
- Esa prueba dejó en la API local un proyecto desechable, `ralph-selftest-1793881401`. La API no permite borrar proyectos.

## 7. Diferencias con lo propuesto

- **Servidor falso en lugar de fixtures.** `--dry-run` y los tests comparten `_http_fake`, un servidor escrito en `jq` que guarda su estado en un fichero y aplica las reglas de la spec. Así el dry-run ejercita el bucle real, no una maqueta. El riesgo es que el falso y la API real diverjan: cuando cambie la API hay que cambiar el falso y repetir la prueba de la sección 6.
- **`RALPH_AGENT_CMD`.** Sustituye a `amp` o `claude` por cualquier comando que lea el prompt por la entrada estándar. Es como los tests y la prueba de punta a punta mueven el bucle sin gastar tokens.
- **Espera explícita de cuota.** Tras soltar una tarea por rate limit, el worker espera él mismo al reset de la ventana (o un backoff largo si no conoce la ventana) antes de volver a pedir trabajo. Apoyarse solo en el pacing no bastaba: sin lectura de la ventana, el pacing deja pasar.
- **Un resultado rechazado por la API cuenta como intento fallido.** Si la validación local deja pasar algo que el servidor responde con `422`, se trata igual que un resultado mal formado: un reintento y después `sick`.
- **El stash solo se hace si `.ralph/` está ignorado por git.** Si no, se llevaría los logs de la ejecución en curso. `RALPH_STASH=0` lo desactiva.
- **`gh` se comprueba autenticado; el remoto, solo con un aviso.** Un remoto que no es de GitHub no impide arrancar.
- **`CLAUDE.md` pasa a apuntar a `AGENTS.md`.** Ya no es el prompt del bucle, y así las sesiones de Claude Code en este repo reciben las convenciones del script.
- **Códigos de salida.** `0` no queda nada, `1` iteraciones agotadas, `2` ventana agotada, `3` lo que queda espera a una persona, `4` configuración o autenticación, `5` el agente muere dos veces seguidas, `6` API inalcanzable.
- **Rescate de una tarea parada.** `./ralph.sh --story <id>` la pide a dedo y vuelve a mandar al doctor. El resumen final lista las tareas paradas con su diagnóstico.
- **`RALPH_MAX_RETRIES` desaparece.** Los reintentos los acota el claim.
