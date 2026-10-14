-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 06 · Rendimiento y mantenimiento
-- MAGIC
-- MAGIC Un pipeline que corre no es un pipeline sano. Este cuaderno mide tres
-- MAGIC cosas que se degradan solas con el tiempo:
-- MAGIC
-- MAGIC 1. **Archivos pequenos.** Cada corrida de Auto Loader escribe su tanda.
-- MAGIC    Treinta corridas dejan treinta archivos, y leer treinta archivos
-- MAGIC    chicos cuesta mas que leer uno grande.
-- MAGIC 2. **Datos desordenados.** Si siempre filtras por asesor pero las filas
-- MAGIC    de un asesor estan repartidas en todos los archivos, hay que abrirlos
-- MAGIC    todos.
-- MAGIC 3. **Historia acumulada.** Delta guarda las versiones viejas. Sirven
-- MAGIC    para volver atras, pero ocupan.
-- MAGIC
-- MAGIC Anota los numeros de cada paso: lo que importa es el antes y el despues.

-- COMMAND ----------

CREATE WIDGET TEXT catalogo DEFAULT "dev";

-- COMMAND ----------

USE CATALOG IDENTIFIER(:catalogo);

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 1 · El problema de los archivos pequenos
-- MAGIC
-- MAGIC `DESCRIBE DETAIL` es la radiografia de una tabla Delta. Mira
-- MAGIC **numFiles** y **sizeInBytes**: si divides, tienes el tamano promedio
-- MAGIC de archivo. Por debajo de unos 100 MB, el motor pasa mas tiempo
-- MAGIC abriendo archivos que leyendo datos.

-- COMMAND ----------

DESCRIBE DETAIL bronce.pagos;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC `OPTIMIZE` junta los archivos chicos en pocos grandes. No cambia ni un
-- MAGIC dato: reescribe la misma informacion mejor empaquetada.
-- MAGIC
-- MAGIC Deja una **version nueva** en el historial, asi que el `VACUUM` del
-- MAGIC paso 4 tiene mas que limpiar despues de un `OPTIMIZE`.

-- COMMAND ----------

OPTIMIZE bronce.pagos;

-- COMMAND ----------

DESCRIBE DETAIL bronce.pagos;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ⚑ **En el examen.** `OPTIMIZE` compacta. `VACUUM` borra archivos que ya
-- MAGIC nadie referencia. Son cosas distintas y suelen aparecer mezcladas en
-- MAGIC las opciones de respuesta.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2 · Ordenar por lo que se filtra
-- MAGIC
-- MAGIC Tres formas de agrupar datos, de la mas vieja a la que hay que usar hoy:
-- MAGIC
-- MAGIC | Tecnica | Como se declara | Cuando |
-- MAGIC |---|---|---|
-- MAGIC | **Particionado** | `PARTITIONED BY (col)` al crear | Columna de baja cardinalidad y tabla grande. Si eliges mal, produce miles de carpetas diminutas y **empeora** todo |
-- MAGIC | **Z-order** | `OPTIMIZE t ZORDER BY (col)` | Hay que repetirlo despues de cada carga |
-- MAGIC | **Liquid clustering** | `CLUSTER BY (col)` | **La respuesta por defecto hoy.** Se declara una vez, se mantiene solo, y se puede cambiar de columna sin reescribir la tabla |
-- MAGIC
-- MAGIC El criterio es siempre el mismo: **la columna por la que filtras**. En
-- MAGIC esta tabla, el asesor.

-- COMMAND ----------

ALTER TABLE plata.cuotas CLUSTER BY (id_asesor);

-- COMMAND ----------

OPTIMIZE plata.cuotas;

-- COMMAND ----------

-- Comparar con el DESCRIBE DETAIL de antes: menos archivos, y ahora cada uno
-- concentra pocos asesores en vez de un poco de todos.
DESCRIBE DETAIL plata.cuotas;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ⚠ **Trampa.** `CLUSTER BY` no reorganiza nada por si solo: deja la
-- MAGIC instruccion. Quien mueve los datos es el `OPTIMIZE` siguiente.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 3 · El historial
-- MAGIC
-- MAGIC Cada escritura deja una version. Por eso existe el viaje en el tiempo, y
-- MAGIC por eso el almacenamiento crece aunque la tabla tenga las mismas filas.

-- COMMAND ----------

DESCRIBE HISTORY bronce.pagos;

-- COMMAND ----------

-- Leer la tabla como estaba hace dos versiones. Esto es lo que te salva
-- cuando alguien corre un UPDATE sin WHERE.
SELECT count(*) FROM bronce.pagos VERSION AS OF 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 4 · `VACUUM`
-- MAGIC
-- MAGIC Borra los archivos que ya ninguna version vigente usa. **Es
-- MAGIC irreversible**: despues de un `VACUUM` ya no puedes viajar mas atras
-- MAGIC que el periodo que dejaste.
-- MAGIC
-- MAGIC El valor por omision son **168 horas (7 dias)** y Databricks no te deja
-- MAGIC bajarlo sin desactivar una proteccion a proposito. La razon no es
-- MAGIC conservadurismo: un flujo de larga duracion puede seguir leyendo
-- MAGIC archivos que ya no aparecen en la ultima version, y borrarlos lo rompe.
-- MAGIC
-- MAGIC `DRY RUN` lista lo que borraria, sin borrar. Siempre primero.

-- COMMAND ----------

VACUUM bronce.pagos DRY RUN;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ⚑ **En el examen.** Si la pregunta dice "recuperar espacio ya mismo" y
-- MAGIC la opcion es `VACUUM ... RETAIN 0 HOURS`, la respuesta correcta casi
-- MAGIC siempre incluye que **se pierde el viaje en el tiempo** y que hay que
-- MAGIC desactivar la comprobacion de retencion.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 5 · Leer el plan antes de culpar al cluster
-- MAGIC
-- MAGIC `EXPLAIN FORMATTED` muestra como piensa ejecutar la consulta. Lo que hay
-- MAGIC que buscar:
-- MAGIC
-- MAGIC | En el plan | Que significa |
-- MAGIC |---|---|
-- MAGIC | `BroadcastHashJoin` | La tabla chica viaja entera a cada nodo. **Esto es lo que quieres** |
-- MAGIC | `SortMergeJoin` | Ambas tablas se barajan por la red. Caro |
-- MAGIC | `Exchange` | Ahi hay un **shuffle**: datos cruzando la red |
-- MAGIC | `PhotonScan` | Photon esta actuando |
-- MAGIC | `AQEShuffleRead` | La ejecucion adaptativa corrigio el plan a mitad de camino |

-- COMMAND ----------

EXPLAIN FORMATTED
SELECT c.id_asesor, count(*) AS cuotas_vencidas
FROM plata.cuotas c
LEFT ANTI JOIN plata.pagos p
  ON p.id_credito = c.id_credito AND p.nro_cuota = c.nro_cuota
WHERE c.fecha_vencimiento <= current_date()
GROUP BY c.id_asesor;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 6 · Diagnostico en la interfaz de Spark
-- MAGIC
-- MAGIC Se llega desde la celda ejecutada: **Spark Jobs** → el job → la etapa
-- MAGIC mas lenta. O desde el trabajo: la corrida → la tarea → **Spark UI**.
-- MAGIC
-- MAGIC Tres sintomas, y que hacer con cada uno:
-- MAGIC
-- MAGIC | Sintoma en la etapa | Causa | Que se hace |
-- MAGIC |---|---|---|
-- MAGIC | Una tarea tarda muchisimo mas que la mediana | **Sesgo**: una llave concentra las filas | Dejar que AQE la divida, o separar esa llave. Si es un `null` masivo, filtrarlo antes |
-- MAGIC | Columna **Spill (disk)** con valores | **Derrame**: no cabe en memoria | Menos datos por tarea, o mas memoria. Casi siempre viene de un shuffle mal dimensionado |
-- MAGIC | **Shuffle Read** enorme frente al tamano de la tabla | Se esta barajando mas de lo necesario | Filtrar antes del join; buscar que el join chico sea broadcast |
-- MAGIC | Muchas tareas de duracion ridicula | **Archivos pequenos** | `OPTIMIZE`, lo del paso 1 |
-- MAGIC
-- MAGIC ⚠ **Lo importante, y lo que casi nadie dice:** con datos de este tamano
-- MAGIC no vas a ver ninguno de estos sintomas. Lo que se practica aqui es
-- MAGIC **donde mirar y en que orden**, para que el dia que una etapa tarde
-- MAGIC cuarenta minutos sepas si el problema es sesgo, derrame o archivos, en
-- MAGIC vez de pedir un cluster mas grande.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Para anotar
-- MAGIC
-- MAGIC | Medicion | Antes | Despues |
-- MAGIC |---|---|---|
-- MAGIC | `bronce.pagos` · numFiles | | |
-- MAGIC | `bronce.pagos` · sizeInBytes | | |
-- MAGIC | `plata.cuotas` · numFiles | | |
-- MAGIC | Versiones en el historial | | |
-- MAGIC
-- MAGIC ☐ Lo construi ☐ Lo entendi ☐ Lo repeti solo
