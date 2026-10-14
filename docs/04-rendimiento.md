# Rendimiento y mantenimiento

Lo que se midió al correr `notebooks/06_rendimiento.sql` sobre el catálogo
`dev`, y qué se puede concluir de ello — que es menos de lo que parece.

---

## Lo medido

| Tabla | `numFiles` antes | `numFiles` después de `OPTIMIZE` |
|---|---|---|
| `bronce.pagos` | 2 | **1** |
| `plata.cuotas` | — | **1** |

`OPTIMIZE` hizo lo que promete: compactó. Y `plata.cuotas`, con sus 294 mil
filas, cabe entera en un solo archivo.

## Lo que estos números **no** demuestran

Nada sobre rendimiento. Pasar de 2 archivos a 1 no cambia el tiempo de ninguna
consulta, y con este volumen tampoco hay sesgo ni derrame que observar en la
interfaz de Spark.

Decirlo importa: un portafolio que presenta una mejora de 2 a 1 archivo como
una optimización está contando un cuento.

## Dónde sí importa

El problema de los archivos pequeños es **acumulativo**. Auto Loader escribe
una tanda por corrida:

| Tiempo de ingesta diaria | Archivos acumulados | Tras `OPTIMIZE` |
|---|---|---|
| 1 semana | ~7 | 1 |
| 6 meses | ~180 | 3 o 4 |
| 2 años | ~730 | una decena |

Leer 730 archivos chicos obliga a 730 aperturas antes de empezar a leer datos.
Ahí la diferencia deja de ser teórica, y es la razón por la que `OPTIMIZE`
—o liquid clustering, que lo mantiene solo— va programado, no a mano.

## Lo que sí quedó practicado

| Herramienta | Para qué |
|---|---|
| `DESCRIBE DETAIL` | La radiografía: `numFiles`, `sizeInBytes`. El tamaño promedio de archivo sale de dividir |
| `OPTIMIZE` | Compacta. No toca los datos |
| `CLUSTER BY` + `OPTIMIZE` | Agrupa por la columna que se filtra. El `CLUSTER BY` solo deja la instrucción; quien mueve los datos es el `OPTIMIZE` |
| `DESCRIBE HISTORY` · `VERSION AS OF` | El historial y el viaje en el tiempo |
| `VACUUM ... DRY RUN` | Lista lo que borraría. La retención de 7 días protege a los flujos de larga duración que siguen leyendo archivos viejos |
| `EXPLAIN FORMATTED` | `BroadcastHashJoin` bueno, `SortMergeJoin` caro, `Exchange` = shuffle |

Y la tabla de diagnóstico del Spark UI —tarea mucho más lenta que la mediana
es sesgo, `Spill (disk)` es derrame, `Shuffle Read` desproporcionado es
barajar de más, muchas tareas ridículamente cortas son archivos pequeños—
queda en el cuaderno para el día que una etapa tarde cuarenta minutos.

Eso es lo que se practicó: **dónde mirar y en qué orden**. No una mejora.
