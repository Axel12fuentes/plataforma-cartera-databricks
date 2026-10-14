# Orquestación y gobierno

Los cuadernos corren solos y la tabla final se defiende sola. Esto es lo que
se configuró y por qué.

---

## El trabajo: `cartera_medallon_diario`

Tres tareas encadenadas sobre cómputo **serverless**:

```
bronce  ──▶  plata  ──▶  oro
```

La dependencia no es decorativa. Sin ella las tres arrancan a la vez y la
capa plata lee una tabla bronce que todavía se está escribiendo: el trabajo
termina "exitoso" con datos de ayer.

| Qué | Cómo quedó | Por qué |
|---|---|---|
| Cómputo | Serverless | Arranca en segundos y se apaga solo. No hay cluster que olvidar encendido |
| Disparador | **Llegada de archivo** en `/Volumes/dev/bronce/landing/` | El pipeline no corre a una hora fija: corre cuando hay algo que procesar |
| Espaciado | Mínimo 5 min entre disparos, 1 min tras el último cambio | Si el proveedor sube 30 archivos seguidos, se procesan en una corrida, no en treinta |
| Reintentos | 3, con 5 min de espera | La mayoría de fallos de nube son transitorios |
| Aviso | Correo al fallar | Un pipeline que falla en silencio es peor que uno que no existe |
| Umbrales | Advertencia a 15 min, corte a 45 | Sin corte, una consulta colgada factura toda la noche |
| Concurrencia | Máximo 1, con cola | Dos corridas simultáneas sobre la misma tabla se pisan |
| Calidad de datos | Activada en `plata` y `oro` | En bronce no: es copia cruda y el monitoreo cuesta cómputo |

### El disparador por llegada de archivo

Es la diferencia entre un pipeline y un cron. Un cron a las 2 a.m. corre
aunque no haya llegado nada —y paga por ello—, y no corre si el archivo llega
a las 2:10.

Databricks revisa la carpeta cada cierto tiempo y dispara solo cuando aparece
algo nuevo. Queda pausado si no hay movimiento, y en pausa no cuesta.

---

## Permisos sobre la tabla final

La tabla `dev.oro.cartera_mora` es una sola y la consultan tres públicos
distintos. La solución ingenua es una vista por asesor: quince objetos que
mantener, y una alta de personal obliga a tocar el pipeline.

Unity Catalog lo resuelve con dos funciones:

| Mecanismo | Objeto | Efecto |
|---|---|---|
| **Filtro de fila** | `dev.oro.filtro_asesor` | El asesor ve solo sus créditos. `gerencia` ve todo |
| **Máscara de columna** | `dev.oro.enmascarar_monto` | `saldo_capital` sale en nulo si no eres de `riesgos` |

Las dos se apoyan en `current_user()` y `is_account_group_member()`: el motor
las evalúa en cada consulta, con cualquier herramienta, y el usuario no puede
rodearlas escribiendo otro SQL.

**La comprobación.** Con un usuario sin grupos, sobre una tabla de 15
asesores y 11 mil créditos:

| id_asesor | créditos | vencido | saldo |
|---|---|---|---|
| A-003 | 787 | 3 756 329.52 | *null* |

Una fila, y el saldo oculto. La consulta no cambió.

> **Al depurar, quítalos.** Con el filtro puesto tus propias verificaciones
> ven solo tu recorte, y parece que la carga falló:
> ```sql
> ALTER TABLE dev.oro.cartera_mora DROP ROW FILTER;
> ALTER TABLE dev.oro.cartera_mora ALTER COLUMN saldo_capital DROP MASK;
> ```

---

## Linaje

No se configura: se registra solo con cada ejecución. En `cartera_mora` →
pestaña **Linaje** aparecen las tablas de las que nace (`plata.pagos`,
`plata.cuotas`), la que nace de ella (`mora_por_oficina`), y el cuaderno y el
trabajo que la escribieron.

La lista muestra los vecinos directos. **Ver gráfico de linaje** muestra la
cadena completa desde el volumen `landing`.

Es la respuesta a la pregunta que siempre llega: *"este número, ¿de dónde
sale?"*.
