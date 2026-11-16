// POST /api/subir  — lo llama el subidor de cada PC.
// Encabezado x-clave-grupo: la clave secreta del grupo (variable CLAVE_GRUPO en Vercel).
// Cuerpo: { id, vivo, filas: [{ persona, dia, segundos, nivel, personaje, clase, limite, limite_semanal,
//           fuente, misiones, muertes, oro_ganado, oro_gastado, kills, xp }] }
// vivo = true cuando el dato sale del registro de chat mientras la persona juega.
import { neon } from "@neondatabase/serverless";
import { createHash, timingSafeEqual } from "node:crypto";

const sql = neon(process.env.DATABASE_URL);
const hash = (s) => createHash("sha256").update(String(s ?? "")).digest();
const texto = (v, max) => (typeof v === "string" && v.length > 0 && v.length <= max ? v : null);
const entero = (v, min, max) => {
  const n = Math.round(Number(v));
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : min;
};

function validar(f) {
  if (!f || typeof f !== "object") return null;
  const persona = texto(f.persona, 32);
  const dia = typeof f.dia === "string" && /^\d{4}-\d{2}-\d{2}$/.test(f.dia) ? f.dia : null;
  if (!persona || !dia) return null;
  return {
    persona, dia,
    segundos: entero(f.segundos, 0, 86400),
    nivel: entero(f.nivel, 0, 200),
    personaje: texto(f.personaje, 32),
    clase: texto(f.clase, 20),
    limite: entero(f.limite, 0, 86400),
    limite_semanal: entero(f.limite_semanal, 0, 604800),
    fuente: f.fuente === "propio" ? "propio" : "amigo",
    misiones: entero(f.misiones, 0, 10000),
    muertes: entero(f.muertes, 0, 10000),
    oro_ganado: entero(f.oro_ganado, 0, 1e11),
    oro_gastado: entero(f.oro_gastado, 0, 1e11),
    kills: entero(f.kills, 0, 1e6),
    xp: entero(f.xp, 0, 1e8),
  };
}

const CONTADORES = ["segundos", "nivel", "misiones", "muertes", "oro_ganado", "oro_gastado", "kills", "xp"];

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "Usá POST" });

  const esperada = process.env.CLAVE_GRUPO;
  if (!esperada || !timingSafeEqual(hash(req.headers["x-clave-grupo"]), hash(esperada))) {
    return res.status(401).json({ error: "Clave del grupo incorrecta" });
  }

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch { return res.status(400).json({ error: "JSON inválido" }); }
  }
  if (!Array.isArray(body?.filas) || body.filas.length > 5000) return res.status(400).json({ error: "filas inválidas" });
  const vivo = body.vivo === true;

  // Una fila por persona y dia: gana el dato propio, despues el de mas tiempo
  const unicas = new Map();
  for (const f of body.filas.map(validar).filter(Boolean)) {
    const k = f.persona + "|" + f.dia, p = unicas.get(k);
    if (!p || (f.fuente === "propio" && p.fuente !== "propio") || (f.fuente === p.fuente && f.segundos > p.segundos)) unicas.set(k, f);
  }
  const filas = [...unicas.values()];
  if (!filas.length) return res.status(200).json({ ok: true, filas: 0 });

  // Dato "en vivo" (el subidor ve el juego abierto): solo actualiza la estimacion
  // de hoy y la marca de "jugando ahora". Nunca pisa los segundos exactos.
  if (vivo) {
    await sql.query(
      `insert into tdj_dias (persona, dia, segundos, nivel, personaje, clase, limite_semanal, fuente, segundos_vivo, en_vivo)
       select persona, dia, 0, nivel, personaje, clase, limite_semanal, 'propio', segundos, now()
       from jsonb_to_recordset($1::jsonb) as x(persona text, dia date, segundos int, nivel smallint, personaje text,
            clase text, limite_semanal int)
       on conflict (persona, dia) do update set
         segundos_vivo  = excluded.segundos_vivo,
         en_vivo        = now(),
         nivel          = greatest(tdj_dias.nivel, excluded.nivel),
         limite_semanal = greatest(tdj_dias.limite_semanal, excluded.limite_semanal),
         personaje      = coalesce(tdj_dias.personaje, excluded.personaje),
         clase          = coalesce(tdj_dias.clase, excluded.clase)`,
      [JSON.stringify(filas)]
    );
    return res.status(200).json({ ok: true, filas: filas.length, vivo: true });
  }

  // Los contadores del dia solo suben (los datos "de amigo" pueden llegar incompletos)
  // y los datos propios mandan sobre los "de amigo".
  const propio = (col) => `case when tdj_dias.fuente = 'propio' and excluded.fuente = 'amigo' then tdj_dias.${col} else excluded.${col} end`;
  await sql.query(
    `insert into tdj_dias (persona, dia, segundos, nivel, personaje, clase, limite, limite_semanal, fuente,
                           misiones, muertes, oro_ganado, oro_gastado, kills, xp, en_vivo)
     select persona, dia, segundos, nivel, personaje, clase, limite, limite_semanal, fuente,
            misiones, muertes, oro_ganado, oro_gastado, kills, xp, null
     from jsonb_to_recordset($1::jsonb) as x(persona text, dia date, segundos int, nivel smallint, personaje text,
          clase text, limite int, limite_semanal int, fuente text, misiones int, muertes int, oro_ganado bigint,
          oro_gastado bigint, kills int, xp int)
     on conflict (persona, dia) do update set
       ${CONTADORES.map((c) => `${c} = greatest(tdj_dias.${c}, excluded.${c})`).join(",\n       ")},
       personaje      = ${propio("personaje")},
       clase          = ${propio("clase")},
       limite         = ${propio("limite")},
       limite_semanal = greatest(tdj_dias.limite_semanal, ${propio("limite_semanal")}),
       fuente         = case when tdj_dias.fuente = 'propio' then 'propio' else excluded.fuente end,
       en_vivo        = case when $2 then null else tdj_dias.en_vivo end, -- cerro el juego: deja de figurar "jugando"
       actualizado    = now()`,
    [JSON.stringify(filas), body.cerrado === true]
  );
  return res.status(200).json({ ok: true, filas: filas.length });
}
