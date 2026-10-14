# Git y Asset Bundles

Hasta aquí el pipeline funcionaba, pero vivía **dentro del workspace**: los
cuadernos escritos en la interfaz, el trabajo armado a clics, el catálogo
`dev` escrito a mano en cada consulta.

Eso tiene tres problemas que no se ven hasta que duelen:

1. Si borran el workspace, se borra el proyecto.
2. Nadie sabe quién cambió qué, ni cómo volver atrás.
3. No hay forma de llevarlo a producción salvo repetir los clics y rezar.

Esta etapa los cierra.

---

## 1 · Carpeta Git

Una **carpeta Git** es una carpeta del workspace que *es* un clon del
repositorio. Se edita el cuaderno en Databricks y se le hace commit ahí mismo.

Se conectó con la **aplicación de GitHub**, no con un token personal: no
expira ni hay que rotarla. Como el repo es privado, hay que darle acceso
explícito desde GitHub a ese repositorio.

---

## 2 · El catálogo deja de estar en el código

Era el agujero de fondo. El pipeline solo sabía vivir en un catálogo.

**Antes**

```sql
CREATE OR REPLACE TABLE dev.plata.cuotas AS SELECT ... FROM dev.bronce.cuotas;
```

**Ahora**

```sql
CREATE WIDGET TEXT catalogo DEFAULT "dev";
USE CATALOG IDENTIFIER(:catalogo);

CREATE OR REPLACE TABLE plata.cuotas AS SELECT ... FROM bronce.cuotas;
```

El trabajo pasa `catalogo` como parámetro y el cuaderno lo recibe como widget.
En el de Python es lo mismo, con `spark.sql(f"USE CATALOG {catalogo}")`, que
vale también para las celdas `%sql` de abajo.

De paso, en `04_oro.sql` la fecha de corte dejó de estar clavada en
`2026-10-13` y también es un widget.

> **Esta es la respuesta a "¿cómo promueves a producción?".** No se promueve
> código distinto: se promueve el mismo código con otra variable. Una rama
> `produccion` con el SQL editado a mano es la respuesta equivocada.

---

## 3 · El bundle

```
databricks.yml              el proyecto y sus destinos
resources/cartera_job.yml   el trabajo, entero
```

Todo lo que se había configurado a clics —las tres tareas, su orden, los
reintentos, el disparador por llegada de archivo, los umbrales de duración,
los avisos— pasa a ser texto versionado. Si mañana alguien lo cambia desde la
pantalla, el siguiente `deploy` lo devuelve al archivo.

### Los dos destinos

| | `dev` | `prod` |
|---|---|---|
| `catalogo` | `dev` | `prod` |
| Nombre del trabajo | `[dev babydog2396] cartera_…` | `cartera_medallon_diario` |
| Disparador al desplegar | **en pausa** | activo |
| Carpeta del bundle | `/Workspace/Users/…` | `/Workspace/Shared/…` |

La pausa **no está en el YAML**: la pone `mode: development` por su cuenta. Es
la red de seguridad del desarrollo: desplegar cien veces mientras pruebas no
dispara ni una corrida ni un centavo.

### Los comandos

```bash
databricks bundle validate -t dev     # revisa el YAML
databricks bundle deploy   -t dev     # crea o actualiza
databricks bundle run cartera_medallon_diario -t dev
databricks bundle destroy  -t dev     # lo borra todo
```

---

## 4 · Levantar `prod` desde cero

Crear el segundo catálogo destapó la cadena completa de almacenamiento de
Unity Catalog, que con `dev` había quedado resuelta por la interfaz sin que se
viera.

`CREATE CATALOG prod` falla —igual desde SQL que desde la CLI— porque el
metastore no tiene almacenamiento raíz y `dev` ya ocupaba la carpeta
disponible. **Dos catálogos no pueden compartir la misma ubicación
gestionada.**

La cadena, en orden:

| Paso | Objeto | Para qué |
|---|---|---|
| 1 | **Credencial de almacenamiento** `dbw_axel_dp750` | La identidad con la que Databricks entra a la cuenta de ADLS. Ya existía: la crea el workspace |
| 2 | **Catálogo** `prod` con `MANAGED LOCATION` | Dónde viven sus tablas gestionadas |

```bash
databricks catalogs create prod \
  --storage-root "abfss://unity-catalog-storage@<cuenta>.dfs.core.windows.net/<id>/prod"
```

**La ruta importa, y no de forma evidente.** La credencial por defecto del
workspace está acotada al prefijo `.../<id>`. Un catálogo creado fuera de ese
prefijo se registra sin error, acepta archivos copiados, y recién falla cuando
Spark intenta escribir una tabla. Está contado entero en el **error 9** del
[cuaderno de errores](01-cuaderno-de-errores.md).

Unity Catalog **sí** permite que la ubicación gestionada de un catálogo
cuelgue de la ruta de otro, mientras no sea exactamente la misma. Lo que no
permite es compartirla.

Después, esquemas, volúmenes, y los archivos copiados de un entorno al otro
sin pasar por el PC:

```bash
databricks fs cp -r dbfs:/Volumes/dev/bronce/landing dbfs:/Volumes/prod/bronce/landing
```

> **Los checkpoints no se copian.** Son el control de qué archivos ya leyó
> Auto Loader. Copiarlos haría que `prod` diera por procesado todo lo que
> procesó `dev`, y la tabla bronce de producción nacería vacía.

---

## 5 · Lo que queda mal a propósito

Al desplegar `prod` la CLI avisa:

> *the bundle root path `/Workspace/Shared/.bundle/…` is writable by all
> workspace users*

Es cierto. Producción se puso en `/Shared` porque **no debe colgar de la
carpeta personal de nadie**: si esa persona se va, se va el pipeline. Pero
`/Shared` lo puede escribir cualquiera del workspace.

En una organización esto se resuelve desplegando `prod` con un **service
principal**, no con un usuario, y restringiendo los permisos de esa carpeta.
Aquí hay un solo usuario, así que queda anotado como la diferencia entre este
laboratorio y un entorno real, no tapado.

---

## Resultado

| | |
|---|---|
| Corrida en `dev` | 1 min 57 s, tres tareas en verde |
| Corrida en `prod` | 1 min 55 s, tres tareas en verde |
| Tablas creadas en `prod` | 7, en los tres esquemas |
| Diferencia de código entre ambos | **ninguna** |
| Diferencia de configuración | el valor de **una** variable |

Levantar producción desde cero —catálogo, esquemas, volúmenes, datos, trabajo
y corrida— tomó menos de diez minutos, y ni una línea de SQL se editó a mano.
