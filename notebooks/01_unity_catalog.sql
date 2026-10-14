-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 01 · Unity Catalog
-- MAGIC
-- MAGIC Monta la jerarquia: catalogo, esquemas y volumenes.
-- MAGIC
-- MAGIC El catalogo `dev` se crea desde la interfaz (Catalogo -> Crear catalogo),
-- MAGIC no por SQL: en un metastore sin almacenamiento raiz, `CREATE CATALOG`
-- MAGIC falla pidiendo una ubicacion gestionada.

-- COMMAND ----------

SELECT current_metastore();

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Esquemas: una capa del medallon por esquema

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS dev.bronce COMMENT 'Crudo, tal cual llego';
CREATE SCHEMA IF NOT EXISTS dev.plata  COMMENT 'Limpio y validado';
CREATE SCHEMA IF NOT EXISTS dev.oro    COMMENT 'Agregado para consumo';

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Volumenes: carpetas gobernadas para lo que NO es tabla
-- MAGIC
-- MAGIC - `landing` guarda los `.csv` tal como llegan
-- MAGIC - `checkpoints` guarda el control de Auto Loader: que archivos ya leyo
-- MAGIC   y el esquema que infirio. **Sin el no hay carga incremental.**

-- COMMAND ----------

CREATE VOLUME IF NOT EXISTS dev.bronce.landing
  COMMENT 'Donde aterrizan los archivos de pagos de cada dia';

CREATE VOLUME IF NOT EXISTS dev.bronce.checkpoints
  COMMENT 'Puntos de control de Auto Loader';

-- COMMAND ----------

SHOW SCHEMAS IN dev;
SHOW VOLUMES IN dev.bronce;
