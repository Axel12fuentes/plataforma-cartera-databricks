# Cuaderno de errores

Lo que falló mientras construía esto, por qué, y cómo lo resolví.

---

## 1 · `CREATE CATALOG` falla: el metastore no tiene almacenamiento

**Qué decía.**

```
AnalysisException: Metastore storage root URL does not exist.
Default Storage is enabled in your account. You can use the UI to create a new
catalog using Default Storage, or please provide a storage location for the
catalog (for example 'CREATE CATALOG myCatalog MANAGED LOCATION '<path>'').
```

**La causa.** Un catálogo necesita un lugar físico donde guardar sus tablas
gestionadas. En los workspaces nuevos de Azure Databricks el metastore ya no
trae almacenamiento raíz, así que cada catálogo tiene que declarar el suyo —
o apoyarse en el almacenamiento predeterminado.

**La corrección.** Crear el catálogo desde la interfaz, que resuelve el
almacenamiento por su cuenta. La alternativa es registrar una credencial de
almacenamiento y una ubicación externa sobre ADLS Gen2, que es trabajo del
Dominio 2 y tiene su propio laboratorio.

**Lo que aprendí.** Es la razón concreta por la que existe `MANAGED LOCATION`.
Cuando una pregunta de examen habla de **aislar físicamente los datos** de un
entorno o un dominio, la respuesta es darle al catálogo su propia ubicación
gestionada. Sin ella, el catálogo ni se crea.

---

## 2 · `writeStream` es asíncrono y la verificación mentía

**El síntoma.** Subí cinco archivos nuevos, volví a correr Auto Loader, y la
consulta de control seguía mostrando los mismos 1.742 registros de cinco
archivos. Parecía que la ingesta incremental no funcionaba.

**La causa.** `writeStream` **arranca el flujo y devuelve el control de
inmediato**. No espera a que termine. La celda siguiente se ejecutaba mientras
el flujo todavía estaba leyendo, y leía el estado anterior.

La primera vez no se notó porque pasaron varios minutos entre ejecutar y
verificar.

**La corrección.**

```python
q = (pagos.writeStream
    .option("checkpointLocation", ckpt)
    .trigger(availableNow=True)
    .toTable("dev.bronce.pagos"))

q.awaitTermination()      # esperar de verdad
```

**Por qué importa fuera del cuaderno.** En un job programado, la tarea termina
marcada como exitosa mientras el flujo sigue corriendo o ni siquiera empezó.
Es el mismo tipo de fallo silencioso que un `EXCEPTION` sin `RAISE`: algo que
parece terminado y no lo está.

---

## 3 · El 90% de la cartera en mora: el dato estaba mal, no la cartera

**El síntoma.** La primera corrida de la capa oro dio esto:

| Tramo | Créditos |
|---|---|
| Más de 90 días | 7.039 |
| 61-90 días | 1.412 |
| 31-60 días | 1.389 |

**11.054 de 12.253 créditos en mora: el 90%.** Una cartera real de
microfinanzas tiene entre 5% y 10%.

**La causa.** El generador escribía solo los últimos 30 días de pagos, pero el
cronograma de cuotas abarcaba de febrero a octubre. Todo lo cobrado fuera de
esa ventana no existía en la tabla, y el `LEFT ANTI JOIN` lo contaba como
impago.

A eso se sumaba una tasa de impago del 6% **por cuota**. Con ocho cuotas
vencidas en promedio eso produce casi un 40% de créditos con alguna cuota
impaga, aun con los datos completos.

**La corrección.** Dos cambios en el generador:

1. Un archivo `pagos_historico.csv` con todo lo anterior a la ventana de 30
   días. Así se carga la historia en producción: de golpe, y después los
   incrementos diarios.
2. Impago por cuota del 6% al **1,5%**, que deja cerca del 11% de créditos con
   alguna cuota impaga.

**Lo que aprendí, y es lo importante.** La capa oro detectó un problema de las
capas de abajo. Para eso sirve: **si el número de negocio es absurdo, algo
aguas arriba está roto**. Un pipeline que corre sin errores no es un pipeline
correcto.

Por eso el cuaderno `04_oro.sql` termina con un control de sensatez explícito.

---

## 4 · Dos esquemas distintos en la misma carpeta de aterrizaje

`cuotas.csv` y `pagos_DDMMAAAA.csv` quedaron juntos en `landing`, y Auto Loader
lee **toda** la carpeta. Al tener columnas distintas, la ingesta habría
mezclado dos esquemas.

Se resolvió con `pathGlobFilter`:

```python
.option("pathGlobFilter", "pagos_*.csv")
```

Funciona, pero es un parche. El diseño correcto es una subcarpeta por origen:
`landing/pagos/` y `landing/cuotas/`. Queda anotado para la siguiente versión.

---

## 5 · El disparador quedó en pausa y el trabajo nunca corrió

**El síntoma.** Creé el disparador por llegada de archivo, le di guardar, y el
trabajo no se ejecutaba al subir archivos nuevos. Todo se veía bien
configurado.

**La causa.** Databricks crea el disparador por llegada de archivo **en pausa**.
Hay que darle **Reanudar** de forma explícita. La pantalla lo muestra, pero en
letra pequeña junto al nombre del disparador.

**Por qué no es un detalle.** Es exactamente el modo de fallo contra el que
sirve la orquestación: nada da error, no hay alerta que disparar —porque la
alerta solo salta si una corrida falla, y aquí no hubo ninguna corrida— y los
datos simplemente dejan de actualizarse. La única señal es mirar el historial
de ejecuciones y ver que está vacío.

**Lo que aprendí.** Después de configurar un disparador, la verificación no es
leer la configuración: es **subir un archivo y comprobar que apareció una
ejecución**.

---

## 6 · El filtro de fila me mentía en mis propias consultas

Puesto el filtro sobre `cartera_mora`, la consulta de control devolvía 787
créditos de un solo asesor. Parecía que la carga había perdido datos.

No: el filtro también se aplica a quien lo creó. Estaba viendo mi recorte.

```sql
ALTER TABLE dev.oro.cartera_mora DROP ROW FILTER;
ALTER TABLE dev.oro.cartera_mora ALTER COLUMN saldo_capital DROP MASK;
```

Es la contracara de que la regla viva en el motor: no hay forma de rodearla
escribiendo otro SQL —ni siquiera para uno mismo—, y eso es justamente lo que
la hace confiable.

---

## 7 · `databricks auth login` se fue a la puerta equivocada

**El síntoma.** Al autenticar la CLI, nunca preguntó por el workspace: saltó
del nombre del perfil directo a `Opening login.databricks.com in your
browser...`. El navegador ofrecía elegir entre cuentas de Databricks en AWS y
una Free Edition. Ninguna servía.

**La causa.** Sin `--host`, la CLI asume que quieres entrar a la **consola de
cuenta de Databricks**. Eso existe en AWS y GCP. En Azure no: el workspace es
un recurso de Azure y la identidad la pone **Entra ID**, no Databricks.

**La corrección.**

```bash
databricks auth login \
  --host https://adb-<id>.<n>.azuredatabricks.net \
  --profile axel-dp750
```

Con `--host` va directo al `/oidc` del workspace, que redirige al login de
Microsoft. Comprobación: `databricks auth profiles` debe decir `Valid: YES`.

**Lo que aprendí.** Azure Databricks y Databricks en AWS no comparten
identidad. Es la misma razón por la que en Azure los permisos de workspace se
gestionan con grupos de Entra ID.

---

## 8 · El segundo catálogo no se podía crear

**El síntoma.** El mismo error del punto 1, pero esta vez también desde la
interfaz, que fue justamente lo que salvó la primera vez:

```
Metastore storage root URL does not exist.
```

**La causa.** Al crear `dev`, la interfaz le asignó sola la única carpeta
disponible —la raíz del almacenamiento del workspace— y se la quedó entera.
**Dos catálogos no pueden compartir la misma ubicación gestionada**, así que
`prod` se quedó sin dónde vivir y ya no había nada que la interfaz pudiera
resolver por su cuenta.

**La corrección.** Armar la cadena a mano, que es la del Dominio 2:

```bash
databricks external-locations create prod_storage \
  "abfss://unity-catalog-storage@<cuenta>.dfs.core.windows.net/prod" \
  dbw_axel_dp750          # la credencial del workspace, ya existente

databricks catalogs create prod \
  --storage-root "abfss://unity-catalog-storage@<cuenta>.dfs.core.windows.net/prod"
```

**Lo que aprendí (incompleto: ver el error 9).** `MANAGED LOCATION` no es un
detalle de configuración: es
lo que hace posible **aislar físicamente** un entorno de otro. Es exactamente
lo que pregunta el examen cuando habla de separar dominios o entornos, y el
motivo por el que un catálogo por entorno es mejor que un esquema por entorno:
los datos de `prod` quedan en otra carpeta, no solo bajo otro nombre.


---

## 9 · Tres comandos en verde y la credencial no llegaba

Este es el mejor error de todo el proyecto, por cómo se escondió.

**El síntoma.** Con `prod` recién montado, el trabajo falló en la primera
tarea:

```
[UNAUTHORIZED_ACCESS] PERMISSION_DENIED: The credential 'dbw_axel_dp750' is a
workspace default credential that is only allowed to access data in the
following paths:
'abfss://unity-catalog-storage@dbstorage....dfs.core.windows.net/7405618998096237'
```

**La causa.** La credencial por defecto del workspace está **acotada a una
ruta**. El catálogo `prod` se creó en `.../prod`, que queda fuera de ese
prefijo.

**Por qué no se vio antes.** Porque nada avisó:

| Paso | Resultado | Por qué mintió |
|---|---|---|
| Crear la ubicación externa | ✅ | Unity Catalog registra el objeto; no prueba la credencial contra la ruta |
| Crear el catálogo | ✅ | Hereda el permiso de la ubicación externa recién creada |
| Copiar 11 archivos con `fs cp` | ✅ | La API de archivos no usa la credencial de almacenamiento |
| Escribir una tabla desde Spark | ❌ | **Aquí sí** se usa la credencial, y recién aquí se descubre |

Tres comandos en verde antes del que importaba, y el error apareció dos pasos
después y en otro sitio.

**La corrección.** Poner el catálogo **dentro** del prefijo permitido:

```bash
databricks catalogs create prod   --storage-root "abfss://unity-catalog-storage@<cuenta>.dfs.core.windows.net/<id>/prod"
```

Y de paso quedó resuelta una duda: Unity Catalog **sí** permite que la
ubicación gestionada de un catálogo cuelgue de la ruta de otro, mientras no
sea exactamente la misma. Lo que no permite es compartirla.

**Lo que aprendí.** La credencial de almacenamiento no es un interruptor de
sí/no: tiene un **alcance de rutas**, y Unity Catalog no lo verifica al
registrar los objetos, solo al leer o escribir datos de verdad. Para
comprobar una ubicación externa antes de construir sobre ella está
**Probar conexión** en su pantalla, o sencillamente escribir una tabla de una
fila. Que los comandos de administración pasen no prueba nada sobre los datos.
