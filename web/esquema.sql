-- Tiempo de Juego: horas y estadisticas por persona y por dia (Neon Postgres en Vercel).
-- Se puede correr varias veces: solo crea lo que falta.
create table if not exists tdj_dias (
  persona     text        not null check (char_length(persona) between 1 and 32),
  dia         date        not null,
  segundos    integer     not null default 0 check (segundos between 0 and 86400),
  nivel       smallint    not null default 0 check (nivel between 0 and 200),
  personaje   text        check (char_length(personaje) <= 32),
  clase       text        check (char_length(clase) <= 20),
  limite      integer     not null default 0 check (limite between 0 and 86400),
  fuente      text        not null default 'propio' check (fuente in ('propio', 'amigo')),
  actualizado timestamptz not null default now(),
  primary key (persona, dia)
);
create index if not exists tdj_dias_dia_idx on tdj_dias (dia);

-- v2: limite semanal y estadisticas del dia
alter table tdj_dias add column if not exists limite_semanal integer not null default 0 check (limite_semanal between 0 and 604800);
alter table tdj_dias add column if not exists misiones   integer not null default 0 check (misiones between 0 and 10000);
alter table tdj_dias add column if not exists muertes    integer not null default 0 check (muertes between 0 and 10000);
alter table tdj_dias add column if not exists oro_ganado bigint  not null default 0 check (oro_ganado between 0 and 100000000000);
alter table tdj_dias add column if not exists oro_gastado bigint not null default 0 check (oro_gastado between 0 and 100000000000);
alter table tdj_dias add column if not exists kills      integer not null default 0 check (kills between 0 and 1000000);
alter table tdj_dias add column if not exists xp         integer not null default 0 check (xp between 0 and 100000000);
-- Cuando llego el ultimo dato "en vivo" (mientras la persona juega)
alter table tdj_dias add column if not exists en_vivo    timestamptz;
-- v2.3: estimacion de hoy mientras la persona juega (la manda el subidor al ver el juego abierto).
-- No pisa "segundos": el dato exacto llega con cada /reload y al cerrar el juego.
alter table tdj_dias add column if not exists segundos_vivo integer not null default 0 check (segundos_vivo between 0 and 86400);
-- v2.4: ultima vez que se vio a la persona jugando (cada dato en vivo y al cerrar el juego)
alter table tdj_dias add column if not exists visto timestamptz;
