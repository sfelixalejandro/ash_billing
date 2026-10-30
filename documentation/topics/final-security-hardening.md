# Endurecimiento final U1–U4 y evaluación para merge

## Resumen y estado inicial

La rama inicial fue `fix/billing-security`, HEAD exacto
`5beb81f1fe6c210aa0125e2f9ccbe8e2368897e5`, como indicó el usuario. El árbol estaba
limpio; no había trabajo local ajeno que preservar. Se inspeccionaron estado, HEAD,
diff y las dos remediaciones previas antes de editar. Se hizo `git fetch origin`:
`origin/main` estaba en `55dfd79`, ancestro de HEAD, con cero commits exclusivos de
main y tres exclusivos de esta rama. No se cambió de rama ni se crearon commits,
push, merge, PR, release o publicación de Hex durante esta ronda.

Antes de cambiar código se ejecutaron las 34 pruebas de seguridad y commit:
todas pasaron. También se ejecutaron cuatro diagnósticos U1–U4 del archivo existente
`/tmp/ash_post_remediation_test.exs`; los cuatro demostraron el comportamiento
anterior. Los informes anteriores conservan sus resultados históricos; este
informe los actualiza respecto de U1–U4 y Bandit.

**Resultado local:** 335 pruebas pasan y la cobertura es 91,58 %. P1–P3 y F1–F6
siguen cubiertos por las suites existentes. U2 y U4 eran defectos de la librería;
U1 y U3 dependen también de la exposición/configuración del consumidor. Se han
endurecido esos defaults sin afirmar que la librería sustituye autorización,
configuración de cuentas o idempotencia externa.

## Hallazgos, evidencia y correcciones

| Área | Clasificación y confianza | Causa y alcance | Corrección y regresión |
|---|---|---|---|
| U1 | Integración condicional de impacto alto; comportamiento confirmado | Los atributos inyectados públicos entraban en `default_accept :*` / `accept :*`. Una app con política permisiva y una mutación expuesta podía cambiar customer ID o estado que concede acceso. La librería no exponía por sí sola esa ruta HTTP | El transformer registra la intención del comodín antes de `DefaultAccept` y retira campos sensibles después de su expansión y antes de cachear inputs. App consumidora mínima con políticas y CRUD demuestra rechazo de inputs atom/string; se permiten campos de perfil. Se cubren identidad, tombstones, status, precio, trials, periodos, cancelación, orden y FK de ownership |
| U2 | Medium, defecto confirmado de propagación | Las operaciones perdían `tenant`, incluyendo create/read, reclaim, completion, release y fallback destroy. Un recurso que requiere tenant fallaba aun recibiéndolo. El diagnóstico no demostró por sí solo corrupción cruzada | Opciones Ash consistentes con dominio/tenant y `authorize?: false` ya usado por el subsistema. Normalizar mediante `Ash.ToTenant`, filtrar lecturas en vez de asumir PK simple, incluir tenant en fences y claves de memoria. Pruebas PostgreSQL con PK compuesta y dos nodos independientes, más memoria, tokens antiguos y fallback destroy |
| U3 | Riesgo condicional confirmado, no falsificación de firma | Un evento válidamente firmado para un endpoint sin restricciones podía tener cuenta/modo distintos de los que el consumidor pretendía procesar. Cuenta/modo no formaban parte del modelo de identidad local | Stripe verifica firma y después cuenta/modo antes de devolver el evento al Plug. Default de cuenta de plataforma; Connect exige cuenta exacta y modo vinculado. Se rechazan sobres v2 con context. Prueba real de dos tenants PostgreSQL con IDs iguales: uno activo y otro cancelado, sin cambios cruzados |
| U4 | Medium, defecto de routing confirmado | Las APIs de suscripción elegían Stripe aunque el recurso declarase otro provider; quantity perdía el recurso al convertirlo a ID. La reconciliación tenía el mismo default | Resolver con `Subscription.Info.provider/1`; override explícito prioritario; IDs sin recurso siguen usando Stripe. Quantity conserva el proveedor antes de convertir a ID. Pruebas de get/cancel/resume/swap/quantity, checkout/customer/portal, overrides y reconciliación del mismo segundo |
| Colisión de idempotencia de creación | Medium, impacto condicional; colisión de claves reproducida | La clave automática era `ash_cust_<id>`, igual para recursos/tenants distintos con el mismo ID. Puede reutilizar una respuesta de creación o impedir la segunda creación según parámetros y cuenta del proveedor | SHA-256 de recurso, tenant canónico e ID local, conservando el prefijo `ash_cust_` y los overrides explícitos. Una regresión falló antes del cambio y pasa después; no se realizaron operaciones reales en Stripe |

### Referencias de código y pruebas

Las rutas relevantes del diff actual son:

- `lib/ash_billing/transformers/protect_billing_attributes.ex:9`: creación de sistema
  conserva cambios/validaciones de la acción, políticas, tenant e identidades.
  La aceptación ampliada existe solo en esa instancia interna de acción.
- `lib/ash_billing/transformers/protect_billing_attributes.ex:22`: registrar los
  inputs sensibles derivados de comodines; `:63` aplica la exclusión tras Ash.
  Los transformers de cliente y suscripción suministran sus campos protegidos.
- `lib/ash_billing/deduplication.ex:157`: normalización de tenant y propagación;
  `:183` codifica la clave literal de memoria; `:191` preserva el namespace de
  advisory locks sin tenant y añade el scope cuando corresponde. El resto del diff
  lleva las opciones a todas las operaciones, sin retirar CAS ni row locks.
- `lib/ash_billing/providers/stripe.ex:199`: validación de scope después de firma;
  `:208` compara cuenta/modo; `:246` infiere modo; `:334` construye requests con
  headers explícitos de cuenta/idempotencia que no desaparecen por `req_opts`.
- `lib/ash_billing.ex:252`: routing de APIs de suscripción; `:331` conserva provider
  en quantity; `:459` genera idempotencia por recurso/tenant/ID; `:479` define la
  precedencia del proveedor. `webhook_sync.ex` conserva el provider en reconciliación.
- `test/ash_billing/final_hardening_test.exs`: 24 regresiones permanentes; U1 desde
  `:55`, U2 desde `:183`, U3 desde `:269`, U4 desde `:326`, nodos BEAM en `:422`,
  cuentas/modos/entitlements en `:463`, tenant canónico en `:577`, protección de
  valores especiales de ETS en `:677`, claves de customer en `:695`.

### Separación entre usuario y sistema

No se cambia `public?` para ocultar datos que las aplicaciones ya leen, ni se
reemplazan políticas de aplicaciones. Un nombre aceptado explícitamente sigue
siendo una decisión del consumidor; debe tener una política de mantenimiento o
ownership apropiada. Tampoco se puede proteger código de servidor que entregue
cambios privilegiados a partir de parámetros no autorizados.

La protección cubre defaults y comodines, incluidos campos declarados manualmente,
IDs personalizados y el FK de cliente configurado. Calculations de entitlements
siguen siendo cálculos de Ash, no inputs de acción. Defaults que conceden acceso,
relaciones gestionadas mediante cambios de acciones personalizados y aceptaciones
explícitas requieren revisión de la aplicación.

La escritura del webhook no añade aceptación pública a las acciones. La creación
presenta los atributos del proveedor antes de ejecutar validaciones/cambios;
actualizaciones conservan filtros CAS y usan cambios atómicos explícitos. La
regresión de consumidor prueba tanto rechazo por políticas sin actor como rechazo
por validación de un estado que la acción prohíbe. Los fixtures previos ahora
nombran sus inputs de billing deliberadamente para seguir construyendo estados de
prueba; no se debilitaron las aserciones existentes. La app consumidora nueva usa
comodines reales sin esas aceptaciones privilegiadas.

### Scope Stripe e idempotencia

La validación no es una allowlist arbitraria de muchas cuentas sobre el mismo
almacenamiento: el contrato sigue siendo una cuenta/entorno/proveedor por tenant
o recurso. El default rechaza `account` no nil. `stripe_account:` fija una cuenta
Connect y el header de API. `expected_livemode:` fija un booleano; si se omite, se
infiere de credenciales `sk_live_`/`rk_live_` o `sk_test_`/`rk_test_`. Connect sin un
modo verificable se rechaza. Plataforma sin información de modo mantiene la
compatibilidad sin restricción de modo; se debe configurarlo explícitamente en
producción. El evento no escoge credenciales ni tenant automáticamente.

Stripe documenta que los endpoints Connect de producción pueden recibir eventos
live y test, y que `account` identifica al propietario conectado. Las consultas de
objetos conectados deben usar esa cuenta. No basta con comprobar la firma para
establecer esa asociación local. Fuentes primarias: [Connect webhooks](https://docs.stripe.com/connect/webhooks),
[API de cuentas conectadas](https://docs.stripe.com/api/connected-accounts).

La colisión de claves de creación se confirmó localmente. El posible efecto externo
se fundamenta en la semántica publicada de Stripe v1: la misma clave puede devolver
la respuesta anterior, o producir error ante parámetros distintos. No se afirma
haber ejecutado un ataque contra Stripe real. Fuente:
[Idempotent requests](https://docs.stripe.com/api/idempotent_requests).

## Verificación ejecutada

Runtime local: Elixir 1.20.4 / OTP 29, PostgreSQL real, y un segundo BEAM iniciado
con `:peer`. La matriz de CI declarada (Elixir 1.17/1.18, OTP 26/27) no se ejecutó
localmente. Los tests concurrentes usan mensajes/barreras, no sleeps arbitrarios.

| Comando o conjunto | Resultado |
|---|---|
| Seguridad y commit previos a cambios | 34 pasaron; `/tmp/ash-hardening-baseline.log` |
| Cuatro diagnósticos U1–U4 temporales, antes de cambios | 4 pasaron, 6 excluidos; `/tmp/ash-hardening-u-baseline.log` |
| Suite de seguridad durante la implementación | P1–P3 y F1–F6: 34 pasaron; `/tmp/ash-hardening-preserved.log` |
| `mix test --cover` final | **335 pasaron; 91,58 %**, umbral 90 % intacto; `/tmp/ash-hardening-full-final.log` |
| `mix format --check-formatted` | Exit 0; `/tmp/ash-hardening-format-final.log` |
| `mix compile --warnings-as-errors` | Exit 0; `/tmp/ash-hardening-compile-final.log` |
| `MIX_ENV=prod mix compile --warnings-as-errors` | Exit 0; `/tmp/ash-hardening-prod-final.log` |
| `git diff --check` | Sin errores |
| `mix hex.audit` antes del update | Advisory HIGH de Bandit 1.14.0; `/tmp/ash-hardening-audit-before.log` |
| `mix deps.update bandit` | Solo Bandit 1.14.0 → 1.14.1 en lock; `/tmp/ash-hardening-bandit-update.log` |
| `mix hex.audit` final | Sin paquetes retirados ni advisories conocidos; `/tmp/ash-hardening-audit-final.log` |
| `mix help credo` / `mix help dialyzer` | Tareas no disponibles; no se afirma haber ejecutado sus análisis |
| Consultas GitHub de solo lectura | No hay PR abierto ni runs para esta rama en las consultas realizadas. Los cambios locales nuevos no tienen CI remoto |

Se conservan los warnings preexistentes del recurso dinámico `SecurityRegression.LockEvent`
(Inspect consolidado y preparación del read). Los warnings nuevos de agrupación de
cláusulas se corrigieron; no se suprimieron warnings. La compilación normal y de
producción es estricta y pasa.

## Revisión adversarial posterior y fallos intermedios

La revisión no se limitó a pasar las primeras pruebas. Detectó y corrigió:

- Las acciones default de Ash se materializan después de que algunos transformers
  leen el DSL; la primera versión dejaba esas acciones sin protección. Los tests de
  consumidor fallaron y se añadió el tratamiento de ese default, aplicando las
  exclusiones después de `DefaultAccept` sin congelar atributos de otras extensiones.
- `force_change_attributes` antes de validar con la acción pública no bastaba para
  un create protegido. Se usa la misma acción ampliada solo para el contexto interno,
  con los valores presentes antes de validaciones, políticas e identidades.
- Tenant como struct y como string debe producir el mismo fence. La canonicalización
  se aplica antes de consultar y arbitrar, no solamente al escribir.
- Un tenant átomo `:_` entraba como patrón en ETS. Una regresión nueva falló con
  `invalid match specification`; la clave ahora codifica tenant/ID como datos
  literales y conserva una tupla de namespace que no colisiona con IDs globales.
- La clave automática de customer colisionaba entre entidades con el mismo ID.
  Otra regresión falló antes de introducir el namespace de recurso/tenant.

También se corrigieron fallos de fixtures/expectativas: accept explícito de un FK
que un recurso de prueba no tenía, pérdida inicial de opciones en un call privado,
respuesta mock sin status e intento de inspeccionar tokens mientras un fence estaba
ocupado. Un primer run tuvo 323 tests pasando pero cobertura 89,36 % porque el
transformer compartido estaba fuera del namespace habitual de transformers; se ubicó
con los demás transformers. La política de cobertura del proyecto, que excluye
transformers del DSL, no se cambió. Las pruebas verifican sus contratos a través de
recursos consumidores compilados; el porcentaje no demuestra exhaustividad del DSL.

## Compatibilidad, despliegue y límites

1. Los comodines dejan de aceptar estado de billing. Las acciones de mantenimiento
   deben nombrar campos explícitos y restringirlos con políticas. No se añadió un
   bypass privilegiado accesible mediante parámetros ordinarios.
2. Connect antes sin cuenta/modo configurados ahora se rechaza. Configurar la cuenta,
   el secreto del endpoint, el modo y las credenciales coherentemente. Los sobres v2
   con context se rechazan; no se implementó soporte thin-event.
3. Para IDs iguales entre tenants, un recurso de eventos multitenant debe tener
   unicidad por tenant. La fixture PostgreSQL utiliza `(tenant_id, event_id)` como PK.
   El consumidor debe generar/revisar su migración; `tenant:` no crea aislamiento
   sobre un recurso no multitenant. Context/schema tenancy no tuvo una integración
   PostgreSQL específica en esta ronda.
4. Drenar workers antiguos. Las claves de locks/ETS con tenant cambian y las claves
   automáticas de customer cambian incluso sin tenant. Para un create anterior sin
   persistir, una repetición con clave nueva puede crear un customer huérfano:
   reconciliar in-flight requests o suministrar su clave original explícita. No se
   sobrescribe una asociación existente gracias al CAS de F3. No se reconstruyen
   mappings históricos ni eventos sin tenant automáticamente.
5. Se mantienen las migraciones previas de tombstones/identidades. Esta ronda no
   aplica migraciones de producción ni cambia la versión del paquete.
6. El guard de commit, el rechazo de transacciones externas/pools distintos y los
   row locks persistentes de P1–P3 permanecen. No se promete transacción distribuida,
   exactly-once externo, pool ilimitado, ni aislamiento distribuido para ETS/memoria.
   Los consumidores raw deben proporcionar IDs no vacíos y usar `with_lease`; el
   shortcut legacy para ID nil no es una garantía de ejecución segura.
7. Una cuenta o modo por tenant/recurso sigue siendo una condición del modelo. No
   se añaden columnas de account/livemode a cada customer/subscription ni un router
   multi-account automático. Una mala asociación secret/API key/tenant, APIs expuestas
   con IDs de otro usuario, providers personalizados que verifican mal, defaults de
   acciones que conceden acceso y tareas externas sin idempotencia siguen siendo
   responsabilidades del consumidor.
8. No se hicieron operaciones de Stripe real, prueba HTTP/2 de explotación de Bandit,
   failover, partitions, load tests de producción ni una matriz heterogénea de OTP.
   La auditoría Hex limpia significa ausencia de advisories conocidos en ese lock,
   no ausencia demostrada de todas las vulnerabilidades.

## Recomendación de merge y release

La implementación local supera las regresiones previas y las nuevas y no deja un
bloqueo conocido en el flujo probado de PostgreSQL con un pool primario, tenant
explícito y scope fijo. **La aprobación para merge es condicional, no automática:**

1. Revisar y aceptar los cambios de contrato de inputs, Connect e idempotency keys.
2. Incorporar estos cambios locales a la rama solo con autorización del usuario y
   ejecutar la matriz CI sobre ese commit exacto. Hoy la rama publicada conserva
   `5beb81f`; no hay un PR/run nuevo que valide esta ronda.
3. Revisar migraciones y plan de drenaje/reintentos de los consumidores pertinentes.
4. Elegir la versión/release y comunicar los cambios de compatibilidad antes de
   publicar. No se creó release, no se cambió versión y no se fusionó main.

Con CI verde y esas decisiones revisadas, recomiendo fusionar las correcciones;
no recomiendo un release de producción sin el plan de compatibilidad y los contratos
externos indicados. No es necesario reescribir los componentes de billing para
resolver los hallazgos demostrados en esta ronda.

## Inventario del diff

- Producción: `lib/ash_billing.ex`, `deduplication.ex`, `providers/stripe.ex`,
  `resource.ex`, `subscription.ex`, sus transformers de atributos,
  `webhook_sync.ex` y el nuevo `transformers/protect_billing_attributes.ex`.
- Tests: nuevo `test/ash_billing/final_hardening_test.exs` y
  `test/support/hardening_support.ex`; aceptaciones explícitas de fixtures en
  `resources.ex`, `postgres_support.ex`, `webhook_transaction_support.ex`.
- Dependencias: únicamente Bandit en `mix.lock`; sin cambios de requisitos en mix.exs.
- Documentación: Unreleased en CHANGELOG, README, contrato de webhooks y referencias
  de actualización en los dos informes históricos, más este informe.
