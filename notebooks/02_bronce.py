# Databricks notebook source
# MAGIC %md
# MAGIC # 02 · Bronce
# MAGIC
# MAGIC Copia fiel del origen, con columnas tecnicas de auditoria. Aqui no se
# MAGIC aplica **ninguna** regla de negocio: si el proveedor manda basura,
# MAGIC queremos verla, no que la carga falle.
# MAGIC
# MAGIC Dos patrones en el mismo cuaderno:
# MAGIC - **cuotas**: lote, carga unica
# MAGIC - **pagos**: Auto Loader, incremental

# COMMAND ----------

from pyspark.sql.functions import current_timestamp, col

# COMMAND ----------

# MAGIC %md
# MAGIC ## El catalogo es un parametro
# MAGIC
# MAGIC Nada en el codigo dice `dev`. El catalogo llega desde afuera: el mismo
# MAGIC cuaderno corre sobre `dev` al desarrollar y sobre `prod` al promover.
# MAGIC Esa es **toda** la diferencia entre los dos entornos.

# COMMAND ----------

dbutils.widgets.text("catalogo", "dev")
catalogo = dbutils.widgets.get("catalogo")

# Fijar el catalogo de la sesion vale tambien para las celdas %sql de abajo.
spark.sql(f"USE CATALOG {catalogo}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Cuotas · el cronograma se entrega una vez

# COMMAND ----------

cuotas = (spark.read
    .option("header", "true")
    .option("inferSchema", "true")
    .csv(f"/Volumes/{catalogo}/bronce/landing/cuotas.csv")
    .withColumn("_ingerido_en", current_timestamp())
    .withColumn("_archivo", col("_metadata.file_path")))

cuotas.write.mode("overwrite").saveAsTable("bronce.cuotas")
print(f"{cuotas.count():,} cuotas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Pagos · Auto Loader
# MAGIC
# MAGIC | Opcion | Que hace | Si falta |
# MAGIC |---|---|---|
# MAGIC | `cloudFiles.schemaLocation` | Guarda el esquema y que archivos ya proceso | **No hay incremental** |
# MAGIC | `schemaEvolutionMode = rescue` | Columna inesperada va a `_rescued_data` | Usa `addNewColumns`, que **detiene el flujo** |
# MAGIC | `pathGlobFilter` | Solo lee los que calzan | Intentaria leer `cuotas.csv` |
# MAGIC | `trigger(availableNow=True)` | Procesa lo pendiente **y se apaga** | Se queda encendido cobrando |

# COMMAND ----------

ruta = f"/Volumes/{catalogo}/bronce/landing/"
ckpt = f"/Volumes/{catalogo}/bronce/checkpoints/pagos/"

pagos = (spark.readStream
    .format("cloudFiles")
    .option("cloudFiles.format", "csv")
    .option("cloudFiles.schemaLocation", ckpt)
    .option("cloudFiles.schemaEvolutionMode", "rescue")
    .option("pathGlobFilter", "pagos_*.csv")
    .option("header", "true")
    .load(ruta)
    .withColumn("_ingerido_en", current_timestamp())
    .withColumn("_archivo", col("_metadata.file_path")))

# COMMAND ----------

# writeStream es ASINCRONO: arranca el flujo y devuelve el control de
# inmediato. Sin awaitTermination la celda siguiente lee datos viejos, y en un
# job la tarea termina "exitosa" con el flujo a medias.
q = (pagos.writeStream
    .option("checkpointLocation", ckpt)
    .trigger(availableNow=True)
    .toTable("bronce.pagos"))

q.awaitTermination()
print("filas leidas en esta corrida:",
      q.lastProgress["sources"][0]["numInputRows"] if q.lastProgress else 0)

# COMMAND ----------

# MAGIC %md
# MAGIC ## Comprobacion
# MAGIC
# MAGIC Cada corrida deja su propia tanda. Al subir archivos nuevos y volver a
# MAGIC ejecutar, solo se leen esos: los anteriores no se reprocesan.

# COMMAND ----------

# MAGIC %sql
# MAGIC SELECT date_trunc('second', _ingerido_en) AS tanda,
# MAGIC        count(*)                           AS filas,
# MAGIC        count(DISTINCT _archivo)           AS archivos
# MAGIC FROM bronce.pagos
# MAGIC GROUP BY 1 ORDER BY 1;
