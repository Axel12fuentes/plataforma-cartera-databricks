-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 05 · Gobierno
-- MAGIC
-- MAGIC La tabla `cartera_mora` tiene la cartera de los 15 asesores. El negocio
-- MAGIC pide dos cosas sobre la **misma** tabla:
-- MAGIC
-- MAGIC 1. Cada asesor ve solo sus creditos.
-- MAGIC 2. El saldo de capital solo lo ve el area de riesgos.
-- MAGIC
-- MAGIC La salida facil es una tabla o una vista por asesor. Son 15 objetos que
-- MAGIC mantener, y cada alta o baja de personal obliga a tocar el pipeline.
-- MAGIC
-- MAGIC Unity Catalog lo resuelve con **filtro de fila** y **mascara de
-- MAGIC columna**: dos funciones que el motor aplica en cada consulta, sin
-- MAGIC duplicar datos y sin que el usuario pueda rodearlas.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 1 · A quien pertenece cada cartera
-- MAGIC
-- MAGIC El filtro necesita saber que asesor es quien consulta. Esa relacion es
-- MAGIC un dato, no codigo: va en una tabla que RR.HH. puede mantener.

-- COMMAND ----------

CREATE TABLE IF NOT EXISTS dev.oro.asignacion_asesor (
  correo    STRING,
  id_asesor STRING
);

INSERT INTO dev.oro.asignacion_asesor VALUES (current_user(), 'A-003');

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 2 · Filtro de fila
-- MAGIC
-- MAGIC La funcion recibe el valor de la columna sobre la que se aplica y
-- MAGIC devuelve `TRUE` si esa fila debe verse.
-- MAGIC
-- MAGIC `is_account_group_member('gerencia')` es la valvula de escape: sin ella
-- MAGIC nadie veria la cartera completa, ni el gerente ni el propio pipeline.

-- COMMAND ----------

CREATE OR REPLACE FUNCTION dev.oro.filtro_asesor(p_id_asesor STRING)
RETURN is_account_group_member('gerencia')
    OR EXISTS (SELECT 1 FROM dev.oro.asignacion_asesor a
               WHERE a.correo = current_user()
                 AND a.id_asesor = p_id_asesor);

ALTER TABLE dev.oro.cartera_mora
  SET ROW FILTER dev.oro.filtro_asesor ON (id_asesor);

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 3 · Mascara de columna
-- MAGIC
-- MAGIC Misma idea, un nivel mas abajo: la fila se ve, el valor no. La funcion
-- MAGIC recibe el valor original y devuelve lo que el usuario debe ver.

-- COMMAND ----------

CREATE OR REPLACE FUNCTION dev.oro.enmascarar_monto(monto DECIMAL(12,2))
RETURN CASE WHEN is_account_group_member('riesgos') THEN monto ELSE NULL END;

ALTER TABLE dev.oro.cartera_mora
  ALTER COLUMN saldo_capital SET MASK dev.oro.enmascarar_monto;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 4 · Comprobacion
-- MAGIC
-- MAGIC Con un usuario que no es de `gerencia` ni de `riesgos`, esta consulta
-- MAGIC sobre una tabla de 15 asesores devuelve **una sola fila** y el saldo en
-- MAGIC nulo. Ese es todo el control, y no hubo que cambiar la consulta.

-- COMMAND ----------

SELECT id_asesor,
       count(*)           AS creditos,
       sum(monto_vencido) AS vencido,
       sum(saldo_capital) AS saldo
FROM dev.oro.cartera_mora
GROUP BY 1 ORDER BY 1;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Para quitarlos
-- MAGIC
-- MAGIC Mientras el filtro este puesto, las consultas de verificacion tambien lo
-- MAGIC sufren: uno cree que la carga fallo cuando en realidad esta viendo su
-- MAGIC recorte.
-- MAGIC
-- MAGIC ```sql
-- MAGIC ALTER TABLE dev.oro.cartera_mora DROP ROW FILTER;
-- MAGIC ALTER TABLE dev.oro.cartera_mora ALTER COLUMN saldo_capital DROP MASK;
-- MAGIC ```

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## 5 · Lo que ya venia hecho
-- MAGIC
-- MAGIC **Linaje.** No se configura. Cada ejecucion lo registra sola: en
-- MAGIC `cartera_mora` → pestaña **Linaje** aparecen las tablas de las que nace,
-- MAGIC las que nacen de ella, y el cuaderno y el trabajo que la escribieron. La
-- MAGIC lista muestra los vecinos directos; **Ver grafico de linaje** muestra la
-- MAGIC cadena entera desde el volumen `landing`.
-- MAGIC
-- MAGIC **Auditoria.** Quien consulto que, en tablas del sistema:

-- COMMAND ----------

SELECT event_time, user_identity.email, action_name
FROM system.access.audit
WHERE event_date >= current_date() - 1
ORDER BY event_time DESC
LIMIT 20;
