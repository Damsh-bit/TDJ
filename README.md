# Tiempo de Juego (TDJ)

Addon de **WoW Forever** para un grupo de amigos: cada uno tiene un **límite semanal de horas** (42 h por defecto), el addon cuenta el tiempo, las misiones, las muertes, el oro y los enemigos de cada día, avisa en el chat cuando alguien sube de nivel o llega al límite, y todo se ve en una web.

- Web: **https://tiempo-de-juego.vercel.app** (y también en **https://alzstats.pro/wow**)
- Datos de ejemplo: agregá `?demo` a cualquiera de las dos direcciones.

## Qué hay en el repo

| Carpeta | Qué es |
|---|---|
| `addon/TiempoDeJuego/` | El addon. Va en `World of Warcraft\_forever_\Interface\AddOns\`. |
| `subidor/` | Programita de Windows que sube los datos a la web cada 5 minutos (y en vivo mientras jugás). |
| `web/` | La web y su API (Vercel + base Neon Postgres). `tdj.js` y `tdj.css` son el panel; alzstats usa una copia. |
| `scripts/empaquetar.ps1` | Arma el zip para pasarle a los amigos. |

## El addon

- **Barra** con las horas de la semana, las de hoy y las estadísticas del día, más una fila por cada amigo (verde si va bien, amarilla si le quedan menos de 5 h, roja si se pasó).
- **Panel de opciones**: el engranaje de la barra o `/tdj`. Ahí se cambia todo: nombre, límite semanal, hora en que empieza el día, qué se muestra, qué avisos llegan y los datos en vivo.
- **Avisos en el chat** con íconos: subidas de nivel, límite semanal, hitos de misiones y muertes, conexiones. Opcional: anunciar en la hermandad cuando llegás al límite.
- **Estadísticas por día**: tiempo (sin contar AFK), misiones entregadas, muertes, oro ganado y gastado, enemigos derrotados (golpe final tuyo o de tu mascota) y experiencia.
- Los amigos se conectan solos por **amigos de Battle.net**, hermandad o grupo.
- Comandos: `/tdj` (opciones), `/tdj historial`, `/tdj limite 42`, `/tdj nombre Juan`, `/tdj olvidar Juan`.

## Cómo llegan los datos a la web

1. Al cerrar el juego (o con `/reload`) el addon guarda los últimos 60 días en `SavedVariables`.
2. **En vivo**: mientras el juego está abierto, el subidor manda cada minuto una estimación de lo jugado hoy (lo último que guardó el addon + el tiempo que pasó desde entonces) y la marca de "jugando ahora". En la web se ve como "Hoy ~45m (en vivo)". El dato exacto reemplaza a la estimación con cada `/reload` y al cerrar el juego.
3. El subidor (tarea de Windows cada 5 minutos) manda todo a `POST /api/subir` con la clave del grupo. La prueba de `instalar.bat` hace una sola vuelta y termina, aunque el juego esté abierto.

## Para tus amigos

Corré `scripts\empaquetar.ps1` y pasales `dist\TiempoDeJuego-paquete.zip`. Adentro está el `LEEME.txt` con los pasos.

## Desarrollo

- `subidor/config.json` tiene la dirección de la web y la clave del grupo (`alz`, la misma que `CLAVE_GRUPO` en Vercel).
- La web se publica desde `web/` con `vercel deploy --prod` (proyecto `tiempo-de-juego`). Necesita `DATABASE_URL` (Neon) y `CLAVE_GRUPO`.
- `web/esquema.sql` crea o actualiza la tabla `tdj_dias`.
- Si cambiás `web/tdj.js` o `web/tdj.css`, copialos a alzstats (`public/wow/tdj.js` y `components/wow/tdj.css`).
