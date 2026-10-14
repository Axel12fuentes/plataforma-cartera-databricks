-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 04 · Oro
-- MAGIC
-- MAGIC La pregunta del negocio: **cuanto de la cartera esta en mora y en que
-- MAGIC tramo**.
-- MAGIC
-- MAGIC Mora = cuota que ya vencio y **no tiene pago**. Eso en SQL es un
-- MAGIC `LEFT ANTI JOIN`: devuelve las filas de la izquierda que no encuentran
-- MAGIC pareja. Mas directo que `NOT EXISTS` o un `LEFT JOIN ... WHERE null`.
-- MAGIC
-- MAGIC Los tramos 1-8, 9-30, 31-60, 61-90 y +90 dias son los que usa el
-- MAGIC sistema financiero peruano para clasificar cartera.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## El catalogo es un parametro
-- MAGIC
-- MAGIC Nada en el codigo dice `dev`. El catalogo llega desde afuera: el mismo
-- MAGIC cuaderno corre sobre `dev` al desarrollar y sobre `prod` al promover.
-- MAGIC Esa es **toda** la diferencia entre los dos entornos.

-- COMMAND ----------

CREATE WIDGET TEXT catalogo    DEFAULT "dev";
CREATE WIDGET TEXT fecha_corte DEFAULT "2026-10-13";

-- COMMAND ----------

USE CATALOG IDENTIFIER(:catalogo);

-- COMMAND ----------

CREATE OR REPLACE TABLE oro.cartera_mora AS
WITH vencidas AS (
  SELECT * FROM plata.cuotas
  WHERE fecha_vencimiento <= DATE(:fecha_corte)
),
pagadas AS (
  SELECT DISTINCT id_credito, nro_cuota FROM plata.pagos
),
impagas AS (
  SELECT v.*, DATEDIFF(DATE(:fecha_corte), v.fecha_vencimiento) AS dias_atraso
  FROM vencidas v
  LEFT ANTI JOIN pagadas p
    ON p.id_credito = v.id_credito AND p.nro_cuota = v.nro_cuota
)
SELECT
  id_credito, id_cliente, id_asesor, oficina, region, producto, moneda,
  count(*)           AS cuotas_impagas,
  max(dias_atraso)   AS dias_atraso,
  sum(monto_cuota)   AS monto_vencido,
  min(saldo_capital) AS saldo_capital,
  CASE
    WHEN max(dias_atraso) =  0 THEN '0 · vence hoy'
    WHEN max(dias_atraso) <=  8 THEN '1 · 1-8 dias'
    WHEN max(dias_atraso) <= 30 THEN '2 · 9-30 dias'
    WHEN max(dias_atraso) <= 60 THEN '3 · 31-60 dias'
    WHEN max(dias_atraso) <= 90 THEN '4 · 61-90 dias'
    ELSE                             '5 · mas de 90'
  END AS tramo_mora
FROM impagas
GROUP BY ALL;

-- COMMAND ----------

CREATE OR REPLACE TABLE oro.mora_por_oficina AS
SELECT region, oficina, tramo_mora,
       count(*)                   AS creditos,
       sum(monto_vencido)         AS monto_vencido,
       round(avg(dias_atraso), 1) AS dias_promedio
FROM oro.cartera_mora
GROUP BY ALL;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Control de sensatez
-- MAGIC
-- MAGIC Una cartera real de microfinanzas tiene entre 5% y 10% en mora. Si este
-- MAGIC numero sale muy por encima, el problema **no es la cartera: son los
-- MAGIC datos**. Paso una vez y el motivo esta en el cuaderno de errores.

-- COMMAND ----------

SELECT tramo_mora, count(*) AS creditos,
       round(sum(monto_vencido), 0) AS monto_vencido
FROM oro.cartera_mora
GROUP BY 1 ORDER BY 1;
