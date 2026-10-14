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
