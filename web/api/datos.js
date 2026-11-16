// GET /api/datos  — los ultimos 120 dias de todos, una fila por persona y dia.
import { neon } from "@neondatabase/serverless";

const sql = neon(process.env.DATABASE_URL);

export default async function handler(req, res) {
  const filas = await sql.query(
    `select persona, to_char(dia, 'YYYY-MM-DD') as dia, segundos, nivel, personaje, clase, limite, limite_semanal,
            fuente, misiones, muertes, oro_ganado::float8 as oro_ganado, oro_gastado::float8 as oro_gastado,
            kills, xp, actualizado, en_vivo, segundos_vivo
     from tdj_dias where dia >= current_date - 120 order by dia`
  );
  // Con el modo en vivo los datos cambian cada pocos minutos: cache corto.
  res.setHeader("Cache-Control", "s-maxage=30, stale-while-revalidate=60");
  return res.status(200).json(filas);
}
