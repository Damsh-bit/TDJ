-- Tiempo de Juego v2
-- Limite SEMANAL de horas compartido entre amigos, estadisticas por dia
-- (misiones, muertes, oro, enemigos, experiencia), avisos con estilo en el chat,
-- panel de opciones y datos "en vivo" para la web.

local PREFIJO = "TDJ1"
local VERSION = "2.0"
local ENVIO_CADA = 60          -- segundos entre envios de estado a los amigos
local VIVO_CADA = 120          -- segundos entre datos "en vivo" para la web
local ONLINE_SI_VISTO = 180    -- si no llega nada en este tiempo, el amigo figura desconectado
local UMBRALES = { 5 * 3600, 2 * 3600, 3600, 1800, 600, 0 } -- avisos de lo que queda en la semana
local RECORDATORIO_EXTRA = 900 -- cada 15 min pasado el limite, recordar
local HITOS_MISIONES = { [10] = true, [25] = true, [50] = true, [100] = true }
local HITOS_MUERTES = { [5] = true, [10] = true, [20] = true, [50] = true }

local OPCIONES_DEFECTO = {
    limiteSemanal = 42, horaReinicio = 6, contarAFK = false,
    mostrarBarra = true, bloquear = false, mostrarAmigos = true, mostrarStats = true, escala = 1.0,
    avisosPantalla = true, sonido = true,
    chatNivel = true, chatLimite = true, chatHitos = true, chatConexion = true,
    avisoHermandad = false, enVivo = true,
}

local ICONO = {
    reloj   = "Interface\\Icons\\INV_Misc_PocketWatch_01",
    nivel   = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
    limite  = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    casi    = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew",
    mision  = "Interface\\GossipFrame\\AvailableQuestIcon",
    muerte  = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    hola    = "Interface\\FriendsFrame\\StatusIcon-Online",
    oro     = "Interface\\MoneyFrame\\UI-GoldIcon",
    espada  = "Interface\\Icons\\INV_Sword_04",
    ok      = "Interface\\RaidFrame\\ReadyCheck-Ready",
}

local DB, OP
local floor, max, min, format = math.floor, math.max, math.min, string.format

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------
local function icono(ruta, tam) return format("|T%s:%d:%d|t", ruta, tam or 14, tam or 14) end

local function fmt(seg)
    seg = max(0, floor(seg or 0))
    local h, m = floor(seg / 3600), floor((seg % 3600) / 60)
    if h > 0 then return format("%dh %02dm", h, m) end
    return format("%dm", m)
end

local function fmtOro(cobre)
    cobre = floor(cobre or 0)
    local o, p = floor(cobre / 10000), floor((cobre % 10000) / 100)
    if o > 0 then return format("%do %dp", o, p) end
    return format("%dp %dc", p, cobre % 100)
end

local function limpiar(s) return (tostring(s or ""):gsub("[;|,~\"\\]", "")) end
local function miNombre() return (DB and DB.nombre) or UnitName("player") or "?" end
local function miClase() local _, c = UnitClass("player"); return c or "" end
local function limiteSemSeg() return floor((OP.limiteSemanal or 42) * 3600) end

local function colorClase(nombre, clase)
    local c = clase and RAID_CLASS_COLORS and RAID_CLASS_COLORS[clase]
    if c then return format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, nombre) end
    return "|cffffffff" .. nombre .. "|r"
end

-- El "dia" arranca a la hora de reinicio (por defecto 6 AM): jugar pasada la
-- medianoche cuenta para el dia anterior. La semana arranca el lunes a esa hora.
local function ajustado(t) return (t or time()) - (OP.horaReinicio or 6) * 3600 end
local function claveDia(t) return date("%Y-%m-%d", ajustado(t)) end
local function inicioSemana(t)
    local a = ajustado(t)
    local desdeLunes = (tonumber(date("%w", a)) + 6) % 7
    return a - desdeLunes * 86400
end
local function claveSemana(t) return date("%Y-%m-%d", inicioSemana(t)) end

local function registroHoy()
    local d = claveDia()
    local r = DB.dias[d]
    if not r then
        r = { seg = 0, misiones = 0, muertes = 0, oroG = 0, oroS = 0, kills = 0, xp = 0, pjs = {},
              nivelIni = UnitLevel("player") }
        DB.dias[d] = r
    end
    return r, d
end

local function segSemana()
    local lunes, total = inicioSemana(), 0
    for i = 0, 6 do
        local r = DB.dias[date("%Y-%m-%d", lunes + i * 86400)]
        if r then total = total + (r.seg or 0) end
    end
    return total
end

local function colorPorPorcentaje(p)
    if p >= 1 then return 0.85, 0.15, 0.15 end
    if p >= 0.85 then return 0.9, 0.75, 0.1 end
    return 0.2, 0.75, 0.3
end

---------------------------------------------------------------------------
-- Avisos con estilo en el chat
---------------------------------------------------------------------------
local function chat(ruta, texto)
    DEFAULT_CHAT_FRAME:AddMessage(format("%s |cffffd100Tiempo de Juego|r |cff8a6d3b»|r %s", icono(ruta), texto))
end
local function imprimir(texto) chat(ICONO.reloj, texto) end

local function sonar()
    if OP.sonido then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959) end
end

local function avisarPantalla(texto)
    if OP.avisosPantalla and RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, texto, ChatTypeInfo["RAID_WARNING"])
    end
    sonar()
end

-- Texto y opcion de cada tipo de evento que se comparte con los amigos
local EVENTOS = {
    NIVEL    = { op = "chatNivel",    icono = ICONO.nivel,  texto = function(n, d) return format("%s llegó a |cffffd100nivel %s|r!", n, d) end },
    LIMITE   = { op = "chatLimite",   icono = ICONO.limite, texto = function(n, d) return format("%s llegó a su |cffff5555límite semanal|r de %sh.", n, d) end },
    CASI     = { op = "chatLimite",   icono = ICONO.casi,   texto = function(n, d) return format("A %s le queda |cffffaa00%s|r de juego esta semana.", n, fmt(tonumber(d))) end },
    MISIONES = { op = "chatHitos",    icono = ICONO.mision, texto = function(n, d) return format("%s completó |cffffd100%s misiones|r hoy.", n, d) end },
    MUERTES  = { op = "chatHitos",    icono = ICONO.muerte, texto = function(n, d) return format("%s ya murió |cffff5555%s veces|r hoy.", n, d) end },
    HOLA     = { op = "chatConexion", icono = ICONO.hola,   texto = function(n, d) return format("%s se conectó |cff8a8a8a(%s esta semana)|r.", n, fmt(tonumber(d))) end },
}
local vistos = {} -- para no repetir el mismo evento que llega por varios canales

local function mostrarEvento(tipo, nombre, clase, dato, esMio)
    local e = EVENTOS[tipo]
    if not e or not OP[e.op] then return end
    local clave = tipo .. nombre .. tostring(dato)
    if vistos[clave] and GetTime() - vistos[clave] < 120 then return end
    vistos[clave] = GetTime()
    chat(e.icono, e.texto(esMio and "|cffffffffVos|r" or colorClase(nombre, clase), dato))
end

---------------------------------------------------------------------------
-- Comunicacion con amigos (hermandad, grupo y amigos de Battle.net)
---------------------------------------------------------------------------
local enviarAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

local function enviar(msg)
    if IsInGuild and IsInGuild() then pcall(enviarAddon, PREFIJO, msg, "GUILD") end
    if IsInRaid and IsInRaid() then pcall(enviarAddon, PREFIJO, msg, "RAID")
    elseif IsInGroup and IsInGroup() then pcall(enviarAddon, PREFIJO, msg, "PARTY") end
    if BNSendGameData and BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts then
        local cliente = BNET_CLIENT_WOW or "WoW"
        for i = 1, (BNGetNumFriends() or 0) do
            for j = 1, (C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
                local ga = C_BattleNet.GetFriendGameAccountInfo(i, j)
                if ga and ga.isOnline and ga.clientProgram == cliente and ga.gameAccountID then
                    pcall(BNSendGameData, ga.gameAccountID, PREFIJO, msg)
                end
            end
        end
    end
end

local function enviarEvento(tipo, dato)
    mostrarEvento(tipo, miNombre(), miClase(), dato, true)
    enviar(table.concat({ "E", tipo, limpiar(miNombre()), miClase(), tostring(dato) }, ";"))
end

local function enviarEstado()
    local r, hoy = registroHoy()
    enviar(table.concat({
        "S2", hoy, claveSemana(), floor(r.seg), floor(segSemana()), limiteSemSeg(), UnitLevel("player") or 0,
        limpiar(UnitName("player")), miClase(), limpiar(miNombre()),
        r.misiones or 0, r.muertes or 0, floor(r.oroG or 0), floor(r.oroS or 0), r.kills or 0, r.xp or 0,
    }, ";"))
end

local proximoEnvio = 0
local function pedirEnvio(enSegundos)
    local t = GetTime() + (enSegundos or 3)
    if proximoEnvio == 0 or t < proximoEnvio then proximoEnvio = t end
end

local actualizarUI -- se define mas abajo

local function procesarMensaje(texto)
    local c = { strsplit(";", texto or "") }
    local tipo = c[1]
    if tipo == "Q" then pedirEnvio(2 + math.random() * 3); return end
    if tipo == "E" then
        if c[3] and c[3] ~= "" and c[3] ~= miNombre() then mostrarEvento(c[2], c[3], c[4], c[5]) end
        return
    end
    if tipo ~= "S2" then return end
    local nombre = c[10]
    if not nombre or nombre == "" or nombre == miNombre() then return end
    local a = DB.amigos[nombre] or { hist = {} }
    a.dia, a.semana = c[2], c[3]
    a.seg, a.semSeg, a.limSem = tonumber(c[4]) or 0, tonumber(c[5]) or 0, tonumber(c[6]) or 0
    a.nivel, a.pj, a.clase = tonumber(c[7]) or 0, c[8], (c[9] ~= "" and c[9] or nil)
    a.visto = time()
    a.hist = a.hist or {}
    a.hist[a.dia] = { seg = a.seg, nivel = a.nivel, misiones = tonumber(c[11]) or 0, muertes = tonumber(c[12]) or 0,
                      oroG = tonumber(c[13]) or 0, oroS = tonumber(c[14]) or 0, kills = tonumber(c[15]) or 0, xp = tonumber(c[16]) or 0 }
    DB.amigos[nombre] = a
    actualizarUI()
end

---------------------------------------------------------------------------
-- Interfaz: la barra
---------------------------------------------------------------------------
local ANCHO = 260
local marco = CreateFrame("Frame", "TiempoDeJuegoMarco", UIParent)
marco:SetSize(ANCHO, 60)
marco:SetFrameStrata("MEDIUM")
marco:SetClampedToScreen(true)
marco:SetMovable(true)
marco:EnableMouse(true)
marco:RegisterForDrag("LeftButton")
marco:Hide()

local function colorTextura(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1) else tex:SetTexture(r, g, b, a or 1) end
end

local fondo = marco:CreateTexture(nil, "BACKGROUND")
fondo:SetAllPoints()
colorTextura(fondo, 0, 0, 0, 0.6)
local bordeSup = marco:CreateTexture(nil, "BORDER")
bordeSup:SetPoint("TOPLEFT"); bordeSup:SetPoint("TOPRIGHT"); bordeSup:SetHeight(1)
colorTextura(bordeSup, 0.79, 0.63, 0.29, 0.9)

local titulo = marco:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
titulo:SetPoint("TOPLEFT", 6, -5)
titulo:SetText(icono(ICONO.reloj, 12) .. " Tiempo de juego")

local engranaje = CreateFrame("Button", nil, marco)
engranaje:SetSize(14, 14)
engranaje:SetPoint("TOPRIGHT", -5, -4)
engranaje:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
engranaje:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

local function crearBarra(alto)
    local b = CreateFrame("StatusBar", nil, marco)
    b:SetSize(ANCHO - 12, alto)
    b:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    b:SetMinMaxValues(0, 1)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    colorTextura(bg, 0.15, 0.15, 0.15, 0.8)
    b.texto = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.texto:SetPoint("LEFT", 4, 0)
    b.texto:SetPoint("RIGHT", -4, 0)
    b.texto:SetJustifyH("LEFT")
    return b
end

local barraPropia = crearBarra(18)
barraPropia:SetPoint("TOPLEFT", 6, -20)
local lineaHoy = marco:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
lineaHoy:SetPoint("TOPLEFT", 8, -42)
lineaHoy:SetPoint("RIGHT", -6, 0)
lineaHoy:SetJustifyH("LEFT")
local barrasAmigos = {}

local function ponerBarra(b, seg, lim)
    local p = lim > 0 and seg / lim or 1
    b:SetValue(min(p, 1))
    b:SetStatusBarColor(colorPorPorcentaje(p))
end

actualizarUI = function()
    if not DB then return end
    local r, hoy = registroHoy()
    local lim, sem = limiteSemSeg(), segSemana()
    local resto = lim - sem

    ponerBarra(barraPropia, sem, lim)
    if resto > 0 then
        barraPropia.texto:SetText(format("Semana %s / %s  (quedan %s)", fmt(sem), fmt(lim), fmt(resto)))
    else
        barraPropia.texto:SetText(format("Semana %s / %s  |cffff4444(+%s pasado)|r", fmt(sem), fmt(lim), fmt(-resto)))
    end

    local y = -40
    if OP.mostrarStats then
        lineaHoy:SetText(format("Hoy %s   %s %d   %s %d   %s %d   %s +%s",
            fmt(r.seg), icono(ICONO.mision, 11), r.misiones or 0, icono(ICONO.muerte, 11), r.muertes or 0,
            icono(ICONO.espada, 11), r.kills or 0, icono(ICONO.oro, 10), fmtOro(r.oroG)))
        lineaHoy:Show()
        y = -56
    else
        lineaHoy:Hide()
    end

    local lista = {}
    if OP.mostrarAmigos then
        local semana = claveSemana()
        for nombre, a in pairs(DB.amigos) do
            lista[#lista + 1] = { nombre = nombre, a = a, sem = (a.semana == semana) and (a.semSeg or 0) or 0 }
        end
        table.sort(lista, function(p, q) return p.sem > q.sem end)
    end
    for i, item in ipairs(lista) do
        local b = barrasAmigos[i]
        if not b then b = crearBarra(14); barrasAmigos[i] = b end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 6, y)
        b:Show()
        local a = item.a
        local aLim = (a.limSem and a.limSem > 0) and a.limSem or lim
        ponerBarra(b, item.sem, aLim)
        local online = (time() - (a.visto or 0)) < ONLINE_SI_VISTO
        b:SetAlpha(online and 1 or 0.5)
        local extra = ""
        if item.sem >= aLim then extra = " |cffff4444PASADO|r" end
        if online then extra = extra .. " |cff33ff33en juego|r" end
        b.texto:SetText(format("%s Nv%d: %s / %s%s", colorClase(item.nombre, a.clase), a.nivel or 0, fmt(item.sem), fmt(aLim), extra))
        y = y - 17
    end
    for i = #lista + 1, #barrasAmigos do barrasAmigos[i]:Hide() end
    marco:SetHeight(-y + 4)
end

marco:SetScript("OnDragStart", function(self) if not OP.bloquear then self:StartMoving() end end)
marco:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    DB.pos = { p, rp, x, y }
end)

local function aplicarBarra()
    marco:SetScale(OP.escala or 1)
    if OP.mostrarBarra then marco:Show(); actualizarUI() else marco:Hide() end
end

---------------------------------------------------------------------------
-- Avisos propios (limite semanal)
---------------------------------------------------------------------------
local function revisarAvisos()
    local semana = claveSemana()
    if DB.avisos.semana ~= semana then DB.avisos = { semana = semana } end
    local av, lim, sem = DB.avisos, limiteSemSeg(), segSemana()
    local resto = lim - sem
    local mensaje, tipo
    for _, u in ipairs(UMBRALES) do
        if resto <= u and not av[u] then
            av[u] = true
            if u == 0 then
                mensaje, tipo = "¡Llegaste a tu límite de " .. fmt(lim) .. " de esta semana!", "LIMITE"
                av.ultimoExtra = sem
            else
                mensaje, tipo = "Te quedan " .. fmt(resto) .. " de juego esta semana.", (u <= 3600) and "CASI" or nil
            end
        end
    end
    if not mensaje and resto < 0 and av.ultimoExtra and (sem - av.ultimoExtra) >= RECORDATORIO_EXTRA then
        av.ultimoExtra = sem
        mensaje = "Ya te pasaste " .. fmt(-resto) .. " del límite semanal. ¡A descansar!"
    end
    if mensaje then
        avisarPantalla(mensaje)
        if tipo == "LIMITE" then
            enviarEvento("LIMITE", OP.limiteSemanal)
            if OP.avisoHermandad and IsInGuild() then
                pcall(SendChatMessage, "[Tiempo de Juego] Llegué a mi límite semanal de " .. OP.limiteSemanal .. "h. ¡Me voy a descansar!", "GUILD")
            end
        elseif tipo == "CASI" then
            enviarEvento("CASI", floor(max(0, resto)))
        else
            imprimir(mensaje)
        end
    end
end

---------------------------------------------------------------------------
-- Datos "en vivo" para la web
-- El addon se susurra a si mismo una linea "TDJ:..." cada 2 minutos. El juego la
-- guarda en Logs\WoWChatLog.txt (con el registro de chat activado) y el subidor
-- la lee mientras jugas. La linea no se muestra en el chat.
---------------------------------------------------------------------------
local function campo(s) return (tostring(s or ""):gsub("[,~\"\\|;:]", "")) end

local function filaPropia(d, r)
    return table.concat({ campo(miNombre()), d, floor(r.seg or 0), r.nivel or 0, campo(r.ultimoPj), campo(r.clase),
        limiteSemSeg(), "propio", r.misiones or 0, r.muertes or 0, floor(r.oroG or 0), floor(r.oroS or 0),
        r.kills or 0, r.xp or 0 }, ",")
end

local function enviarVivo()
    if not OP.enVivo then return end
    local r, d = registroHoy()
    pcall(SendChatMessage, "TDJ:" .. filaPropia(d, r), "WHISPER", nil, UnitName("player"))
end

local function filtroVivo(_, _, msg) return type(msg) == "string" and msg:find("^TDJ:") ~= nil end
if ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", filtroVivo)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filtroVivo)
end

local function activarRegistroChat()
    if OP.enVivo and LoggingChat and not LoggingChat() then LoggingChat(true) end
end

---------------------------------------------------------------------------
-- Exportacion para la web (al salir o /reload): ultimos 60 dias, propios y de amigos.
-- Registros separados por "~", campos por ",":
--   persona,dia,segundos,nivel,personaje,clase,limiteSemanal,fuente,misiones,muertes,oroGanado,oroGastado,kills,xp
---------------------------------------------------------------------------
local function armarExport()
    local desde = claveDia(time() - 60 * 86400)
    local filas = {}
    for d, r in pairs(DB.dias) do
        if d >= desde then filas[#filas + 1] = filaPropia(d, r) end
    end
    for nombre, a in pairs(DB.amigos) do
        for d, h in pairs(a.hist or {}) do
            if d >= desde then
                filas[#filas + 1] = table.concat({ campo(nombre), d, floor(h.seg or 0), h.nivel or 0, campo(a.pj), campo(a.clase),
                    a.limSem or 0, "amigo", h.misiones or 0, h.muertes or 0, floor(h.oroG or 0), floor(h.oroS or 0),
                    h.kills or 0, h.xp or 0 }, ",")
            end
        end
    end
    DB.export = table.concat(filas, "~")
end

---------------------------------------------------------------------------
-- Estadisticas del dia
---------------------------------------------------------------------------
local ultimoOro, ultimoXP, ultimoXPMax, ultimoNivel

local function anotarPersonaje(r)
    r.ultimoPj, r.clase = UnitName("player"), miClase()
    r.nivel = max(r.nivel or 0, UnitLevel("player") or 0)
    r.nivelIni = r.nivelIni or UnitLevel("player")
    r.pjs = r.pjs or {}
    r.pjs[UnitName("player") or "?"] = UnitLevel("player")
end

local function sumar(r, campoNombre, n) r[campoNombre] = (r[campoNombre] or 0) + n end

local function alCambiarOro()
    local m = GetMoney()
    if ultimoOro then
        local r, dif = registroHoy(), m - ultimoOro
        if dif > 0 then sumar(r, "oroG", dif) elseif dif < 0 then sumar(r, "oroS", -dif) end
    end
    ultimoOro = m
end

local function alCambiarXP()
    local xp, mx, nv = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if ultimoXP then
        local ganado
        if nv > (ultimoNivel or nv) then ganado = (ultimoXPMax - ultimoXP) + xp else ganado = xp - ultimoXP end
        if ganado > 0 then sumar(registroHoy(), "xp", ganado) end
    end
    ultimoXP, ultimoXPMax, ultimoNivel = xp, mx, nv
end

---------------------------------------------------------------------------
-- Panel de opciones
---------------------------------------------------------------------------
local panel
local function crearPanel()
    local ok, f = pcall(CreateFrame, "Frame", "TiempoDeJuegoOpciones", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "TiempoDeJuegoOpciones", UIParent)
        local bg = f:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); colorTextura(bg, 0.05, 0.04, 0.03, 0.95)
    end
    f:SetSize(440, 600)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()
    tinsert(UISpecialFrames, "TiempoDeJuegoOpciones") -- se cierra con Escape

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("TOP", 0, -6)
    t:SetText(icono(ICONO.reloj, 14) .. " |cffffd100Tiempo de Juego|r  |cff8a8a8av" .. VERSION .. "|r")

    local y = -34
    local refrescos = {}
    local columna = 0
    local function finFila() if columna == 1 then y = y - 24; columna = 0 end end
    local function seccion(texto)
        finFila()
        y = y - 8
        local s = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        s:SetPoint("TOPLEFT", 18, y)
        s:SetText(texto)
        local linea = f:CreateTexture(nil, "ARTWORK")
        linea:SetPoint("TOPLEFT", 18, y - 16); linea:SetPoint("RIGHT", f, "RIGHT", -18, 0); linea:SetHeight(1)
        colorTextura(linea, 0.79, 0.63, 0.29, 0.5)
        y = y - 24
    end
    local function casilla(texto, clave, alCambiar)
        local c = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        c:SetSize(24, 24)
        c:SetPoint("TOPLEFT", 20 + columna * 200, y)
        local l = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("LEFT", c, "RIGHT", 2, 1)
        l:SetText(texto)
        c:SetScript("OnClick", function(self)
            OP[clave] = self:GetChecked() and true or false
            if alCambiar then alCambiar() end
        end)
        refrescos[#refrescos + 1] = function() c:SetChecked(OP[clave]) end
        if columna == 1 then y = y - 24; columna = 0 else columna = 1 end
    end
    local function paso(texto, clave, minimo, maximo, salto, mostrar, alCambiar)
        finFila()
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", 24, y - 5)
        l:SetText(texto)
        local menos = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        menos:SetSize(24, 20); menos:SetPoint("TOPLEFT", 250, y); menos:SetText("-")
        local valor = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        valor:SetPoint("LEFT", menos, "RIGHT", 6, 0); valor:SetWidth(70)
        local mas = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        mas:SetSize(24, 20); mas:SetPoint("LEFT", valor, "RIGHT", 6, 0); mas:SetText("+")
        local function poner(v)
            v = max(minimo, min(maximo, floor(v / salto + 0.5) * salto))
            OP[clave] = v
            valor:SetText(mostrar(v))
            if alCambiar then alCambiar() end
        end
        menos:SetScript("OnClick", function() poner((OP[clave] or minimo) - salto) end)
        mas:SetScript("OnClick", function() poner((OP[clave] or minimo) + salto) end)
        refrescos[#refrescos + 1] = function() valor:SetText(mostrar(OP[clave] or minimo)) end
        y = y - 26
    end

    seccion("General")
    do
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", 24, y - 5)
        l:SetText("Tu nombre (como te ven tus amigos)")
        local e = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        e:SetSize(130, 20); e:SetPoint("TOPLEFT", 256, y); e:SetAutoFocus(false); e:SetMaxLetters(24)
        local function guardar(self)
            local n = limpiar(self:GetText())
            if n ~= "" then DB.nombre = n; pedirEnvio(1) end
            self:SetText(miNombre()); self:ClearFocus()
        end
        e:SetScript("OnEnterPressed", guardar)
        e:SetScript("OnEditFocusLost", guardar)
        e:SetScript("OnEscapePressed", function(self) self:SetText(miNombre()); self:ClearFocus() end)
        refrescos[#refrescos + 1] = function() e:SetText(miNombre()) end
        y = y - 26
    end
    paso("Límite semanal", "limiteSemanal", 1, 168, 1, function(v) return v .. " horas" end,
        function() DB.avisos = { semana = claveSemana() }; pedirEnvio(1); actualizarUI() end)
    paso("El día nuevo empieza a las", "horaReinicio", 0, 23, 1, function(v) return format("%02d:00", v) end, actualizarUI)
    casilla("Contar el tiempo AFK", "contarAFK")

    seccion("Barra")
    casilla("Mostrar la barra", "mostrarBarra", aplicarBarra)
    casilla("Bloquear posición", "bloquear")
    casilla("Mostrar amigos", "mostrarAmigos", actualizarUI)
    casilla("Mostrar estadísticas de hoy", "mostrarStats", actualizarUI)
    paso("Tamaño", "escala", 0.6, 1.6, 0.1, function(v) return format("%d%%", floor(v * 100 + 0.5)) end, aplicarBarra)

    seccion("Tus avisos")
    casilla("Carteles en pantalla", "avisosPantalla")
    casilla("Sonido", "sonido")

    seccion("Avisos de amigos en el chat")
    casilla("Subidas de nivel", "chatNivel")
    casilla("Límite semanal", "chatLimite")
    casilla("Misiones y muertes", "chatHitos")
    casilla("Conexiones", "chatConexion")
    casilla("Anunciar mi límite en la hermandad", "avisoHermandad")
    finFila()

    seccion("Web")
    casilla("Datos en vivo mientras juego", "enVivo", activarRegistroChat)
    finFila()
    local nota = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nota:SetPoint("TOPLEFT", 24, y + 2); nota:SetPoint("RIGHT", f, "RIGHT", -18, 0); nota:SetJustifyH("LEFT")
    nota:SetText("Activa el registro de chat del juego para que el subidor mande tus horas a la web mientras jugás, sin esperar a que cierres.")

    local cerrar = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cerrar:SetSize(100, 22); cerrar:SetPoint("BOTTOM", 0, 14); cerrar:SetText("Cerrar")
    cerrar:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnShow", function() for _, r in ipairs(refrescos) do r() end end)
    return f
end

local function abrirOpciones()
    panel = panel or crearPanel()
    if panel:IsShown() then panel:Hide() else panel:Show() end
end
engranaje:SetScript("OnClick", abrirOpciones)

-- Tambien aparece en Opciones > AddOns del juego, con un boton que abre el panel
local function registrarEnOpcionesDelJuego()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local p = CreateFrame("Frame")
    local t = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -16)
    t:SetText("Tiempo de Juego")
    local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    b:SetSize(180, 24); b:SetPoint("TOPLEFT", 16, -48); b:SetText("Abrir opciones")
    b:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel.Close then pcall(SettingsPanel.Close, SettingsPanel) end
        panel = panel or crearPanel(); panel:Show()
    end)
    pcall(function() Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(p, "Tiempo de Juego")) end)
end

---------------------------------------------------------------------------
-- Eventos y reloj
---------------------------------------------------------------------------
local eventos = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "CHAT_MSG_ADDON", "BN_CHAT_MSG_ADDON",
    "GROUP_ROSTER_UPDATE", "PLAYER_LOGOUT", "PLAYER_MONEY", "QUEST_TURNED_IN", "PLAYER_DEAD", "PLAYER_XP_UPDATE",
    "COMBAT_LOG_EVENT_UNFILTERED" }) do
    pcall(eventos.RegisterEvent, eventos, e)
end

local contando = false
local acumulado, desdeEnvio, desdeVivo = 0, 0, 0

eventos:SetScript("OnEvent", function(self, evento, ...)
    if evento == "ADDON_LOADED" then
        if ... ~= "TiempoDeJuego" then return end
        TiempoDeJuegoDB = TiempoDeJuegoDB or {}
        DB = TiempoDeJuegoDB
        DB.dias = DB.dias or {}
        DB.amigos = DB.amigos or {}
        DB.avisos = DB.avisos or {}
        DB.op = DB.op or {}
        OP = DB.op
        for k, v in pairs(OPCIONES_DEFECTO) do if OP[k] == nil then OP[k] = v end end
        -- Datos de la version 1
        if DB.horaReinicio and OP.horaReinicio == 6 then OP.horaReinicio = DB.horaReinicio end
        if DB.oculto then OP.mostrarBarra = false end
        if DB.bloqueado then OP.bloquear = true end
        DB.horaReinicio, DB.oculto, DB.bloqueado, DB.limiteHoras = nil, nil, nil, nil

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIJO)
        elseif RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(PREFIJO) end
        marco:ClearAllPoints()
        if DB.pos then marco:SetPoint(DB.pos[1], UIParent, DB.pos[2], DB.pos[3], DB.pos[4])
        else marco:SetPoint("TOP", UIParent, "TOP", 0, -30) end
        aplicarBarra()
        registrarEnOpcionesDelJuego()

    elseif evento == "PLAYER_LOGIN" then
        contando = true
        anotarPersonaje(registroHoy())
        ultimoOro = GetMoney()
        ultimoXP, ultimoXPMax, ultimoNivel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
        activarRegistroChat()
        actualizarUI()
        enviar("Q")
        pedirEnvio(5)
        enviar(table.concat({ "E", "HOLA", limpiar(miNombre()), miClase(), floor(segSemana()) }, ";"))
        imprimir("v" .. VERSION .. " cargado. Opciones: el engranaje de la barra o |cffffff00/tdj|r.")

    elseif evento == "PLAYER_LEVEL_UP" then
        local r = registroHoy()
        local nuevo = tonumber((...)) or 0
        r.pjs[UnitName("player") or "?"] = nuevo
        r.nivel = max(r.nivel or 0, nuevo)
        enviarEvento("NIVEL", nuevo)
        pedirEnvio(2)

    elseif evento == "PLAYER_MONEY" then
        alCambiarOro()
    elseif evento == "PLAYER_XP_UPDATE" then
        alCambiarXP()
    elseif evento == "QUEST_TURNED_IN" then
        local r = registroHoy()
        sumar(r, "misiones", 1)
        if HITOS_MISIONES[r.misiones] then enviarEvento("MISIONES", r.misiones) end
    elseif evento == "PLAYER_DEAD" then
        local r = registroHoy()
        sumar(r, "muertes", 1)
        if HITOS_MUERTES[r.muertes] then enviarEvento("MUERTES", r.muertes) end
    elseif evento == "COMBAT_LOG_EVENT_UNFILTERED" then
        if CombatLogGetCurrentEventInfo then
            local _, sub, _, origen = CombatLogGetCurrentEventInfo()
            if sub == "PARTY_KILL" and (origen == UnitGUID("player") or origen == UnitGUID("pet")) then
                sumar(registroHoy(), "kills", 1)
            end
        end

    elseif evento == "GROUP_ROSTER_UPDATE" then
        pedirEnvio(4)
    elseif evento == "PLAYER_LOGOUT" then
        armarExport()
    elseif evento == "CHAT_MSG_ADDON" or evento == "BN_CHAT_MSG_ADDON" then
        local prefijo, texto = ...
        if prefijo == PREFIJO then procesarMensaje(texto) end
    end
end)

eventos:SetScript("OnUpdate", function(self, transcurrido)
    if not contando then return end
    if transcurrido > 60 then transcurrido = 60 end
    acumulado = acumulado + transcurrido
    if acumulado < 1 then return end

    local r = registroHoy()
    if not r.ultimoPj then anotarPersonaje(r) end -- arranco un dia nuevo jugando
    r.limiteSemanal = limiteSemSeg()
    if OP.contarAFK or not UnitIsAFK("player") then r.seg = r.seg + acumulado end
    desdeEnvio, desdeVivo = desdeEnvio + acumulado, desdeVivo + acumulado
    acumulado = 0

    revisarAvisos()
    if desdeEnvio >= ENVIO_CADA or (proximoEnvio > 0 and GetTime() >= proximoEnvio) then
        desdeEnvio, proximoEnvio = 0, 0
        enviarEstado()
    end
    if desdeVivo >= VIVO_CADA then desdeVivo = 0; enviarVivo() end
    if marco:IsShown() then actualizarUI() end
end)

---------------------------------------------------------------------------
-- Comandos: /tdj o /tiempo
---------------------------------------------------------------------------
local function historial()
    local dias = {}
    for d in pairs(DB.dias) do dias[#dias + 1] = d end
    table.sort(dias, function(a, b) return a > b end)
    imprimir("Tus últimos días:")
    for i = 1, min(10, #dias) do
        local r = DB.dias[dias[i]]
        DEFAULT_CHAT_FRAME:AddMessage(format("   |cffffd100%s|r  %s   %s %d   %s %d   %s %d   %s +%s / -%s",
            dias[i], fmt(r.seg), icono(ICONO.mision, 11), r.misiones or 0, icono(ICONO.muerte, 11), r.muertes or 0,
            icono(ICONO.espada, 11), r.kills or 0, icono(ICONO.oro, 10), fmtOro(r.oroG), fmtOro(r.oroS)))
    end
    imprimir(format("Esta semana: %s de %s.", fmt(segSemana()), fmt(limiteSemSeg())))
end

SLASH_TIEMPODEJUEGO1 = "/tdj"
SLASH_TIEMPODEJUEGO2 = "/tiempo"
SlashCmdList["TIEMPODEJUEGO"] = function(entrada)
    local cmd, resto = (entrada or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "opciones" then abrirOpciones()
    elseif cmd == "historial" then historial()
    elseif cmd == "limite" then
        local n = tonumber((resto:gsub(",", ".")))
        if n and n > 0 and n <= 168 then
            OP.limiteSemanal = floor(n); DB.avisos = { semana = claveSemana() }
            imprimir("Límite semanal: " .. OP.limiteSemanal .. " horas."); pedirEnvio(1)
        else imprimir("Uso: /tdj limite 42") end
    elseif cmd == "nombre" then
        local n = limpiar(resto)
        if n ~= "" then DB.nombre = n; imprimir("Tus amigos te ven como: " .. n); pedirEnvio(1)
        else imprimir("Uso: /tdj nombre Juan") end
    elseif cmd == "olvidar" then
        if DB.amigos[resto] then DB.amigos[resto] = nil; actualizarUI(); imprimir("Quitado: " .. resto)
        else imprimir("No encontré a '" .. resto .. "'.") end
    else
        imprimir("Comandos: |cffffff00/tdj|r (opciones), |cffffff00/tdj historial|r, |cffffff00/tdj limite 42|r, |cffffff00/tdj nombre Juan|r, |cffffff00/tdj olvidar Juan|r")
    end
end
