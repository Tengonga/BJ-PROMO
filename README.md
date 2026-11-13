# BlackJack Smashburger · Promo QR «Levanta tu carta»

Escaneas el QR del cartel → dejas tu email o móvil → te sale una carta con **burger o patatas** y un código único `BJ-XXXX-XXXX` → lo enseñas en caja → el personal lo canjea.

- Máximo **1000 tickets** (controlado en el servidor, no se puede saltar).
- **1 ticket por email o móvil.**
- Reparto exacto: **200 burgers / 800 patatas** (configurable), asignadas al azar.
- Cada código se canjea **una sola vez** y queda registrado en qué local y a qué hora.

## Archivos

| Archivo | Qué es |
|---|---|
| `index.html` | Página del cliente (a la que lleva el QR) |
| `canje.html` | Página del personal para validar y canjear tickets |
| `bases.html` | Plantilla de bases legales (rellena lo marcado en amarillo) |
| `config.js` | URL y clave pública de Supabase |
| `sql/schema.sql` | Base de datos y lógica (tope, cupos, códigos, canje) |
| `qr-cartel-promo.png` | QR para imprimir → `https://promo.blackjacksmash.es` |

## Puesta en marcha (unos 20 minutos, todo gratis)

### 1. Base de datos: Supabase
1. Crea una cuenta en supabase.com → **New project** (región: Europe West).
2. Abre `sql/schema.sql` y, al final, cambia:
   - las fechas de inicio y fin,
   - los cupos (`1000` tickets, `200` burgers),
   - `CAMBIA-ESTA-CLAVE` por la clave del personal (**mínimo 10 caracteres**, que no sea un PIN de 4 cifras).
3. Supabase → **SQL Editor** → pega el archivo entero → **Run**.
4. **Project Settings → API**: copia la *Project URL* y la clave *anon public* en `config.js`.

> La clave *anon* es pública a propósito: con ella solo se pueden llamar las 4 funciones de la promo. Las tablas no se pueden leer desde fuera. **Nunca pongas la clave `service_role` en la web.**

### 2. Publicar: Vercel (o Netlify)
1. Cuenta en vercel.com → **Add New → Project** → sube esta carpeta (o conéctala desde GitHub).
2. **Settings → Domains** → añade `promo.blackjacksmash.es`.
3. Vercel te dirá que crees un registro **CNAME** `promo` → `cname.vercel-dns.com` en el panel donde tengáis el dominio. Cuando propague, ya funciona con HTTPS.

### 3. Probar antes de imprimir
- Pide un ticket con tu email y canjéalo en `promo.blackjacksmash.es/canje.html`.
- Borra los tickets de prueba: SQL Editor → `delete from tickets;`

### 4. Imprimir el QR
Usa `qr-cartel-promo.png`. Tiene corrección de errores alta, así que admite un logo pequeño en el centro y funciona impreso a 3 cm o más.

## En el local
- Abrid `promo.blackjacksmash.es/canje.html` en el móvil o la tablet de caja, meted la clave y elegid el local.
- Escaneáis el QR del ticket con la cámara (Chrome en Android) o escribís el código. **Verde = válido → Canjear. Rojo = ya usado o no existe.**
- Si un cliente perdió su ticket: Supabase → Table Editor → `tickets`, buscad por su email o móvil.

## Consultas útiles (SQL Editor)
```sql
-- Resumen
select count(*) emitidos,
       count(*) filter (where prize='burger') burgers,
       count(redeemed_at) canjeados,
       count(*) filter (where redeemed_at_sede='Ontinyent') ontinyent,
       count(*) filter (where redeemed_at_sede='Alcoy') alcoy
from tickets;

-- Cambiar la clave del personal
update promo_config set staff_pin_hash = extensions.crypt('NUEVA-CLAVE', extensions.gen_salt('bf'));

-- Ampliar fecha de fin
update promo_config set ends_at = '2027-01-06 23:59:59+01';

-- Al terminar (protección de datos): borrar contactos
update tickets set contact = 'borrado-' || id;
```

## Límites a tener en cuenta
- El email o el móvil **no se verifican**. Alguien con muchos emails podría sacar varios tickets. Para una promo de 1000 tickets suele bastar; si veis abuso, se puede añadir verificación por código (SMS o email), aunque añade coste y fricción.
- Como el premio se asigna al azar, la promo puede considerarse una *combinación aleatoria con fines publicitarios*. Consultadlo con vuestra gestoría y publicad las bases antes de empezar.
