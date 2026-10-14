# -*- coding: utf-8 -*-
"""Genera el cronograma de cuotas y los archivos diarios de pagos.

    python scripts/generar_pagos.py            # 30 dias de pagos
    python scripts/generar_pagos.py --dias 60
    python scripts/generar_pagos.py --nuevo-dia   # un archivo mas, para probar Auto Loader

Lee los desembolsos del Proyecto 1 (PostgreSQL local) y de cada credito
construye su cronograma a cuota fija. Luego simula los pagos: unos puntuales,
otros con atraso, y algunos que nunca llegan. Esos son los que generan mora.

Salida en datos/:
    cuotas.csv              el cronograma completo (carga unica)
    pagos_DDMMAAAA.csv      un archivo por dia (carga incremental)

A proposito se ensucian algunas filas: duplicados por reintento del canal,
espacios en los textos, montos en cero y una fecha vacia. La capa plata
tiene que limpiarlos.
"""
import argparse
import csv
import os
import random
from datetime import date, timedelta

import psycopg2

SEMILLA = 20261013
random.seed(SEMILLA)

SALIDA = 'datos'
HOY = date(2026, 10, 13)

CANALES = ['App', 'Agente', 'Agencia', 'Debito automatico', 'Yape']

# Como se comporta el pago de cada cuota vencida.
# Los ultimos dos tramos son los que forman la mora dura.
COMPORTAMIENTO = [
    ('puntual',      0.620, (-3, 0)),    # paga antes o el mismo dia
    ('atraso_leve',  0.200, (1, 8)),
    ('atraso_medio', 0.110, (9, 30)),
    ('atraso_alto',  0.040, (31, 60)),
    ('atraso_grave', 0.015, (61, 90)),
    ('impago',       0.015, None),       # no paga: queda en mora
]
# El impago es por CUOTA, no por credito. Con ~8 cuotas vencidas en
# promedio, un 1,5% por cuota deja alrededor del 11% de creditos con alguna
# cuota impaga: el orden de magnitud de una cartera real de microfinanzas.


def conectar():
    return psycopg2.connect(
        host=os.getenv('PGHOST', 'localhost'),
        port=os.getenv('PGPORT', '5433'),
        dbname=os.getenv('POSTGRES_DB', 'wh_creditos'),
        user=os.getenv('POSTGRES_USER'),
        password=os.getenv('POSTGRES_PASSWORD'),
    )


def cuota_fija(monto, tasa_anual, plazo):
    """Cuota de sistema frances. La tasa anual es efectiva, como en Peru."""
    i = (1 + float(tasa_anual) / 100) ** (1 / 12) - 1
    if i == 0:
        return round(float(monto) / plazo, 2)
    return round(float(monto) * i / (1 - (1 + i) ** -plazo), 2)


def sumar_meses(f, n):
    mes = f.month - 1 + n
    anio = f.year + mes // 12
    mes = mes % 12 + 1
    dia = min(f.day, [31, 29 if anio % 4 == 0 else 28, 31, 30, 31, 30,
                      31, 31, 30, 31, 30, 31][mes - 1])
    return date(anio, mes, dia)


def elegir_comportamiento():
    r, acc = random.random(), 0.0
    for nombre, p, rango in COMPORTAMIENTO:
        acc += p
        if r <= acc:
            return nombre, rango
    return 'puntual', (0, 0)


def leer_creditos(cur):
    cur.execute("""
        SELECT d.id_desembolso, c.id_lead, a.id_asesor, o.oficina, o.region,
               p.producto, t.fecha, d.monto, d.plazo_meses, d.tasa_anual, d.moneda
        FROM dw.fact_desembolso d
        JOIN dw.dim_tiempo   t ON t.sk_tiempo   = d.sk_tiempo
        JOIN dw.dim_cliente  c ON c.sk_cliente  = d.sk_cliente
        JOIN dw.dim_asesor   a ON a.sk_asesor   = d.sk_asesor
        JOIN dw.dim_oficina  o ON o.sk_oficina  = d.sk_oficina
        JOIN dw.dim_producto p ON p.sk_producto = d.sk_producto
        ORDER BY d.id_desembolso
    """)
    return cur.fetchall()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dias', type=int, default=30,
                    help='cuantos dias de pagos escribir (por omision 30)')
    ap.add_argument('--nuevo-dia', action='store_true',
                    help='escribe solo un archivo mas, para probar Auto Loader')
    args = ap.parse_args()

    os.makedirs(SALIDA, exist_ok=True)

    with conectar() as con, con.cursor() as cur:
        creditos = leer_creditos(cur)
    print(f'creditos leidos: {len(creditos):,}')

    cuotas, pagos = [], []
    id_pago = 0

    for (id_cred, id_cliente, id_asesor, oficina, region, producto,
         fecha_des, monto, plazo, tasa, moneda) in creditos:

        cuota = cuota_fija(monto, tasa, plazo)
        saldo = float(monto)

        for n in range(1, plazo + 1):
            vence = sumar_meses(fecha_des, n)
            saldo = max(0.0, round(saldo - cuota * 0.7, 2))

            cuotas.append({
                'id_credito': id_cred, 'nro_cuota': n,
                'fecha_vencimiento': vence.isoformat(),
                'monto_cuota': f'{cuota:.2f}', 'saldo_capital': f'{saldo:.2f}',
                'moneda': moneda, 'id_cliente': id_cliente,
                'id_asesor': id_asesor, 'oficina': oficina, 'region': region,
                'producto': producto,
            })

            if vence > HOY:          # todavia no vence: no puede haber pago
                continue

            _, rango = elegir_comportamiento()
            if rango is None:        # impago
                continue

            fecha_pago = vence + timedelta(days=random.randint(*rango))
            if fecha_pago > HOY:
                continue

            id_pago += 1
            pagos.append({
                'id_pago': id_pago, 'id_credito': id_cred, 'nro_cuota': n,
                'fecha_pago': fecha_pago.isoformat(),
                'monto_pagado': f'{cuota:.2f}',
                'canal_pago': random.choice(CANALES),
            })

            # --- suciedad deliberada, para que la capa plata tenga trabajo ---
            if random.random() < 0.012:          # reintento del canal: duplicado
                d = dict(pagos[-1]); d['id_pago'] = id_pago = id_pago + 1
                pagos.append(d)
            if random.random() < 0.008:          # espacios en el texto
                pagos[-1]['canal_pago'] = '  ' + pagos[-1]['canal_pago'] + ' '
            if random.random() < 0.004:          # monto en cero
                pagos[-1]['monto_pagado'] = '0.00'
            if random.random() < 0.003:          # fecha vacia
                pagos[-1]['fecha_pago'] = ''

    # ---------------------------------------------------------- cronograma
    ruta_cuotas = os.path.join(SALIDA, 'cuotas.csv')
    if not args.nuevo_dia:
        with open(ruta_cuotas, 'w', newline='', encoding='utf-8') as f:
            w = csv.DictWriter(f, fieldnames=list(cuotas[0].keys()))
            w.writeheader(); w.writerows(cuotas)
        print(f'cuotas.csv          {len(cuotas):>9,} filas')

    # ---------------------------------------------------- pagos por dia
    # Las filas sin fecha no pueden ir a un archivo diario: van al historico,
    # para que la capa plata tenga tambien ese caso que limpiar.
    sin_fecha = [p for p in pagos if not p['fecha_pago']]

    por_dia = {}
    for p in pagos:
        if p['fecha_pago']:
            por_dia.setdefault(p['fecha_pago'], []).append(p)

    dias = sorted(por_dia)
    if args.nuevo_dia:
        dias = dias[-1:]
    else:
        recientes = dias[-args.dias:]
        antiguos = dias[:-args.dias]
        # Un solo archivo con todo lo anterior a la ventana: asi se carga la
        # historia en produccion, de una vez, y despues van los incrementos.
        historico = [r for d in antiguos for r in por_dia[d]] + sin_fecha
        ruta_h = os.path.join(SALIDA, 'pagos_historico.csv')
        with open(ruta_h, 'w', newline='', encoding='utf-8') as fh:
            w = csv.DictWriter(fh, fieldnames=['id_pago', 'id_credito', 'nro_cuota',
                                               'fecha_pago', 'monto_pagado', 'canal_pago'])
            w.writeheader(); w.writerows(historico)
        print(f'pagos_historico.csv {len(historico):>9,} filas')
        dias = recientes

    total = 0
    for d in dias:
        f = date.fromisoformat(d)
        nombre = f'pagos_{f.strftime("%d%m%Y")}.csv'
        with open(os.path.join(SALIDA, nombre), 'w', newline='', encoding='utf-8') as fh:
            w = csv.DictWriter(fh, fieldnames=['id_pago', 'id_credito', 'nro_cuota',
                                               'fecha_pago', 'monto_pagado', 'canal_pago'])
            w.writeheader(); w.writerows(por_dia[d])
        total += len(por_dia[d])

    print(f'archivos de pagos   {len(dias):>9} dias · {total:,} filas')
    print(f'\nTodo en {os.path.abspath(SALIDA)}')


if __name__ == '__main__':
    main()
