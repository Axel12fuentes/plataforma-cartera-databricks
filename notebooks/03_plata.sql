-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 03 · Plata
-- MAGIC
-- MAGIC Tipar, validar y deduplicar. Lo que no pasa las reglas va a
-- MAGIC **cuarentena**, no a la basura: descartar pierde la evidencia de que
-- MAGIC entro y por que se fue.

-- COMMAND ----------

CREATE OR REPLACE TABLE dev.plata.cuotas AS
SELECT
  CAST(id_credito        AS BIGINT)        AS id_credito,
  CAST(nro_cuota         AS INT)           AS nro_cuota,
  CAST(fecha_vencimiento AS DATE)          AS fecha_vencimiento,
  CAST(monto_cuota       AS DECIMAL(12,2)) AS monto_cuota,
  CAST(saldo_capital     AS DECIMAL(12,2)) AS saldo_capital,
  moneda, id_cliente, id_asesor,
  TRIM(oficina) AS oficina, TRIM(region) AS region, producto,
  current_timestamp() AS _procesado_en
FROM dev.bronce.cuotas;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Pagos
-- MAGIC
-- MAGIC Tres cosas, en orden:
-- MAGIC
-- MAGIC 1. **`TRY_CAST` y no `CAST`.** Una fecha vacia con `CAST` hace fallar la
-- MAGIC    consulta entera. `TRY_CAST` devuelve nulo y nosotros decidimos.
-- MAGIC 2. **Filtrar** lo invalido.
-- MAGIC 3. **Deduplicar por llave de negocio**, no por `id_pago`: el reintento
-- MAGIC    del canal genera un id distinto para el mismo pago.

-- COMMAND ----------

CREATE OR REPLACE TABLE dev.plata.pagos AS
WITH tipado AS (
  SELECT
    TRY_CAST(id_pago      AS BIGINT)        AS id_pago,
    TRY_CAST(id_credito   AS BIGINT)        AS id_credito,
    TRY_CAST(nro_cuota    AS INT)           AS nro_cuota,
    TRY_CAST(fecha_pago   AS DATE)          AS fecha_pago,
    TRY_CAST(monto_pagado AS DECIMAL(12,2)) AS monto_pagado,
    INITCAP(TRIM(canal_pago))               AS canal_pago,
    _archivo, _ingerido_en
  FROM dev.bronce.pagos
),
valido AS (
  SELECT * FROM tipado
  WHERE fecha_pago   IS NOT NULL
    AND monto_pagado >  0
    AND id_credito   IS NOT NULL
),
dedup AS (
  SELECT *, ROW_NUMBER() OVER (
      PARTITION BY id_credito, nro_cuota, fecha_pago, monto_pagado
      ORDER BY id_pago
    ) AS rn
  FROM valido
)
SELECT * EXCEPT (rn), current_timestamp() AS _procesado_en
FROM dedup WHERE rn = 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Cuarentena
-- MAGIC
-- MAGIC Manana alguien pregunta "y los pagos que faltan?". Esta tabla responde,
-- MAGIC con el motivo.

-- COMMAND ----------

CREATE OR REPLACE TABLE dev.plata.pagos_cuarentena AS
SELECT *,
  CASE
    WHEN TRY_CAST(fecha_pago   AS DATE) IS NULL       THEN 'fecha vacia o invalida'
    WHEN TRY_CAST(monto_pagado AS DECIMAL(12,2)) <= 0 THEN 'monto no positivo'
    ELSE 'otro'
  END AS motivo,
  current_timestamp() AS _detectado_en
FROM dev.bronce.pagos
WHERE TRY_CAST(fecha_pago AS DATE) IS NULL
   OR TRY_CAST(monto_pagado AS DECIMAL(12,2)) <= 0;

-- COMMAND ----------

SELECT 'bronce'      AS capa, count(*) AS filas FROM dev.bronce.pagos
UNION ALL SELECT 'plata',      count(*) FROM dev.plata.pagos
UNION ALL SELECT 'cuarentena', count(*) FROM dev.plata.pagos_cuarentena;

-- COMMAND ----------

SELECT motivo, count(*) FROM dev.plata.pagos_cuarentena GROUP BY 1;
