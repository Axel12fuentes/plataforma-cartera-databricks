# Apagar todo y reconstruirlo desde cero

Este laboratorio cuesta dinero mientras exista. Este documento dice qué cobra
Azure, cómo apagarlo del todo, y cómo volver a levantarlo entero sin ayuda de
nadie.

Está escrito para leerse dentro de seis meses, cuando no te acuerdes de nada.

---

## 1 · Qué cuesta y qué no

| Recurso | Cobra cuando | Orden de magnitud |
|---|---|---|
| **Cómputo serverless** | Solo mientras una consulta o un job corre | Céntimos por corrida. Se apaga solo |
| **Workspace de Databricks** | Existir no cuesta | $0 |
| **NAT Gateway** | **Por hora, exista o no tráfico** | ~$0,045/h ≈ **$30/mes** |
| **Almacenamiento (ADLS)** | Por GB guardado | Céntimos con estos volúmenes |
| **Disparador por llegada de archivo** | Revisa la carpeta periódicamente | Muy poco, pero no cero |

**El NAT Gateway es el único que duele.** Lo crea Azure solo, dentro del grupo
de recursos administrado del workspace, cuando el workspace usa conectividad
segura de clúster. No se puede apagar: o está, o no está el workspace.

> Por eso la decisión no es "apagarlo por hoy": o lo dejas corriendo y pagas
> ~$30 al mes, o lo borras entero. Con este repo, borrarlo no pierde nada.

---

## 2 · Tres niveles de apagado

### Nivel 1 · Pausar (vuelves mañana)

Trabajos → `cartera_medallon_diario` → disparador → **Pausar**.

El de `dev` ya se pausa solo: lo hace `mode: development` del bundle.

Esto detiene las corridas automáticas. **No** detiene el NAT Gateway.

### Nivel 2 · Vaciar los datos (vuelves en semanas)

```bash
databricks bundle destroy -t dev
databricks bundle destroy -t prod
```

Borra los dos trabajos. Los catálogos se borran desde Catálogo → el catálogo →
⋮ → Eliminar, o:

```bash
databricks catalogs delete dev  --force
databricks catalogs delete prod --force
```

Sigue sin detener el NAT Gateway.

### Nivel 3 · Apagar de verdad (es lo que conviene)

Borrar el **workspace de Databricks**. Al borrarlo, Azure borra solo su grupo
de recursos administrado, y con él el NAT Gateway, la cuenta de
almacenamiento y todo lo demás.

Portal de Azure → busca `dbw-axel-dp750` → **Eliminar**.

---

## 3 · Lo del grupo de recursos

Hay **dos** grupos y conviene no confundirlos:

| Grupo | Qué tiene | Quién lo borra |
|---|---|---|
| El tuyo (donde creaste el workspace) | El recurso `dbw-axel-dp750` y lo que tú hayas puesto ahí | Tú |
| `databricks-rg-dbw-axel-dp750-…` | Lo que Azure creó solo: almacenamiento, red, **NAT Gateway**, Access Connector | **No lo toques**: se borra solo al borrar el workspace |

**Borrar tu grupo de recursos** es la vía más limpia y se lleva todo por
delante — pero antes **mira qué más hay dentro**. Si pusiste ahí otra cosa de
otro proyecto, se va también.

### Comprobación antes de borrar

Portal → Grupos de recursos → el tuyo → pestaña **Información general**.
Si solo ves el workspace de Databricks, bórralo entero sin miedo.

### Después de borrar

Portal → **Análisis de costos**, filtra por los últimos 7 días. Al día
siguiente la barra diaria debe estar en cero. Si no lo está, quedó algo vivo:
busca por tipo de recurso, no por nombre.

---

## 4 · Checklist de apagado total

```
☐ Pausar el disparador de prod          (por si el borrado tarda)
☐ git push de todo lo pendiente          (el repo es lo único que sobrevive)
☐ Confirmar que el repo tiene: notebooks/, resources/, databricks.yml, scripts/
☐ Mirar qué hay en el grupo de recursos
☐ Borrar el workspace (o el grupo entero)
☐ Al día siguiente: Análisis de costos en cero
```

---

## 5 · Reconstruirlo desde cero

Todo lo necesario está en este repositorio. Lo único que **no** está son los
datos, y es a propósito: se generan.

### Lo que necesitas antes de empezar

| Qué | Para qué |
|---|---|
| Docker Desktop corriendo | El Proyecto 1 vive en un PostgreSQL en contenedor |
| El repo del [Proyecto 1](https://github.com/Axel12fuentes/warehouse-dimensional-creditos) | De ahí salen los créditos que aquí se cobran |
| Una suscripción de Azure | Para el workspace |
| La CLI de Databricks | `winget install Databricks.DatabricksCLI` |

### Paso 1 · Levantar el Proyecto 1

```bash
cd warehouse-dimensional-creditos
docker compose up -d
```

Sin esto, el generador de datos no tiene de dónde leer. Es la dependencia que
más fácil se olvida.

### Paso 2 · Generar los datos

```bash
cd plataforma-cartera-databricks
python scripts/generar_pagos.py
```

Produce en `datos/`: `cuotas.csv`, `pagos_historico.csv` y 30 archivos diarios.
Semilla fija: la misma corrida genera siempre lo mismo.

### Paso 3 · Crear el workspace de Azure Databricks

Portal → Crear recurso → Azure Databricks. Región: la misma donde quieras el
metastore (aquí, East US 2). Anota la URL: `https://adb-<id>.<n>.azuredatabricks.net`.

### Paso 4 · Crear el catálogo `dev`

Catálogo → Crear catálogo → nombre `dev`, tipo Estándar, ubicación vacía.

Si falla con *Metastore storage root URL does not exist*, mira el **error 8**
del cuaderno: necesitas darle una ubicación gestionada explícita.

### Paso 5 · Autenticar la CLI

```bash
databricks auth login --host https://adb-<id>.<n>.azuredatabricks.net --profile <perfil>
databricks auth profiles        # debe decir Valid: YES
```

**Con `--host`.** Sin él se va a la consola de cuenta de Databricks, que en
Azure no es donde vive tu workspace (**error 7**).

### Paso 6 · Poner el host en el bundle

En `databricks.yml`, los dos destinos tienen la URL del workspace. Cámbiala
por la nueva.

### Paso 7 · Esquemas, volúmenes y archivos

```bash
databricks schemas create bronce dev
databricks schemas create plata  dev
databricks schemas create oro    dev
databricks volumes create dev bronce landing     MANAGED
databricks volumes create dev bronce checkpoints MANAGED
```

Los `.csv` se suben desde Catálogo → `dev` → `bronce` → `landing` →
**Cargar en este volumen**. O desde la CLI:

```bash
databricks fs cp -r datos dbfs:/Volumes/dev/bronce/landing
```

### Paso 8 · Desplegar y correr

```bash
databricks bundle validate -t dev
databricks bundle deploy   -t dev
databricks bundle run cartera_medallon_diario -t dev
```

Unos dos minutos. Al terminar existen las 7 tablas en los tres esquemas.

### Paso 9 · Gobierno (opcional)

Correr `notebooks/05_gobierno.sql`, cambiando `A-003` por el asesor que
quieras asignarte.

### Para levantar `prod`

Lo mismo con `-t prod`, más el catálogo `prod` con su propia ubicación
gestionada **dentro del prefijo permitido por la credencial** — es el
**error 9**, el que más cuesta descubrir solo.

---

## 6 · Qué sobrevive y qué no

| | |
|---|---|
| **Sobrevive** | El repositorio: cuadernos, bundle, generador, documentación |
| **Se regenera** | Los datos, con `scripts/generar_pagos.py` y su semilla fija |
| **Se pierde** | El historial de ejecuciones de los trabajos y las versiones Delta |

Nada de lo que se pierde hace falta. Esa es justamente la prueba de que el
proyecto está bien hecho: **si borrarlo todo no te asusta, es que el código
era la fuente de la verdad y no el workspace.**
