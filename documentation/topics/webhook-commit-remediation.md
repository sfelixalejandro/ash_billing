# Remediación de confirmación HTTP y contención de webhooks

## Alcance y estado inicial

Trabajo sobre `fix/billing-security`, HEAD
`62e94bcdd75509cb56fcb4ce7cc94e9d442c4a9e`. El estado inicial estaba limpio;
se inspeccionaron estado, HEAD y diff antes de editar. No se crearon commits,
ramas, PR, pushes ni merges. Los cambios permanecen locales.

Existían `/tmp/ash_post_remediation_test.exs` y los reportes de auditoría.
La reproducción original se ejecutó antes de modificar: **10 pruebas pasaron**,
porque sus aserciones demostraban los defectos. Las expectativas corregidas de
P1–P3 son permanentes en `test/ash_billing/webhook_commit_test.exs`; el archivo
original de diagnóstico no se modificó. Esto es una corrección posterior a F1–F6,
no una nueva afirmación de que todos los riesgos de aquella auditoría desaparecen.

## Resultados y decisiones

| Problema | Causa | Solución y evidencia |
|---|---|---|
| P1: HTTP 200 anterior al COMMIT | `process_event` enviaba la respuesta dentro de `with_lease`; una restricción diferida podía abortar después de enviarla | Preparar con `resp/3`, salir de la transacción y únicamente entonces `send_resp/1`. Prueba con constraint trigger diferido, fallo del primer COMMIT, lectura desde otra conexión al enviar, reintento inmediato y diario SQL que cuenta exactamente una cancelación confirmada |
| Rutas de error y deduplicación | El opt-out podía reconocer fallos de persistencia y se ignoraba el resultado de liberar el lease | Adquisición y completion fallidas producen 5xx; liberar/registrar errores debe tener éxito antes de permitir el opt-out. Fallos de COMMIT de sincronización no usan el opt-out, tampoco en memoria o sin deduplicación. Pruebas de reclaim, handler, sync, completion y cancelación |
| Transacciones externas | Un Plug no puede esperar un COMMIT que hará su caller después de retornar | Rechazar con 503 antes de adquirir/escribir si el proceso está en una transacción Ecto/Ash. Incluye evento nuevo, shortcut de ya procesado y configuración sin recursos de billing |
| P2: contención del pool | El segundo reclaim esperaba un row lock mientras retenía otra conexión | Try advisory lock transaccional por tabla física/event ID, seguido de `FOR UPDATE NOWAIT`; devolver ocupado en vez de esperar. Prueba con pool de dos conexiones, diez duplicados resueltos antes de liberar al propietario y `SELECT 1` con `queue: false` exitoso |
| P3: autobloqueo entre Repos | La transacción del cliente bloqueaba una FK insertada desde otra conexión, mientras la misma ejecución esperaba ambas | Validar un único pool primario para los recursos configurados antes del lease y para sincronización directa. Distintos pools fallan con error estructurado; dos módulos Repo que comparten explícitamente el mismo dynamic Repo sí insertan la FK y confirman correctamente |
| ID ausente o vacío | El atajo público para ID nil podía saltarse el registro de deduplicación en el Plug | Con deduplicación activada el Plug rechaza esos IDs. Los fixtures end-to-end ahora incluyen IDs de evento; las aserciones de comportamiento permanecen |

### Frontera de commit

El cuerpo preparado no se envía durante la transacción. Los errores específicos
Postgrex/DBConnection se convierten en fallos de transacción; otros errores no se
ocultan. La captura no exige que Postgrex esté instalado en producción, donde es
una dependencia opcional del consumidor.

Después de un fallo de ejecución/COMMIT se intenta liberar el lease en otra
transacción, usando su token. No se puede liberar un lease reemplazado ni alterar
un evento ya confirmado por un competidor. Si la limpieza falla, se mantiene 5xx
y la recuperación depende del lease persistente y su expiración. Un resultado de
COMMIT desconocido por desconexión se trata conservadoramente: si el servidor ya
confirmó, el siguiente intento observa `processed`.

Los shortcuts `already_processed` proceden de una lectura protegida de un registro
persistente previamente confirmado, no de una escritura pendiente. El Plug los
rechaza igualmente dentro de una transacción externa.

### Fencing y bloqueos

El advisory lock no sustituye el estado persistente: conserva row lock y CAS de
status/token. Su clave estable depende de tabla física e ID, por lo que dos
módulos de recurso/Repo que acceden a esa tabla arbitran el mismo evento. Una
colisión hash solo añade contención conservadora. `NOWAIT` cubre escritores de
filas que no participan en el advisory lock. Las operaciones locales usan un lock
OTP no bloqueante, reentrante y monitorizado; no se reintroduce el antiguo
`reclaim_lock` ETS huérfano.

El test entre dos nodos BEAM independientes sigue usando PostgreSQL como autoridad:
el duplicado remoto devuelve ocupado antes de liberar al propietario; después
observa el evento procesado. La prueba de `:kill` espera la liberación real del
advisory lock en `pg_locks`, mediante consultas y un deadline, antes de reclamar.
No se usan sleeps arbitrarios para ordenar esas carreras.

## Invariantes preservados

- Un fallo de COMMIT no produce HTTP 2xx; la cancelación y completion del evento
  PostgreSQL en el mismo pool confirman o revierten juntas.
- Un duplicado no reemplaza el token ni ejecuta efectos mientras sigue vigente el
  fence de la transacción propietaria, aunque haya vencido el TTL del lease.
- Una liberación antigua no puede cambiar el propietario nuevo ni deshacer un
  `processed` confirmado.
- F1–F3 conservan tombstones, ownership, comparación de snapshots y serialización
  cliente/suscripción. No se cambian políticas, accept lists ni ámbito tenant.
- Los handlers obligatorios siguen sin poder omitirse silenciosamente.
- No se promete exactly-once para efectos fuera de la transacción PostgreSQL.

## Verificación ejecutada

Entorno local: Elixir 1.20.4 / OTP 29, PostgreSQL real. La matriz CI de otras
versiones no se ejecutó en este trabajo.

| Comando / conjunto | Resultado real |
|---|---|
| `mix test /tmp/ash_post_remediation_test.exs` antes de editar | 10 pasaron; demuestra baseline vulnerable. Log `/tmp/ash-ack-before.log` |
| Pruebas dirigidas iniciales de Plug, seguridad y commit | 32, 6, 41 y finalmente 27 pasaron en sus respectivas etapas; logs `/tmp/ash-ack-initial.log`, `/tmp/ash-commit-regressions.log`, `/tmp/ash-nonblocking-initial.log`, `/tmp/ash-nonblocking-regressions.log` |
| `mix test --cover`, versión final | **311 pasaron, 90,82 % cobertura total**, exit 0; `/tmp/ash-ack-full-final.log` |
| `mix format --check-formatted` | Exit 0; `/tmp/ash-ack-format-final.log` |
| `mix compile --warnings-as-errors` | Exit 0; `/tmp/ash-ack-compile-final.log` |
| `MIX_ENV=prod mix compile --warnings-as-errors` | Exit 0 después de eliminar la referencia obligatoria al struct Postgrex; `/tmp/ash-ack-prod-compile-final.log` |
| `git diff --check` | Sin errores |
| `mix test /tmp/ash_post_remediation_test.exs:282` | 1 pasó, 9 excluidas; reproduce el límite de efectos externos al perder la conexión; `/tmp/ash-ack-disconnect.log` |
| `mix hex.audit` | Falló por advisory preexistente HIGH de Bandit 1.14.0, EEF-CVE-2026-116078; `/tmp/ash-ack-deps.log`. No se modificaron dependencias |
| Disponibilidad de Credo / Dialyzer (`mix help credo`, `mix help dialyzer`) | Tareas no disponibles; no se ejecutaron análisis inexistentes |

Durante el desarrollo hubo fallos intermedios corregidos: una aserción equivocada
sobre `Repo.rollback`, una recuperación anterior a la limpieza asíncrona de la
conexión, un arity incorrecto de `release` en el test, una expectativa de logging,
fixtures sin IDs y una configuración de test que seleccionaba recurso en vez de
memoria. También se eliminaron warnings nuevos de comparaciones constantes en
los tests y de Postgrex opcional en producción. La suite final conserva warnings
preexistentes del recurso dinámico de prueba `SecurityRegression.LockEvent`
(consolidación de Inspect y preparación del read); no se suprimieron.

## Compatibilidad, riesgos residuales y producción

1. **Configuración más estricta:** el Plug rechaza transacciones externas y pools
   primarios distintos. La sincronización directa devuelve
   `{:error, {:multiple_transaction_repos, repos}}` para estos últimos. Esto es un
   rechazo explícito, no soporte de commits distribuidos. Una aplicación con
   bases/pools separados debe consolidar el pool transaccional o diseñar un
   inbox/outbox y reconciliación como cambio arquitectónico separado.
2. **Efectos externos:** la reproducción de desconexión confirmó que un callback
   antiguo puede seguir vivo y realizar un efecto después de que otro propietario
   termine. PostgreSQL puede liberar su fence al perder la conexión; ese fence no
   protege sistemas externos. Idempotency keys por evento/efecto o un outbox único
   son requisitos del consumidor. No se cambió esa frontera ni se promete
   ejecución externa exactly-once.
3. **Capacidad del pool:** los duplicados todavía necesitan checkout breve para
   arbitrar en PostgreSQL. Un pool sin conexiones disponibles puede rechazar o
   demorar peticiones. Eventos distintos del mismo cliente también pueden esperar
   sus locks de sincronización. Configurar timeouts y capacidad; no se afirma que
   se haya eliminado toda contención ni se hizo una prueba de carga de producción.
4. **Despliegue mixto:** drenar workers antiguos. Los binarios previos no toman el
   advisory lock nuevo; especialmente una inserción sin fila previa puede volver
   a esperar ante un escritor antiguo/no cooperante.
5. **Modos no durables:** memoria, otros data layers no transaccionales y
   `deduplicate?: false` conservan sus límites. No crean historial durable por
   sí mismos. El test demuestra rechazo del COMMIT de billing fallido, no
   atomicidad de ETS con PostgreSQL ni deduplicación durable en memoria.
6. **Contrato del handler:** trabajo síncrono, acotado, sin enviar la respuesta,
   cambiar el dynamic Repo ni usar otra conexión/base para efectos que se pretenden
   atómicos. El Plug no puede garantizar commits de transacciones desconocidas o
   tareas independientes creadas por código de aplicación.
7. **Otros riesgos:** U1–U4 permanecen fuera del alcance. El advisory HIGH de
   Bandit sigue pendiente de una actualización separada. No se probaron fallos de
   red con resultado ambiguo de COMMIT, failover ni todas las variantes de réplicas;
   el código retorna error y los reintentos dependen del registro durable.

La corrección está validada para el flujo PostgreSQL en un mismo pool primario,
con handlers que respeten ese contrato. La preparación para producción sigue
condicionada a configuración compatible, idempotencia externa, drenaje de workers,
revisión de U1–U4 y resolución del advisory de dependencias aplicable al despliegue.

## Archivos y resumen del diff

| Archivo | Cambio |
|---|---|
| `lib/ash_billing/plug.ex` | Preflight transaccional; preparar antes de enviar; errores de persistencia fail-closed; cleanup CAS; validar ID |
| `lib/ash_billing/resource_lock.ex` | Validar pool primario, detectar transacciones externas, capturar errores específicos de commit y try lock local |
| `lib/ash_billing/deduplication.ex` | Try advisory xact lock y lectura NOWAIT para adquisición, ejecución, completion y release; preservar CAS |
| `test/ash_billing/webhook_commit_test.exs` (nuevo) | 14 regresiones permanentes de commit, errores, transacciones externas, pool, locks, Repos e IDs |
| `test/support/webhook_transaction_support.ex` (nuevo) | Repo/pool y recursos de integración adicionales |
| `test/ash_billing/security_regression_test.exs` | Expectativas no bloqueantes; prueba multinodo y recuperación tras liberación real del fence |
| `test/ash_billing/end_to_end_test.exs` | IDs únicos en tres fixtures de eventos válidos |
| `documentation/topics/webhooks-and-resilience.md` | Contrato de commits, configuración, contención y límites |
| `CHANGELOG.md` | Entrada bajo Unreleased |
| Este informe (nuevo) | Evidencia, compatibilidad y riesgos residuales |
