-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 01 · Unity Catalog
-- MAGIC
-- MAGIC Monta la jerarquia: catalogo, esquemas y volumenes.
-- MAGIC
-- MAGIC El catalogo se crea desde la interfaz (Catalogo -> Crear catalogo),
-- MAGIC no por SQL: en un metastore sin almacenamiento raiz, `CREATE CATALOG`
-- MAGIC falla pidiendo una ubicacion gestionada.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## El catalogo es un parametro
-- MAGIC
-- MAGIC Nada en el codigo dice `dev`. El catalogo llega desde afuera: el mismo
-- MAGIC cuaderno corre sobre `dev` al desarrollar y sobre `prod` al promover.
-- MAGIC Esa es **toda** la diferencia entre los dos entornos.

-- COMMAND ----------

CREATE WIDGET TEXT catalogo DEFAULT "dev";

-- COMMAND ----------

USE CATALOG IDENTIFIER(:catalogo);

-- COMMAND ----------

SELECT current_metastore();

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Esquemas: una capa del medallon por esquema

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS bronce COMMENT 'Crudo, tal cual llego';
CREATE SCHEMA IF NOT EXISTS plata  COMMENT 'Limpio y validado';
CREATE SCHEMA IF NOT EXISTS oro    COMMENT 'Agregado para consumo';

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Volumenes: carpetas gobernadas para lo que NO es tabla
-- MAGIC
-- MAGIC - `landing` guarda los `.csv` tal como llegan
-- MAGIC - `checkpoints` guarda el control de Auto Loader: que archivos ya leyo
-- MAGIC   y el esquema que infirio. **Sin el no hay carga incremental.**

-- COMMAND ----------

CREATE VOLUME IF NOT EXISTS bronce.landing
  COMMENT 'Donde aterrizan los archivos de pagos de cada dia';

CREATE VOLUME IF NOT EXISTS bronce.checkpoints
  COMMENT 'Puntos de control de Auto Loader';

-- COMMAND ----------

SHOW SCHEMAS;
SHOW VOLUMES IN bronce;
