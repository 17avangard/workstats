script_name('WorkStats')
script_author('17avangard')
script_description('Подсчёт заработка за сеанс на работах Arizona RP. Команда: /wss')
script_version('1.20')

-- ВАЖНО: файл должен быть в кодировке UTF-8.

local imgui    = require 'mimgui'
local ffi      = require 'ffi'
local encoding = require 'encoding'

encoding.default = 'CP1251'
local u8  = encoding.UTF8
local new = imgui.new

-- SAMP.Lua нужна, чтобы читать сообщения сервера о выплатах
local okSampev, sampev = pcall(require, 'samp.events')
if not okSampev then sampev = nil end

------------------------------------------------------------------
-- Иконки FontAwesome (если шрифт не найден - используется обычный текст)
------------------------------------------------------------------
local ICONS = {
    close = 0xF057,      -- circle-xmark
    plus = 0xF055,       -- circle-plus
    check = 0xF058,      -- circle-check
    trash = 0xF2ED,      -- trash-can
    play = 0xF144,       -- circle-play
    stop = 0xF28D,       -- circle-stop
    report = 0xF46C,     -- clipboard-check (завершить сеанс)
    target = 0xF140,     -- bullseye
    clock = 0xF017,      -- clock
    hourglass = 0xF252,  -- hourglass-half
    wallet = 0xF555,     -- wallet
    coins = 0xF51E,      -- coins
    user = 0xF2BD,       -- circle-user (иконка игрока)
    briefcase = 0xF0B1,  -- briefcase
    chart = 0xF201,      -- chart-line
    back = 0xF060,       -- arrow-left (назад из настроек)
    gear = 0xF013,       -- gear (вкладка Настройки)
    session = 0xF080,    -- chart-column (вкладка Сеанс)
    history = 0xF073,    -- calendar-days (вкладка История)
    palette = 0xF53F,    -- palette (вкладка Темы)
    winclose = 0xF00D,   -- xmark (закрыть меню)
    map = 0xF279,        -- map (быстрая карта)
    sync = 0xF021,       -- arrows-rotate (проверка обновлений)
    download = 0xF019,   -- download (скачать обновление)
}
local ICON_FALLBACK = { close = 'x', winclose = 'x', plus = '+', trash = 'x', gear = '*', back = '<' }
local iconsOk = false
local iconRanges
local fontIcons          -- отдельный шрифт FontAwesome (не слит с основным)
local iconMissing = {}   -- иконки, которых нет в загруженном шрифте
local iconSrcName = ''
local iconChecked, iconReport = false, nil

local function cpToUtf8(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    else return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64) end
end

-- только иконка
local function ic(name)
    if iconsOk and ICONS[name] and not iconMissing[name] then return cpToUtf8(ICONS[name]) end
    return ICON_FALLBACK[name] or ''
end

-- иконка + текст
local function icl(name, text)
    local g = ic(name)
    if g == '' then return text end
    return g .. (iconsOk and '  ' or ' ') .. text
end

-- разбор строки на куски: обычный текст / символ иконки (U+F000..U+F8FF)
local function splitIcons(str)
    local out, i, n = {}, 1, #str
    while i <= n do
        local a, b = str:find('\239[\128-\163][\128-\191]', i)
        if not a then out[#out + 1] = { str:sub(i), false }; break end
        if a > i then out[#out + 1] = { str:sub(i, a - 1), false } end
        out[#out + 1] = { str:sub(a, b), true }
        i = b + 1
    end
    return out
end

-- ширина строки (иконки считаются шрифтом иконок)
local function textWidth(str)
    if not (iconsOk and fontIcons) then return imgui.CalcTextSize(str).x end
    local w = 0
    for _, sg in ipairs(splitIcons(str)) do
        if sg[2] then
            imgui.PushFont(fontIcons)
            w = w + imgui.CalcTextSize(sg[1]).x
            imgui.PopFont()
        else
            w = w + imgui.CalcTextSize(sg[1]).x
        end
    end
    return w
end

-- нарисовать строку в draw list: иконки - шрифтом иконок, текст - обычным
local function drawText(dl, pos, col, str)
    if not (iconsOk and fontIcons) then
        dl:AddText(pos, col, str)
        return
    end
    local lh = imgui.GetTextLineHeight()
    local x = pos.x
    for _, sg in ipairs(splitIcons(str)) do
        if sg[2] then
            imgui.PushFont(fontIcons)
            local ilh = imgui.GetTextLineHeight()
            local iw = imgui.CalcTextSize(sg[1]).x
            dl:AddText(imgui.ImVec2(x, pos.y + (lh - ilh) / 2), col, sg[1])
            imgui.PopFont()
            x = x + iw
        elseif sg[1] ~= '' then
            dl:AddText(imgui.ImVec2(x, pos.y), col, sg[1])
            x = x + imgui.CalcTextSize(sg[1]).x
        end
    end
end

-- рисует иконку (или букву) строго по центру точки (cx, cy):
-- центр считается по реальным границам глифа, а не по строке шрифта
local function drawBadgeGlyph(dl, cx, cy, col, str)
    if iconsOk and fontIcons and #str == 3 and str:byte(1) == 0xEF then
        local b1, b2, b3 = str:byte(1, 3)
        local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
        imgui.PushFont(fontIcons)
        local ok = pcall(function()
            local g = fontIcons:FindGlyph(cp)
            local px = cx - (g.X0 + g.X1) / 2
            local py = cy - (g.Y0 + g.Y1) / 2
            dl:AddText(imgui.ImVec2(math.floor(px + 0.5), math.floor(py + 0.5)), col, str)
        end)
        imgui.PopFont()
        if ok then return end
    end
    local w = imgui.CalcTextSize(str).x
    local lh = imgui.GetTextLineHeight()
    dl:AddText(imgui.ImVec2(cx - w / 2, cy - lh / 2), col, str)
end

------------------------------------------------------------------
-- Настройки
------------------------------------------------------------------
local ACCENT = { 0.56, 0.72, 0.96 }
local GREEN  = { 0.58, 0.80, 0.68 }
local RED    = { 0.94, 0.60, 0.68 }
local BG     = { 0.090, 0.094, 0.110 }   -- фон окна
local PANEL  = { 0.068, 0.072, 0.088 }   -- сайдбар и карточки

-- темы оформления
local THEMES = {
    { name = 'Небо',    accent = { 0.56, 0.72, 0.96 }, green = { 0.58, 0.80, 0.68 }, red = { 0.94, 0.60, 0.68 },
      bg = { 0.090, 0.094, 0.110 }, panel = { 0.068, 0.072, 0.088 } },
    { name = 'Фиалка',  accent = { 0.74, 0.65, 0.94 }, green = { 0.58, 0.82, 0.70 }, red = { 0.95, 0.60, 0.70 },
      bg = { 0.095, 0.085, 0.125 }, panel = { 0.072, 0.064, 0.100 } },
    { name = 'Изумруд', accent = { 0.40, 0.80, 0.62 }, green = { 0.62, 0.88, 0.50 }, red = { 0.94, 0.58, 0.58 },
      bg = { 0.075, 0.100, 0.095 }, panel = { 0.056, 0.080, 0.076 } },
    { name = 'Океан',   accent = { 0.35, 0.80, 0.90 }, green = { 0.50, 0.88, 0.72 }, red = { 0.94, 0.58, 0.64 },
      bg = { 0.065, 0.095, 0.115 }, panel = { 0.048, 0.074, 0.092 } },
    { name = 'Закат',   accent = { 0.96, 0.66, 0.40 }, green = { 0.64, 0.82, 0.55 }, red = { 0.94, 0.52, 0.52 },
      bg = { 0.115, 0.090, 0.085 }, panel = { 0.090, 0.068, 0.064 } },
    { name = 'Сакура',  accent = { 0.96, 0.62, 0.78 }, green = { 0.62, 0.84, 0.72 }, red = { 0.96, 0.55, 0.60 },
      bg = { 0.115, 0.085, 0.105 }, panel = { 0.092, 0.065, 0.084 } },
    { name = 'Золото',  accent = { 0.94, 0.80, 0.42 }, green = { 0.66, 0.84, 0.58 }, red = { 0.94, 0.56, 0.54 },
      bg = { 0.105, 0.098, 0.080 }, panel = { 0.082, 0.076, 0.060 } },
    { name = 'AMOLED',  accent = { 0.78, 0.80, 0.86 }, green = { 0.58, 0.82, 0.66 }, red = { 0.94, 0.58, 0.64 },
      bg = { 0.000, 0.000, 0.000 }, panel = { 0.045, 0.045, 0.050 } },
}
local themeIdx = 1
local showDist = true   -- плашка расстояния до метки (такси)
-- tog: анимации переключателей и состояние автопаузы (одна таблица - меньше upvalues)
local tog = { t = 1, last = os.clock(), t2 = 1, last2 = os.clock(), pause = true, pauseSec = 600, act = os.clock(), themeOpen = false }
local distX, distY = nil, nil  -- позиция плашки (доля от размера экрана), nil = по умолчанию
local distDirty = false
local themePath = getWorkingDirectory() .. '\\config\\work_stats_theme.cfg'

local function copyColor(dst, src) dst[1], dst[2], dst[3] = src[1], src[2], src[3] end

local function applyTheme(i)
    local t = THEMES[i]
    if not t then return end
    themeIdx = i
    copyColor(ACCENT, t.accent)
    copyColor(GREEN, t.green)
    copyColor(RED, t.red)
    copyColor(BG, t.bg)
    copyColor(PANEL, t.panel)
end

local function saveTheme()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(themePath, 'w')
    if not f then return end
    f:write(tostring(themeIdx) .. '\n' .. (showDist and '1' or '0') .. '\n' .. (tog.pause and '1' or '0') .. '\n')
    if distX and distY then f:write(('%.5f\n%.5f\n'):format(distX, distY)) end
    f:close()
end

local function setTheme(i)
    applyTheme(i)
    saveTheme()
end

local function loadTheme()
    local f = io.open(themePath, 'r')
    if not f then return end
    local n = tonumber(f:read('*l') or '')
    local d = f:read('*l')
    local l3 = f:read('*l')
    local dx, dy
    if l3 == '0' or l3 == '1' then      -- новый формат: 3-я строка = автопауза
        if l3 == '0' then tog.pause = false end
        dx = tonumber(f:read('*l') or '')
        dy = tonumber(f:read('*l') or '')
    else                                 -- старый формат: 3-я строка = X плашки
        dx = tonumber(l3 or '')
        dy = tonumber(f:read('*l') or '')
    end
    f:close()
    if dx and dy then distX, distY = dx, dy end
    if n and THEMES[n] then applyTheme(n) end
    if d == '0' then showDist = false end
end

loadTheme()
tog.t, tog.t2 = showDist and 1 or 0, tog.pause and 1 or 0

-- мини-окно: доход и время сеанса поверх игры (включается в настройках)
tog.miShow, tog.miX, tog.miY, tog.miDirty, tog.t3, tog.last3 = true, nil, nil, false, 1, os.clock()
function tog.saveMini()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(getWorkingDirectory() .. '\\config\\work_stats_mini.cfg', 'w')
    if not f then return end
    f:write((tog.miShow and '1' or '0') .. '\n')
    if tog.miX and tog.miY then f:write(('%.5f\n%.5f\n'):format(tog.miX, tog.miY)) end
    f:close()
end
function tog.loadMini()
    local f = io.open(getWorkingDirectory() .. '\\config\\work_stats_mini.cfg', 'r')
    if not f then return end
    local v = f:read('*l')
    local x, y = tonumber(f:read('*l') or ''), tonumber(f:read('*l') or '')
    f:close()
    if v == '0' then tog.miShow = false end
    if x and y then tog.miX, tog.miY = x, y end
end
tog.loadMini()
tog.t3 = tog.miShow and 1 or 0

-- быстрая карта: показывается, пока зажата выбранная клавиша
tog.map = { on = false, key = 0, binding = false, a = 0, last = os.clock(), tried = -10, tex = nil, texPath = nil }
tog.mapPath = getWorkingDirectory() .. '\\config\\work_stats_map.cfg'
tog.bit = require 'bit'
tog.icons = {} -- иконки на карте, которые ставит сервер (SetPlayerMapIcon)
do
    local okV, v = pcall(require, 'vkeys')
    tog.vk = (okV and type(v) == 'table') and v or nil
end
function tog.saveMap()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(tog.mapPath, 'w')
    if not f then return end
    f:write((tog.map.on and '1' or '0') .. '\n' .. tostring(tog.map.key) .. '\n')
    f:close()
end
function tog.loadMap()
    local f = io.open(tog.mapPath, 'r')
    if not f then return end
    local on, key = f:read('*l'), tonumber(f:read('*l') or '')
    f:close()
    tog.map.on = (on == '1')
    if key and key > 0 and key < 256 then tog.map.key = key end
end
tog.loadMap()
tog.t4, tog.last4 = tog.map.on and 1 or 0, os.clock()
function tog.keyName(vk)
    if not vk or vk == 0 then return nil end
    if tog.vk and tog.vk.id_to_name then
        local ok, n = pcall(tog.vk.id_to_name, vk)
        if ok and type(n) == 'string' and n ~= '' then return n end
    end
    if vk >= 0x30 and vk <= 0x39 or vk >= 0x41 and vk <= 0x5A then return string.char(vk) end
    if vk >= 0x70 and vk <= 0x87 then return 'F' .. (vk - 0x6F) end
    return ('0x%02X'):format(vk)
end

local JOBS = {
    { id = 'taxi',    name = 'Таксист', builtin = true },
    { id = 'oil',     name = 'Нефтевышка', builtin = true },
    { id = 'collect', name = 'Инкассатор', builtin = true },
}

local JOB_COLORS = {
    taxi = { 0.96, 0.80, 0.40 }, oil = { 0.62, 0.62, 0.70 }, collect = { 0.58, 0.80, 0.68 },
}

local savePath = getWorkingDirectory() .. '\\config\\work_stats.cfg'

------------------------------------------------------------------
-- Такси: доход считается только по сообщению сервера о выплате за заказ.
-- Остальные работы считают любой рост денег, как раньше.
------------------------------------------------------------------
-- [Такси] Клиент оплатил: 27.615.671 (комиссия: 0).
local TAXI_AMOUNT_PAT = u8:decode('Клиент оплатил:%s*(.-)%s*%(')
------------------------------------------------------------------
-- Состояние
------------------------------------------------------------------
local window = new.bool(false)
local locked = false
local scale = 1
local fontMain, fontTitle, fontBig, fontDist

local PALETTE = {
    { 0.74, 0.65, 0.94 }, { 0.94, 0.60, 0.68 }, { 0.46, 0.80, 0.90 },
    { 0.70, 0.86, 0.46 }, { 0.92, 0.74, 0.52 }, { 0.78, 0.66, 0.52 },
}
local MAX_JOBS = 9
local jobsPath = getWorkingDirectory() .. '\\config\\work_stats_jobs.cfg'

local stats = {} -- [id] = { total, secs, count, sEarned, sSecs, sCount, sBest, best, sSpent, spent }
local function newStats()
    return { total = 0, secs = 0, count = 0, best = 0, sEarned = 0, sSecs = 0, sCount = 0, sBest = 0, sSpent = 0, spent = 0 }
end
for _, j in ipairs(JOBS) do stats[j.id] = newStats() end

-- пользовательские работы
local function saveJobs()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(jobsPath, 'w')
    if not f then return end
    for _, j in ipairs(JOBS) do
        if not j.builtin then f:write(('%s|%d|%s\n'):format(j.id, j.ci or 1, j.name)) end
    end
    f:close()
end

local function loadJobs()
    local f = io.open(jobsPath, 'r')
    if not f then return end
    for line in f:lines() do
        local id, ci, name = line:match('^(c%d+)|(%d+)|(.+)$')
        if id and name and #JOBS < MAX_JOBS then
            name = name:gsub('%s+$', '')
            ci = tonumber(ci) or 1
            JOBS[#JOBS + 1] = { id = id, name = name, ci = ci }
            JOB_COLORS[id] = PALETTE[(ci - 1) % #PALETTE + 1]
            stats[id] = newStats()
        end
    end
    f:close()
end

loadJobs()

local selected = 1       -- индекс выбранной работы в JOBS
local running = nil      -- id работы, на которой идёт подсчёт
local lastMoney = nil
local lastTick = os.clock()
local lastSave = os.clock()
local balance = nil
local me = { nick = '', id = -1 }
local tab = 1             -- 1 = сеанс, 2 = история
local log = {}            -- завершённые сеансы
local confirmClear = 0
local hs = { job = nil, target = 0, cur = 0, set = 0, last = os.clock() } -- плавная прокрутка истории
local confirmDel, confirmDelT = nil, 0
local pendingRemove = nil
local logPath = getWorkingDirectory() .. '\\config\\work_stats_log.cfg'

------------------------------------------------------------------
-- Вспомогательные функции
------------------------------------------------------------------
local function V4(r, g, b, a) return imgui.ImVec4(r, g, b, a or 1) end
local function U32(r, g, b, a) return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a or 1)) end

local function say(text)
    sampAddChatMessage(u8:decode('[WorkStats] ' .. text), 0xFF779ECB)
end

local function fmtMoney(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1 '):reverse()
    return (out:gsub('^%s+', '')) .. ' $'
end

local function fmtTime(sec)
    sec = math.floor(sec or 0)
    return ('%d:%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

local function perHour(earned, secs)
    if secs < 5 then return 0 end
    return earned / (secs / 3600)
end

local function fitText(str, maxW)
    if imgui.CalcTextSize(str).x <= maxW then return str end
    local guard = 0
    while #str > 0 and guard < 200 do
        str = str:gsub('[\1-\127\194-\244][\128-\191]*$', '')
        if imgui.CalcTextSize(str .. '...').x <= maxW then return str .. '...' end
        guard = guard + 1
    end
    return str
end

local function firstChar(str)
    local ch = str:match('^[%z\1-\127\194-\244][\128-\191]*') or '?'
    if #ch == 1 then return ch:upper() end
    if #ch == 2 then
        local b1, b2 = ch:byte(1, 2)
        if b1 == 0xD0 and b2 >= 0xB0 and b2 <= 0xBF then      -- а-п
            return string.char(0xD0, b2 - 0x20)
        elseif b1 == 0xD1 and b2 >= 0x80 and b2 <= 0x8F then  -- р-я
            return string.char(0xD0, b2 + 0x20)
        elseif b1 == 0xD1 and b2 == 0x91 then                 -- ё
            return string.char(0xD0, 0x81)
        elseif b1 == 0xD1 and b2 == 0x96 then                 -- і
            return string.char(0xD0, 0x86)
        elseif b1 == 0xD1 and b2 == 0x97 then                 -- ї
            return string.char(0xD0, 0x87)
        elseif b1 == 0xD1 and b2 == 0x94 then                 -- є
            return string.char(0xD0, 0x84)
        elseif b1 == 0xD2 and b2 == 0x91 then                 -- ґ
            return string.char(0xD2, 0x90)
        end
    end
    return ch
end

-- значок работы: первая буква названия капсом
local function jobGlyph(j)
    return firstChar(j.name)
end

local function readMoney()
    local ok, m = pcall(getPlayerMoney, PLAYER_HANDLE)
    if ok and type(m) == 'number' then return m end
end

local function saveStats()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(savePath, 'w')
    if not f then return end
    for _, j in ipairs(JOBS) do
        local s = stats[j.id]
        f:write(('%s %d %d %d %d %d\n'):format(j.id, s.total, math.floor(s.secs), s.count, s.best, s.spent))
    end
    f:close()
end

local function loadStats()
    local f = io.open(savePath, 'r')
    if not f then return end
    for line in f:lines() do
        local id, total, secs, count, best, spent = line:match('^(%w+) (%d+) (%d+) (%d+) (%d+) ?(%d*)')
        if id and stats[id] then
            local s = stats[id]
            s.total, s.secs, s.count, s.best = tonumber(total), tonumber(secs), tonumber(count), tonumber(best)
            s.spent = tonumber(spent) or 0
        end
    end
    f:close()
end

loadStats()

local function setOpen(v)
    window[0] = v and true or false
    if not v then tog.themeOpen = false; tog.map.binding = false end
    if v and not locked then
        lockPlayerControl(true)
        locked = true
    elseif not v and locked then
        lockPlayerControl(false)
        locked = false
    end
end

local function resetSession(id)
    local s = stats[id]
    s.sEarned, s.sSecs, s.sCount, s.sBest, s.sSpent = 0, 0, 0, 0, 0
end

local function saveLog()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(logPath, 'w')
    if not f then return end
    for _, e in ipairs(log) do
        f:write(('%s %s %d %d %d %d\n'):format(e.job, e.ts, e.secs, e.earned, e.spent, e.count))
    end
    f:close()
end

local function loadLog()
    local f = io.open(logPath, 'r')
    if not f then return end
    for line in f:lines() do
        local job, ts, secs, earned, spent, count = line:match('^(%w+) (%S+) (%d+) (%d+) (%d+) (%d+)')
        if job and stats[job] then
            log[#log + 1] = { job = job, ts = ts, secs = tonumber(secs), earned = tonumber(earned),
                              spent = tonumber(spent), count = tonumber(count) }
        end
    end
    f:close()
end

loadLog()

-- завершить сеанс: записать в историю и обнулить текущий
local function finishSession(id)
    local st = stats[id]
    if st.sEarned > 0 or st.sSpent > 0 or st.sSecs > 5 then
        log[#log + 1] = { job = id, ts = os.date('%d.%m_%H:%M'), secs = math.floor(st.sSecs),
                          earned = math.floor(st.sEarned), spent = math.floor(st.sSpent), count = st.sCount }
        while #log > 300 do table.remove(log, 1) end
        saveLog()
    end
    resetSession(id)
    if running == id then running = nil end
    saveStats()
    tog.saveActive()
end

local function clearHistory(id)
    for i = #log, 1, -1 do
        if log[i].job == id then table.remove(log, i) end
    end
    local st = stats[id]
    st.total, st.secs, st.count, st.best, st.spent = 0, 0, 0, 0, 0
    saveLog()
    saveStats()
end

local function removeJob(idx)
    local j = JOBS[idx]
    if not j or j.builtin then return end
    if running == j.id then running = nil end
    for i = #log, 1, -1 do
        if log[i].job == j.id then table.remove(log, i) end
    end
    stats[j.id], JOB_COLORS[j.id] = nil, nil
    table.remove(JOBS, idx)
    if selected > idx then selected = selected - 1 end
    if selected > #JOBS then selected = #JOBS end
    if selected < 1 then selected = 1 end
    saveJobs()
    saveLog()
    saveStats()
    tog.saveActive()
end

------------------------------------------------------------------
-- Защита сеансов: автосохранение незавершённых сеансов в файл (раз в 5 сек),
-- восстановление после вылета и автозавершение при кике / выходе из игры
------------------------------------------------------------------
tog.activePath = getWorkingDirectory() .. '\\config\\work_stats_active.cfg'
tog.activeOn, tog.lastActive, tog.offSince, tog.recovered = false, os.clock(), nil, nil

function tog.hasData(st)
    return st and (st.sEarned > 0 or st.sSpent > 0 or st.sSecs > 5)
end

-- записать все незавершённые сеансы; если их нет - удалить файл. Возвращает true, если файл записан
function tog.saveActive()
    local lines = {}
    for _, j in ipairs(JOBS) do
        local st = stats[j.id]
        if tog.hasData(st) then
            lines[#lines + 1] = ('%s %d %d %d %d'):format(j.id, math.floor(st.sSecs), math.floor(st.sEarned),
                math.floor(st.sSpent), st.sCount)
        end
    end
    if #lines == 0 then
        if tog.activeOn then
            os.remove(tog.activePath)
            tog.activeOn = false
        end
        return false
    end
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(tog.activePath, 'w')
    if not f then return false end
    f:write('T ' .. os.time() .. '\n' .. table.concat(lines, '\n') .. '\n')
    f:close()
    tog.activeOn = true
    return true
end

-- при запуске: если остался файл, значит прошлый сеанс оборвался (вылет) - переносим его в историю
function tog.recoverActive()
    local f = io.open(tog.activePath, 'r')
    if not f then return end
    local head = f:read('*l') or ''
    local savedAt = tonumber(head:match('^T (%d+)')) or os.time()
    local ts = os.date('%d.%m_%H:%M', savedAt)
    local n = 0
    for line in f:lines() do
        local id, secs, earned, spent, count = line:match('^(%w+) (%d+) (%d+) (%d+) (%d+)')
        if id and stats[id] then
            log[#log + 1] = { job = id, ts = ts, secs = tonumber(secs), earned = tonumber(earned),
                              spent = tonumber(spent), count = tonumber(count) }
            n = n + 1
        end
    end
    f:close()
    os.remove(tog.activePath)
    if n > 0 then
        while #log > 300 do table.remove(log, 1) end
        saveLog()
        tog.recovered = n
    end
end
tog.recoverActive()

-- завершить все сеансы, где есть данные (кик, обрыв связи, выход из игры, выгрузка скрипта)
function tog.finishAll(reason)
    local n = 0
    for _, j in ipairs(JOBS) do
        if tog.hasData(stats[j.id]) then
            finishSession(j.id)
            n = n + 1
        end
    end
    running = nil
    if n > 0 and reason then pcall(say, reason) end
    return n
end

------------------------------------------------------------------
-- GitHub: автозагрузка карты и обновление скрипта
-- Репозиторий: https://github.com/17avangard/workstats
-- Файлы в ветке main: WorkStats.lua, map.jpg, version.txt
------------------------------------------------------------------
tog.dl = require('moonloader').download_status
tog.GH = 'https://raw.githubusercontent.com/17avangard/workstats/main/'
tog.up = { st = 'idle', remote = nil, done = false, silent = false, t0 = 0 }
tog.upTmp = getWorkingDirectory() .. '\\config\\work_stats_new.tmp'

function tog.readAll(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local d = f:read('*a')
    f:close()
    return d
end

-- true, если версия a новее версии b ("1.20" > "1.19")
function tog.isNewer(a, b)
    local x, y = {}, {}
    for n in tostring(a):gmatch('%d+') do x[#x + 1] = tonumber(n) end
    for n in tostring(b):gmatch('%d+') do y[#y + 1] = tonumber(n) end
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- kind: 'checking' (качаем version.txt) или 'loading' (качаем сам скрипт)
function tog.upStart(kind)
    local u = tog.up
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    os.remove(tog.upTmp)
    u.st, u.done, u.t0 = kind, false, os.clock()
    local file = (kind == 'checking') and 'version.txt' or 'WorkStats.lua'
    downloadUrlToFile(tog.GH .. file .. '?t=' .. os.time(), tog.upTmp, function(id, status)
        if status == tog.dl.STATUSEX_ENDDOWNLOAD then u.done = true end
    end)
end

function tog.checkUpdate(silent)
    if tog.up.st == 'checking' or tog.up.st == 'loading' then return end
    tog.up.silent = silent
    tog.upStart('checking')
end

-- путь к карте, если она уже лежит на диске
function tog.mapFile()
    local wd = getWorkingDirectory()
    for _, p in ipairs({
        wd .. '\\resource\\workstats\\map.png', wd .. '\\resource\\workstats\\map.jpg',
        wd .. '\\resource\\map.png', wd .. '\\config\\work_stats_map.png',
    }) do
        if doesFileExist(p) then return p end
    end
end

-- если карты нет - скачиваем map.jpg с GitHub (сначала во временный файл)
function tog.mapFetch()
    local m = tog.map
    if not m.on or m.tex or tog.mapFile() then return end
    local wd = getWorkingDirectory()
    local dst = wd .. '\\resource\\workstats\\map.jpg'
    local tmp = dst .. '.tmp'
    if m.dl == 'done' then
        local d = tog.readAll(tmp)
        if d and #d > 10000 then
            os.remove(dst)
            os.rename(tmp, dst)
            m.dl = 'ok'
        else
            os.remove(tmp)
            m.dl, m.dlT = 'err', os.clock()
        end
    elseif m.dl == 'loading' then
        if os.clock() - m.dlT > 90 then m.dl, m.dlT = 'err', os.clock() end
    elseif m.dl == nil or m.dl == 'ok' or (m.dl == 'err' and os.clock() - m.dlT > 60) then
        pcall(createDirectory, wd .. '\\resource')
        pcall(createDirectory, wd .. '\\resource\\workstats')
        os.remove(tmp)
        m.dl, m.dlT = 'loading', os.clock()
        downloadUrlToFile(tog.GH .. 'map.jpg', tmp, function(id, status)
            if status == tog.dl.STATUSEX_ENDDOWNLOAD then m.dl = 'done' end
        end)
    end
end

-- вызывается из tick(): обрабатывает завершённые загрузки
function tog.updTick()
    local u = tog.up
    if u.st == 'checking' then
        if u.done then
            local v = (tog.readAll(tog.upTmp) or ''):match('%d+[%.%d]*')
            os.remove(tog.upTmp)
            if not v then
                u.st = 'err'
            elseif tog.isNewer(v, thisScript().version) then
                u.st, u.remote = 'avail', v
                if u.silent then say('доступно обновление v' .. v .. ': /wss - Настройки') end
            else
                u.st = 'latest'
            end
        elseif os.clock() - u.t0 > 15 then
            u.st = 'err'
        end
    elseif u.st == 'loading' then
        if u.done then
            local d = tog.readAll(tog.upTmp)
            os.remove(tog.upTmp)
            local ok = d and #d > 5000 and d:find('script_name', 1, true)
            if ok then
                local f = io.open(thisScript().path, 'wb')
                if f then f:write(d); f:close() else ok = false end
            end
            if ok then
                u.st = 'reload'
                say('обновлено до v' .. tostring(u.remote) .. ', перезагрузка...')
                thisScript():reload()
            else
                u.st = 'err'
            end
        elseif os.clock() - u.t0 > 60 then
            u.st = 'err'
        end
    end
    tog.mapFetch()
end

------------------------------------------------------------------
-- Подсчёт: рост денег = доход (для такси - только выплаты за заказы
-- по сообщению сервера), падение = расход, пока включён сеанс
------------------------------------------------------------------
-- метка заказа (такси): чекпоинт / гоночный чекпоинт от сервера или метка-вейпоинт на карте
local mark = { cp = nil, rc = nil, wp = nil }
local function markerPos() return mark.rc or mark.cp or mark.wp end

local function fmtInt(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1 '):reverse()
    return (out:gsub('^%s+', ''))
end

local function creditPayout(s, delta)
    tog.act = os.clock()
    s.sEarned, s.total = s.sEarned + delta, s.total + delta
    s.sCount, s.count = s.sCount + 1, s.count + 1
    if delta > s.sBest then s.sBest = delta end
    if delta > s.best then s.best = delta end
end

local function tick()
    local now = os.clock()
    local dt = now - lastTick
    lastTick = now

    tog.updTick() -- обновления и автозагрузка карты

    local m = readMoney()
    balance = m

    -- метка на карте (вейпоинт), если сервер ставит её так
    local okW, found, wx, wy, wz = pcall(getTargetBlipCoordinates)
    mark.wp = (okW and found) and { x = wx, y = wy, z = wz } or nil

    if isSampAvailable() and sampGetGamestate() == 3 then
        local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if ok then
            me.id = id
            me.nick = u8(sampGetPlayerNickname(id) or '')
        end
    end

    if running and m and lastMoney and isSampAvailable() and sampGetGamestate() == 3 then
        local s = stats[running]
        s.sSecs = s.sSecs + dt
        s.secs = s.secs + dt
        local delta = m - lastMoney
        if delta > 0 then
            -- такси считается по сообщению сервера (см. sampev.onServerMessage),
            -- рост баланса игнорируется; остальные работы - как раньше
            if running ~= 'taxi' then creditPayout(s, delta) end
        elseif delta < 0 then -- расходы (аренда, бензин и т.д.)
            s.sSpent, s.spent = s.sSpent - delta, s.spent - delta
        end
    end
    lastMoney = m

    -- кик / обрыв соединения / выход на экран подключения: незавершённые сеансы - в историю
    if isSampAvailable() and sampGetGamestate() ~= 3 then
        tog.offSince = tog.offSince or now
        if now - tog.offSince > 3 then
            tog.finishAll('соединение потеряно - сеанс завершён и сохранён в историю')
            tog.icons = {}
        end
    else
        tog.offSince = nil
    end

    -- автопауза: долго нет выплат
    if tog.pause and running and now - tog.act > tog.pauseSec then
        local s = stats[running]
        s.sSecs = math.max(0, s.sSecs - tog.pauseSec)
        s.secs = math.max(0, s.secs - tog.pauseSec)
        running = nil
        saveStats()
        say(('автопауза: нет выплат %d мин. Время простоя вычтено'):format(tog.pauseSec / 60))
    end

    -- автосохранение незавершённых сеансов (на случай вылета игры)
    if now - tog.lastActive > 5 then
        tog.lastActive = now
        if tog.saveActive() then saveStats() end
    end

    if now - lastSave > 30 then
        lastSave = now
        saveStats()
    end
end

------------------------------------------------------------------
-- Интерфейс
------------------------------------------------------------------
-- плавные анимации наведения: animTo(ключ, цель 0..1, скорость) возвращает сглаженное значение.
-- Каждый ключ нужно вызывать не больше одного раза за кадр.
local hv, hvDt, hvLast = {}, 0, os.clock()
local function animTo(key, goal, speed, dur)
    local e = hv[key]
    if not e then e = { t = goal, p = goal }; hv[key] = e end -- первый кадр без "вспышки"
    if dur then -- анимация за фиксированное время со сглаживанием начала и конца
        local step = hvDt / dur
        if e.p < goal then e.p = math.min(goal, e.p + step) else e.p = math.max(goal, e.p - step) end
        e.t = e.p * e.p * (3 - 2 * e.p)
        return e.t
    end
    e.t = e.t + (goal - e.t) * (1 - math.exp(-hvDt * (speed or 14)))
    if math.abs(goal - e.t) < 0.005 then e.t = goal end
    return e.t
end
local function lerp(a, b, t) return a + (b - a) * t end
local function mixRGB(c1, c2, t) return lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t), lerp(c1[3], c2[3], t) end

local function styledButton(id, label, w, h, primary)
    local pos = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    local hov, act = imgui.IsItemHovered(), imgui.IsItemActive()
    local hA = animTo('b' .. id, hov and 1 or 0, 14)
    local aA = animTo('ba' .. id, act and 1 or 0, 28)
    local dl = imgui.GetWindowDrawList()
    local p2 = imgui.ImVec2(pos.x + w, pos.y + h)
    local r = 9 * scale
    local tc
    if primary then
        local k = 1.0 + 0.06 * hA - 0.24 * aA
        dl:AddRectFilled(pos, p2, U32(math.min(1, ACCENT[1] * k), math.min(1, ACCENT[2] * k), math.min(1, ACCENT[3] * k), 1), r)
        tc = U32(0.07, 0.08, 0.10, 1)
    else
        dl:AddRectFilled(pos, p2, U32(1, 1, 1, 0.03 + 0.03 * hA + 0.02 * aA), r)
        dl:AddRect(pos, p2, U32(1, 1, 1, 0.09 + 0.07 * hA), r)
        tc = U32(0.82, 0.84, 0.88, 1)
    end
    if #label == 3 and label:byte(1) == 0xEF then
        -- одиночная иконка: центр по реальным границам глифа
        drawBadgeGlyph(dl, pos.x + w / 2, pos.y + h / 2, tc, label)
    else
        local tw = textWidth(label)
        drawText(dl, imgui.ImVec2(pos.x + (w - tw) / 2, pos.y + (h - imgui.GetTextLineHeight()) / 2), tc, label)
    end
    return clicked
end

local function statCard(label, value, w, h)
    local pos = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(pos, imgui.ImVec2(pos.x + w, pos.y + h), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
    drawText(dl, imgui.ImVec2(pos.x + 14 * scale, pos.y + 10 * scale), U32(0.55, 0.57, 0.63, 1), label)
    if fontTitle then imgui.PushFont(fontTitle) end
    dl:AddText(imgui.ImVec2(pos.x + 14 * scale, pos.y + h - imgui.GetTextLineHeight() - 10 * scale), U32(0.90, 0.91, 0.94, 1), value)
    if fontTitle then imgui.PopFont() end
    imgui.Dummy(imgui.ImVec2(w, h))
end

local function checkIcons()
    iconChecked = true
    if not (iconsOk and fontIcons) then return end
    local ok = pcall(function()
        local fb = fontIcons.FallbackGlyph
        local bad = {}
        for name, cp in pairs(ICONS) do
            local g = fontIcons:FindGlyph(cp)
            if g == nil or g == fb then
                iconMissing[name] = true
                bad[#bad + 1] = name
            end
        end
        table.sort(bad)
        iconReport = (#bad == 0) and ('иконки загружены: ' .. iconSrcName)
            or ('в шрифте иконок (' .. iconSrcName .. ') нет: ' .. table.concat(bad, ', '))
    end)
    if not ok then iconReport = 'не удалось проверить иконки' end
end

local function draw()
    if not iconChecked then checkIcons() end
    local nowH = os.clock()
    hvDt, hvLast = math.min(0.05, nowH - hvLast), nowH
    local sx, sy = getScreenResolution()
    local W, H = math.floor(780 * scale), math.floor(560 * scale)
    local SB = math.floor(210 * scale)
    local PAD = math.floor(20 * scale)

    local bgdl = imgui.GetBackgroundDrawList()
    bgdl:AddRectFilled(imgui.ImVec2(0, 0), imgui.ImVec2(sx, sy), U32(0.02, 0.02, 0.04, 0.30))

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 14 * scale)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, V4(BG[1], BG[2], BG[3], 0.97))
    imgui.PushStyleColor(imgui.Col.Border, V4(1, 1, 1, 0.07))

    imgui.SetNextWindowPos(imgui.ImVec2(sx / 2, sy / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
    imgui.Begin('###WorkStats', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoScrollbar)

    local wp = imgui.GetWindowPos()
    local dl = imgui.GetWindowDrawList()

    ----------------------------------------------------------------
    -- Сайдбар
    ----------------------------------------------------------------
    local sbA = animTo('sbhide', (tab == 4) and 1 or 0, nil, 0.26) -- 0 = сайдбар виден, 1 = скрыт
    if sbA < 0.995 then
        local wps = imgui.ImVec2(wp.x - SB * sbA, wp.y) -- сайдбар уезжает влево
        dl:AddRectFilled(wps, imgui.ImVec2(wps.x + SB, wps.y + H), U32(PANEL[1], PANEL[2], PANEL[3], 1), 14 * scale, 5)
        dl:AddLine(imgui.ImVec2(wps.x + SB, wps.y + 14 * scale), imgui.ImVec2(wps.x + SB, wps.y + H - 14 * scale), U32(1, 1, 1, 0.07), 1)

        -- логотип (три столбика) и название
        local lg = math.floor(36 * scale)
        local l0 = imgui.ImVec2(wps.x + PAD, wps.y + PAD)
        dl:AddRectFilled(l0, imgui.ImVec2(l0.x + lg, l0.y + lg), U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.15), 11 * scale)
        local bw3, bx = 5 * scale, l0.x + 9 * scale
        for k, hh in ipairs({ 0.38, 0.62, 0.86 }) do
            local top = l0.y + lg - 8 * scale - (lg - 16 * scale) * hh
            dl:AddRectFilled(imgui.ImVec2(bx + (k - 1) * (bw3 + 2 * scale), top),
                imgui.ImVec2(bx + (k - 1) * (bw3 + 2 * scale) + bw3, l0.y + lg - 8 * scale),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.6 + 0.2 * k), 2)
        end
        if fontTitle then imgui.PushFont(fontTitle) end
        dl:AddText(imgui.ImVec2(l0.x + lg + 12 * scale, l0.y - 3 * scale), U32(0.92, 0.93, 0.96, 1), 'WorkStats')
        if fontTitle then imgui.PopFont() end
        dl:AddText(imgui.ImVec2(l0.x + lg + 12 * scale, l0.y + lg - imgui.GetTextLineHeight() + 2 * scale),
            U32(0.50, 0.52, 0.58, 1), 'Статистика работ')

        -- заголовок секции
        local secY = PAD + lg + 20 * scale
        drawText(dl, imgui.ImVec2(wps.x + PAD, wps.y + secY), U32(0.45, 0.47, 0.54, 1), icl('briefcase', 'РАБОТЫ'))

        -- список работ
        local rowH = math.floor(32 * scale)
        local badge = math.floor(22 * scale)
        local y = secY + imgui.GetTextLineHeight() + 8 * scale
        for i, j in ipairs(JOBS) do
            imgui.SetCursorPos(imgui.ImVec2(10 * scale - SB * sbA, y))
            local sp = imgui.GetCursorScreenPos()
            local p2 = imgui.ImVec2(sp.x + SB - 20 * scale, sp.y + rowH)

            -- крестик создаём ПЕРВЫМ, чтобы он перехватывал клик раньше строки
            local xs = math.floor(22 * scale)
            local xp = imgui.ImVec2(p2.x - xs - 4 * scale, sp.y + (rowH - xs) / 2)
            local xc, xh, armed = false, false, false
            if not j.builtin then
                imgui.SetCursorScreenPos(xp)
                xc = imgui.InvisibleButton('##del' .. i, imgui.ImVec2(xs, xs))
                xh = imgui.IsItemHovered()
                armed = (confirmDel == j.id) and (os.clock() - confirmDelT < 3)
            end

            -- строка работы
            imgui.SetCursorScreenPos(sp)
            if imgui.InvisibleButton('##job' .. i, imgui.ImVec2(SB - 20 * scale, rowH)) then selected = i end
            local hov = imgui.IsItemHovered()

            local col = JOB_COLORS[j.id] or ACCENT
            local sel = (selected == i)
            local hA = animTo('jh' .. j.id, (hov or xh) and 1 or 0, 14)
            local sA = animTo('js' .. j.id, sel and 1 or 0, 12)
            if hA > 0.01 then
                dl:AddRectFilled(sp, p2, U32(1, 1, 1, 0.045 * hA * (1 - sA)), 9 * scale)
            end
            if sA > 0.01 then
                dl:AddRectFilled(sp, p2, U32(col[1], col[2], col[3], 0.13 * sA), 9 * scale)
                -- полоска слева "вырастает" из центра
                local barH = (rowH - 16 * scale) * sA
                local midY = sp.y + rowH / 2
                dl:AddRectFilled(imgui.ImVec2(sp.x, midY - barH / 2), imgui.ImVec2(sp.x + 3 * scale, midY + barH / 2),
                    U32(col[1], col[2], col[3], sA), 2)
            end
            -- цветной бейдж с первой буквой
            local b0 = imgui.ImVec2(sp.x + 12 * scale, sp.y + (rowH - badge) / 2)
            dl:AddRectFilled(b0, imgui.ImVec2(b0.x + badge, b0.y + badge), U32(col[1], col[2], col[3], lerp(0.22, 0.9, sA)), 7 * scale)
            local ch = jobGlyph(j)
            drawBadgeGlyph(dl, b0.x + badge / 2, b0.y + badge / 2,
                U32(lerp(col[1], 0.07, sA), lerp(col[2], 0.08, sA), lerp(col[3], 0.10, sA), 1), ch)
            -- название
            local dotOff = j.builtin and 14 or 36
            local nameMaxW = (p2.x - dotOff * scale - 8 * scale) - (b0.x + badge + 10 * scale)
            dl:AddText(imgui.ImVec2(b0.x + badge + 10 * scale, sp.y + (rowH - imgui.GetTextLineHeight()) / 2),
                (function()
                    local r1, g1, b1 = mixRGB({ 0.66, 0.68, 0.75 }, { 0.82, 0.84, 0.88 }, hA)
                    return U32(lerp(r1, 0.94, sA), lerp(g1, 0.95, sA), lerp(b1, 0.98, sA), 1)
                end)(),
                fitText(j.name, nameMaxW))
            -- индикатор активного сеанса
            if running == j.id then
                local cx, cy = p2.x - dotOff * scale, sp.y + rowH / 2
                local pulse = 0.5 + 0.5 * math.sin(os.clock() * 4)
                dl:AddCircleFilled(imgui.ImVec2(cx, cy), (4 + 3 * pulse) * scale, U32(GREEN[1], GREEN[2], GREEN[3], 0.18), 16)
                dl:AddCircleFilled(imgui.ImVec2(cx, cy), 4 * scale, U32(GREEN[1], GREEN[2], GREEN[3], 1), 12)
            end
            -- удаление пользовательской работы (два клика)
            if not j.builtin then
                local dv = animTo('jd' .. j.id, (hov or xh or armed) and 1 or 0, 16)
                local dh = animTo('jdh' .. j.id, xh and 1 or 0, 16)
                if dv > 0.01 then
                    local rc = armed and RED or { 1, 1, 1 }
                    dl:AddRectFilled(xp, imgui.ImVec2(xp.x + xs, xp.y + xs),
                        U32(rc[1], rc[2], rc[3], (armed and 0.22 or lerp(0.04, 0.10, dh)) * dv), 7 * scale)
                    local xg = ic('trash')
                    local xw = textWidth(xg)
                    local ir, ig, ib = mixRGB({ 0.55, 0.57, 0.63 }, { 0.92, 0.93, 0.96 }, dh)
                    if armed then ir, ig, ib = RED[1], RED[2], RED[3] end
                    drawText(dl, imgui.ImVec2(xp.x + (xs - xw) / 2, xp.y + (xs - imgui.GetTextLineHeight()) / 2),
                        U32(ir, ig, ib, dv), xg)
                end
                if xh then imgui.SetTooltip(armed and 'Нажмите ещё раз - удалить работу и её историю' or 'Удалить работу') end
                if xc then
                    if armed then
                        pendingRemove = i
                        confirmDel = nil
                    else
                        confirmDel, confirmDelT = j.id, os.clock()
                    end
                end
            end
            y = y + rowH + 2 * scale
        end
        if pendingRemove then
            removeJob(pendingRemove)
            pendingRemove = nil
        end

        -- карточка игрока (ник и ID)
        local pcH = math.floor(52 * scale)
        local pc0 = imgui.ImVec2(wps.x + 10 * scale, wps.y + H - 10 * scale - pcH)
        local pc1 = imgui.ImVec2(wps.x + SB - 10 * scale, wps.y + H - 10 * scale)

        dl:AddRectFilled(pc0, pc1, U32(1, 1, 1, 0.04), 11 * scale)
        dl:AddRect(pc0, pc1, U32(1, 1, 1, 0.06), 11 * scale)
        local av = 17 * scale
        local avc = imgui.ImVec2(pc0.x + 14 * scale + av, pc0.y + pcH / 2)
        dl:AddCircleFilled(avc, av, U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.2), 24)
        dl:AddCircle(avc, av, U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.6), 24, 1)
        local nick = (me.nick ~= '') and me.nick or 'Игрок'
        local ini = (iconsOk and ic('user') ~= '') and ic('user') or firstChar(nick)
        drawBadgeGlyph(dl, avc.x, avc.y, U32(ACCENT[1], ACCENT[2], ACCENT[3], 1), ini)
        -- шестерёнка справа в карточке игрока: открывает «Настройки»
        local gs = math.floor(28 * scale)
        local gp = imgui.ImVec2(pc1.x - 8 * scale - gs, pc0.y + (pcH - gs) / 2)
        imgui.SetCursorScreenPos(gp)
        if imgui.InvisibleButton('##gear', imgui.ImVec2(gs, gs)) then tog.prevTab = tab; tab = 4 end
        local gA = animTo('gearh', imgui.IsItemHovered() and 1 or 0, 14)
        local gS = animTo('gears', (tab == 4) and 1 or 0, 12)
        dl:AddRectFilled(gp, imgui.ImVec2(gp.x + gs, gp.y + gs),
            U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.18 * gS + 0.07 * gA * (1 - gS)), 8 * scale)
        local gr, gg, gb = mixRGB({ 0.55, 0.57, 0.63 }, { 0.92, 0.93, 0.96 }, gA)
        drawBadgeGlyph(dl, gp.x + gs / 2, gp.y + gs / 2,
            U32(lerp(gr, ACCENT[1], gS), lerp(gg, ACCENT[2], gS), lerp(gb, ACCENT[3], gS), 1), ic('gear'))
        local tx = avc.x + av + 10 * scale
        local maxNW = gp.x - tx - 6 * scale
        local lh = imgui.GetTextLineHeight()
        do
            local nickY = pc0.y + pcH / 2 - lh - 1 * scale
            local nickW = imgui.CalcTextSize(nick).x
            local ncol = U32(0.92, 0.93, 0.96, 1)
            if nickW <= maxNW then
                dl:AddText(imgui.ImVec2(tx, nickY), ncol, nick)
            else
                -- длинный ник: плавно прокручивается туда-обратно внутри своей области
                local over = nickW + 2 * scale - maxNW
                local hold, speed = 1.0, 35 * scale
                local move = over / speed
                local cyc = (hold + move) * 2
                local t = os.clock() % cyc
                local off
                if t < hold then off = 0
                elseif t < hold + move then off = (t - hold) / move * over
                elseif t < hold * 2 + move then off = over
                else off = (1 - (t - hold * 2 - move) / move) * over end
                off = off * off * (3 - 2 * (off / over)) / (over > 0 and over or 1) -- сглаживание
                dl:PushClipRect(imgui.ImVec2(tx, nickY - 2 * scale), imgui.ImVec2(tx + maxNW, nickY + lh + 2 * scale), true)
                dl:AddText(imgui.ImVec2(tx - off, nickY), ncol, nick)
                dl:PopClipRect()
            end
        end
        dl:AddText(imgui.ImVec2(tx, pc0.y + pcH / 2 + 1 * scale), U32(0.55, 0.57, 0.63, 1),
            me.id >= 0 and ('ID: ' .. me.id) or 'ID: -')
    end

    ----------------------------------------------------------------
    -- Основная панель
    ----------------------------------------------------------------
    local job = JOBS[selected]
    local s = stats[job.id]
    local SBW = SB * (1 - sbA) -- панель плавно расширяется
    local MW = W - SBW - PAD * 2
    local mx = SBW + PAD
    local gap = 10 * scale
    local lh = imgui.GetTextLineHeight()
    local function P(px, py) return imgui.ImVec2(wp.x + px, wp.y + py) end
    local GRAY = U32(0.55, 0.57, 0.63, 1)
    local isRun = (running == job.id)
    local jc = JOB_COLORS[job.id] or ACCENT

    -- шапка: название + статус
    local y = PAD
    local cb = math.floor(28 * scale)
    if fontTitle then imgui.PushFont(fontTitle) end
    local tlh = imgui.GetTextLineHeight()
    local tw = imgui.CalcTextSize(job.name).x
    if tab == 4 then
    -- шапка настроек: кнопка «назад» и заголовок
    dl:AddText(P(mx + cb + 12 * scale, y + (cb - tlh) / 2), U32(0.94, 0.95, 0.98, 1), 'Настройки')
    if fontTitle then imgui.PopFont() end
    imgui.SetCursorPos(imgui.ImVec2(mx, y))
    if styledButton('##back', ic('back'), cb, cb, false) then tab = tog.prevTab or 1; tog.themeOpen = false end
    else
    local hb = math.floor(tlh)
    local nx = mx + hb + 10 * scale
    dl:AddText(P(nx, y), U32(0.94, 0.95, 0.98, 1), job.name)
    if fontTitle then imgui.PopFont() end
    dl:AddRectFilled(P(mx, y), P(mx + hb, y + hb), U32(jc[1], jc[2], jc[3], 0.9), 9 * scale)
    local hg = jobGlyph(job)
    local hc = P(mx + hb / 2, y + hb / 2)
    drawBadgeGlyph(dl, hc.x, hc.y, U32(0.07, 0.08, 0.10, 1), hg)
    local chipTxt = isRun and 'Сеанс идёт' or 'На паузе'
    local cc = isRun and GREEN or { 0.60, 0.62, 0.68 }
    local chW = imgui.CalcTextSize(chipTxt).x + 30 * scale
    local chH = lh + 8 * scale
    local chX, chY = nx + tw + 14 * scale, y + (tlh - chH) / 2
    dl:AddRectFilled(P(chX, chY), P(chX + chW, chY + chH), U32(cc[1], cc[2], cc[3], 0.15), chH / 2)
    dl:AddCircleFilled(P(chX + 13 * scale, chY + chH / 2), 3 * scale, U32(cc[1], cc[2], cc[3], 1), 10)
    dl:AddText(P(chX + 22 * scale, chY + (chH - lh) / 2), U32(cc[1], cc[2], cc[3], 1), chipTxt)
    end

    -- кнопка обновления (только в настройках): проверить / скачать новую версию с GitHub
    if tab == 4 then
        local up, lbl = tog.up, nil
        if up.st == 'checking' then lbl = 'Проверка...'
        elseif up.st == 'avail' then lbl = icl('download', 'Обновить до v' .. tostring(up.remote))
        elseif up.st == 'loading' or up.st == 'reload' then lbl = 'Скачивание...'
        elseif up.st == 'latest' then lbl = 'Версия актуальна (v' .. thisScript().version .. ')'
        elseif up.st == 'err' then lbl = 'Ошибка. Повторить'
        else lbl = icl('sync', 'Проверить обновления') end
        local ubw = math.floor(textWidth(lbl) + 32 * scale)
        imgui.SetCursorPos(imgui.ImVec2(W - PAD - cb - 8 * scale - ubw, PAD))
        if styledButton('##upd', lbl, ubw, cb, up.st == 'avail') then
            if up.st == 'avail' then
                tog.upStart('loading')
            elseif up.st ~= 'checking' and up.st ~= 'loading' and up.st ~= 'reload' then
                tog.checkUpdate(false)
            end
        end
    end

    imgui.SetCursorPos(imgui.ImVec2(W - PAD - cb, PAD))
    if styledButton('##close', ic('winclose'), cb, cb, false) then setOpen(false) end

    -- вкладки
    local ty = y + tlh + 14 * scale
    local tabs = { icl('session', 'Сеанс'), icl('history', 'История') }
    if tab ~= 4 then
    local tx = mx
    for i, name in ipairs(tabs) do
        local w = textWidth(name) + 28 * scale
        imgui.SetCursorPos(imgui.ImVec2(tx, ty))
        if imgui.InvisibleButton('##tab' .. i, imgui.ImVec2(w, lh + 12 * scale)) then tab = i end
        local act = (tab == i)
        local hov = imgui.IsItemHovered()
        local thA = animTo('th' .. i, hov and 1 or 0, 14)
        local taA = animTo('ta' .. i, act and 1 or 0, 12)
        local tr, tg, tb = mixRGB({ 0.55, 0.57, 0.63 }, { 0.82, 0.84, 0.88 }, thA)
        drawText(dl, P(tx + 14 * scale, ty + 4 * scale),
            U32(lerp(tr, 0.94, taA), lerp(tg, 0.95, taA), lerp(tb, 0.98, taA), 1), name)
        if taA > 0.01 then
            -- подчёркивание растёт от центра вкладки
            local cxm, half = tx + w / 2, (w - 20 * scale) / 2 * taA
            dl:AddRectFilled(P(cxm - half, ty + lh + 9 * scale), P(cxm + half, ty + lh + 11 * scale),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], taA), 2)
        end
        tx = tx + w
    end
    end
    dl:AddLine(P(mx, ty + lh + 12 * scale), P(mx + MW, ty + lh + 12 * scale), U32(1, 1, 1, 0.07), 1)
    local top = ty + lh + 24 * scale

    -- нижние кнопки
    local bh = math.floor(38 * scale)
    local by = H - PAD - bh - lh - 10 * scale
    local bw = math.floor((MW - gap) / 2)

    if tab == 1 then
        local profit = s.sEarned - s.sSpent

        -- главная карточка
        local hh = math.floor(96 * scale)
        dl:AddRectFilled(P(mx, top), P(mx + MW, top + hh), U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.10), 14 * scale)
        dl:AddRect(P(mx, top), P(mx + MW, top + hh), U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.28), 14 * scale)
        drawText(dl, P(mx + 18 * scale, top + 12 * scale), GRAY, icl('coins', 'Заработано за сеанс'))
        if fontBig then imgui.PushFont(fontBig) end
        dl:AddText(P(mx + 18 * scale, top + 12 * scale + lh + 2 * scale), U32(ACCENT[1], ACCENT[2], ACCENT[3], 1), fmtMoney(s.sEarned))
        if fontBig then imgui.PopFont() end
        -- справа: чистая прибыль
        local pStr = ((profit >= 0) and '+' or '-') .. fmtMoney(math.abs(profit))
        local pLbl = icl('chart', 'Чистая прибыль')
        local pc2 = (profit >= 0) and GREEN or RED
        if fontTitle then imgui.PushFont(fontTitle) end
        local pw = imgui.CalcTextSize(pStr).x
        dl:AddText(P(mx + MW - 18 * scale - pw, top + 12 * scale + lh + 6 * scale), U32(pc2[1], pc2[2], pc2[3], 1), pStr)
        if fontTitle then imgui.PopFont() end
        local plw = textWidth(pLbl)
        drawText(dl, P(mx + MW - 18 * scale - plw, top + 12 * scale), GRAY, pLbl)

        -- три карточки
        local cw = math.floor((MW - gap * 2) / 3)
        local ch = math.floor(66 * scale)
        local cy = top + hh + gap
        imgui.SetCursorPos(imgui.ImVec2(mx, cy))
        statCard(icl('clock', 'Время'), fmtTime(s.sSecs), cw, ch)
        imgui.SetCursorPos(imgui.ImVec2(mx + cw + gap, cy))
        statCard(icl('check', 'Заказов'), tostring(s.sCount), cw, ch)
        imgui.SetCursorPos(imgui.ImVec2(mx + (cw + gap) * 2, cy))
        statCard(icl('wallet', 'Потрачено'), fmtMoney(s.sSpent), cw, ch)


        imgui.SetCursorPos(imgui.ImVec2(mx, by))
        if styledButton('##start', isRun and icl('stop', 'Остановить') or icl('play', 'Начать сеанс'), bw, bh, true) then
            if isRun then
                running = nil
                saveStats()
            else
                running = job.id
                tog.act = os.clock()
                lastMoney = readMoney()
                lastTick = os.clock()
            end
        end
        imgui.SetCursorPos(imgui.ImVec2(mx + bw + gap, by))
        if styledButton('##finish', icl('report', 'Завершить сеанс'), bw, bh, false) then finishSession(job.id) end

    elseif tab == 2 then
        -- история сеансов выбранной работы
        local items = {}
        for i = #log, 1, -1 do
            if log[i].job == job.id then items[#items + 1] = log[i] end
        end

        local by2 = by - lh - 8 * scale -- кнопка выше, чтобы под ней влезли итоги
        local listH = by2 - gap - top
        local rowH = math.floor(lh + 14 * scale)
        local colPad = 14 * scale
        local weights = { 1.3, 1.0, 1.0, 1.5, 1.5, 1.5 }
        local alignR  = { false, false, true, true, true, true }
        local wsum = 0
        for _, w in ipairs(weights) do wsum = wsum + w end
        local colL, colW, cx = {}, {}, colPad
        for c = 1, 6 do
            colW[c] = (MW - colPad * 2) * weights[c] / wsum
            colL[c] = cx
            cx = cx + colW[c]
        end
        -- x для текста: слева по краю столбца или справа (числа выравниваются по правому краю)
        local function colX(c, str)
            if alignR[c] then return colL[c] + colW[c] - imgui.CalcTextSize(str).x end
            return colL[c]
        end
        local heads = { 'Дата', 'Время', 'Заказов', 'Доход', 'Расход', 'Итог' }

        imgui.SetCursorPos(imgui.ImVec2(mx, top))
        imgui.PushStyleColor(imgui.Col.ChildBg, V4(PANEL[1], PANEL[2], PANEL[3], 1))
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 11 * scale)
        imgui.BeginChild('##hist', imgui.ImVec2(MW, listH), false, imgui.WindowFlags.NoScrollWithMouse)
        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0))
        local cdl = imgui.GetWindowDrawList()
        local cwp = imgui.GetWindowPos()

        -- плавная прокрутка колесом мыши (обычная прокрутка отключена флагом выше)
        do
            local now = os.clock()
            local dt = math.min(0.05, now - hs.last)
            hs.last = now
            if hs.job ~= job.id then
                hs.job, hs.target, hs.cur, hs.set = job.id, 0, 0, 0
                imgui.SetScrollY(0)
            else
                local maxY = imgui.GetScrollMaxY()
                local realY = imgui.GetScrollY()
                if math.abs(realY - hs.set) > 1.5 then
                    hs.target, hs.cur = realY, realY -- ползунок перетащили вручную
                end
                if imgui.IsWindowHovered() then
                    local wheel = imgui.GetIO().MouseWheel
                    if wheel ~= 0 then hs.target = hs.target - wheel * rowH * 2 end
                end
                hs.target = math.max(0, math.min(maxY, hs.target))
                hs.cur = hs.cur + (hs.target - hs.cur) * (1 - math.exp(-dt * 14))
                if math.abs(hs.target - hs.cur) < 0.5 then hs.cur = hs.target end
                imgui.SetScrollY(hs.cur)
                hs.set = hs.cur
            end
        end

        for c = 1, 6 do
            imgui.SetCursorPos(imgui.ImVec2(colX(c, heads[c]), 10 * scale))
            imgui.PushStyleColor(imgui.Col.Text, V4(0.55, 0.57, 0.63, 1))
            imgui.TextUnformatted(heads[c])
            imgui.PopStyleColor()
        end
        local ry = 10 * scale + rowH
        if #items == 0 then
            imgui.SetCursorPos(imgui.ImVec2(16 * scale, ry + 6 * scale))
            imgui.TextDisabled('История пуста. Нажмите "Завершить сеанс", и он появится здесь.')
        else
            for i, e in ipairs(items) do
                local yy = ry + (i - 1) * rowH
                if i % 2 == 1 then
                    cdl:AddRectFilled(imgui.ImVec2(cwp.x + 6 * scale, cwp.y + yy - imgui.GetScrollY()),
                        imgui.ImVec2(cwp.x + MW - 6 * scale, cwp.y + yy + rowH - imgui.GetScrollY()),
                        U32(1, 1, 1, 0.025), 7 * scale)
                end
                local net = e.earned - e.spent
                local vals = {
                    (e.ts:gsub('_', ' ')), fmtTime(e.secs), tostring(e.count), '+' .. fmtMoney(e.earned),
                    '-' .. fmtMoney(e.spent), ((net >= 0) and '+' or '-') .. fmtMoney(math.abs(net)),
                }
                local colr = {
                    V4(0.80, 0.82, 0.88, 1), V4(0.80, 0.82, 0.88, 1), V4(0.80, 0.82, 0.88, 1), V4(GREEN[1], GREEN[2], GREEN[3], 1),
                    V4(RED[1], RED[2], RED[3], 1), (net >= 0) and V4(GREEN[1], GREEN[2], GREEN[3], 1) or V4(RED[1], RED[2], RED[3], 1),
                }
                for c = 1, 6 do
                    imgui.SetCursorPos(imgui.ImVec2(colX(c, vals[c]), yy + (rowH - lh) / 2))
                    imgui.PushStyleColor(imgui.Col.Text, colr[c])
                    imgui.TextUnformatted(vals[c])
                    imgui.PopStyleColor()
                end
            end
            imgui.SetCursorPos(imgui.ImVec2(0, ry + #items * rowH + 8 * scale))
            imgui.Dummy(imgui.ImVec2(0, 0))
        end
        imgui.PopStyleVar()
        imgui.EndChild()
        imgui.PopStyleVar()
        imgui.PopStyleColor()

        imgui.SetCursorPos(imgui.ImVec2(mx, by2))
        local armed = (os.clock() - confirmClear) < 3
        if styledButton('##clear', icl('trash', armed and 'Нажмите ещё раз для подтверждения' or 'Очистить историю и итоги'), MW, bh, armed) then
            if armed then
                clearHistory(job.id)
                confirmClear = 0
            else
                confirmClear = os.clock()
            end
        end

        -- итоги за всё время
        local allNet = s.total - s.spent
        local sumStr = ('За всё время: +%s  /  -%s  ·  итог %s%s  ·  %s  ·  %d выплат'):format(
            fmtMoney(s.total), fmtMoney(s.spent), (allNet >= 0) and '+' or '-', fmtMoney(math.abs(allNet)),
            fmtTime(s.secs), s.count)
        local sw = imgui.CalcTextSize(sumStr).x
        dl:AddText(P(mx + math.max(0, (MW - sw) / 2), by2 + bh + 6 * scale), U32(0.62, 0.64, 0.70, 1), sumStr)

    else
        -- настройки
        drawText(dl, P(mx, top), GRAY, icl('gear', 'Общие настройки'))
        -- переключатель: плашка расстояния до метки
        local tgY = top + lh + 8 * scale
        local tgH = math.floor(56 * scale)
        imgui.SetCursorPos(imgui.ImVec2(mx, tgY))
        if imgui.InvisibleButton('##togdist', imgui.ImVec2(MW, tgH)) then
            showDist = not showDist
            saveTheme()
        end
        local tgHov = imgui.IsItemHovered()
        dl:AddRectFilled(P(mx, tgY), P(mx + MW, tgY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
        local tgA = animTo('tgrow', tgHov and 1 or 0, 14)
        if tgA > 0.01 then dl:AddRect(P(mx, tgY), P(mx + MW, tgY + tgH), U32(1, 1, 1, 0.10 * tgA), 11 * scale) end
        drawText(dl, P(mx + 14 * scale, tgY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('target', 'Расстояние до метки'))
        dl:AddText(P(mx + 14 * scale, tgY + tgH - lh - 9 * scale), GRAY, 'Показывать при наличии метки. Двигайте плашку мышью')
        local swW, swH = 40 * scale, 22 * scale
        local swX, swY = mx + MW - 14 * scale - swW, tgY + (tgH - swH) / 2

        -- плавная анимация переключения (0 = выкл, 1 = вкл)
        local nowT = os.clock()
        local adt = math.min(0.05, nowT - tog.last)
        tog.last = nowT
        local goal = showDist and 1 or 0
        tog.t = tog.t + (goal - tog.t) * (1 - math.exp(-adt * 16))
        if math.abs(goal - tog.t) < 0.01 then tog.t = goal end
        local tt = tog.t

        -- свечение вокруг включённого переключателя
        if tt > 0 then
            dl:AddRectFilled(P(swX - 3 * scale, swY - 3 * scale), P(swX + swW + 3 * scale, swY + swH + 3 * scale),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 * tt), swH / 2 + 3 * scale)
        end
        -- дорожка: в цвет темы, плавно заливается при включении
        dl:AddRectFilled(P(swX, swY), P(swX + swW, swY + swH),
            U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 + 0.84 * tt), swH / 2)
        dl:AddRect(P(swX, swY), P(swX + swW, swY + swH),
            U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.40 * (1 - tt)), swH / 2)
        -- ползунок: скользит и меняет цвет (в выключенном виде - цвет темы, во включённом - тёмный)
        local kx = swX + swH / 2 + (swW - swH) * tt
        local kr, kg, kb = ACCENT[1] + (0.07 - ACCENT[1]) * tt, ACCENT[2] + (0.08 - ACCENT[2]) * tt, ACCENT[3] + (0.10 - ACCENT[3]) * tt
        dl:AddCircleFilled(P(kx, swY + swH / 2), swH / 2 - 3 * scale, U32(kr, kg, kb, 0.75 + 0.25 * tt), 16)

        -- переключатель: автопауза
        local apY = tgY + tgH + gap
        imgui.SetCursorPos(imgui.ImVec2(mx, apY))
        if imgui.InvisibleButton('##togpause', imgui.ImVec2(MW, tgH)) then
            tog.pause = not tog.pause
            tog.act = os.clock()
            saveTheme()
        end
        local apHov = imgui.IsItemHovered()
        dl:AddRectFilled(P(mx, apY), P(mx + MW, apY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
        local apA = animTo('aprow', apHov and 1 or 0, 14)
        if apA > 0.01 then dl:AddRect(P(mx, apY), P(mx + MW, apY + tgH), U32(1, 1, 1, 0.10 * apA), 11 * scale) end
        drawText(dl, P(mx + 14 * scale, apY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('hourglass', 'Автопауза'))
        dl:AddText(P(mx + 14 * scale, apY + tgH - lh - 9 * scale), GRAY, 'Пауза, если долго нет выплат')
        local aswX, aswY = mx + MW - 14 * scale - swW, apY + (tgH - swH) / 2
        local nowA = os.clock()
        local adt2 = math.min(0.05, nowA - tog.last2)
        tog.last2 = nowA
        local goal2 = tog.pause and 1 or 0
        tog.t2 = tog.t2 + (goal2 - tog.t2) * (1 - math.exp(-adt2 * 16))
        if math.abs(goal2 - tog.t2) < 0.01 then tog.t2 = goal2 end
        local t2 = tog.t2
        if t2 > 0 then
            dl:AddRectFilled(P(aswX - 3 * scale, aswY - 3 * scale), P(aswX + swW + 3 * scale, aswY + swH + 3 * scale),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 * t2), swH / 2 + 3 * scale)
        end
        dl:AddRectFilled(P(aswX, aswY), P(aswX + swW, aswY + swH),
            U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 + 0.84 * t2), swH / 2)
        dl:AddRect(P(aswX, aswY), P(aswX + swW, aswY + swH),
            U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.40 * (1 - t2)), swH / 2)
        local akx = aswX + swH / 2 + (swW - swH) * t2
        local akr, akg, akb = ACCENT[1] + (0.07 - ACCENT[1]) * t2, ACCENT[2] + (0.08 - ACCENT[2]) * t2, ACCENT[3] + (0.10 - ACCENT[3]) * t2
        dl:AddCircleFilled(P(akx, aswY + swH / 2), swH / 2 - 3 * scale, U32(akr, akg, akb, 0.75 + 0.25 * t2), 16)

        -- переключатель: мини-окно
        do
            local miRowY = apY + tgH + gap
            imgui.SetCursorPos(imgui.ImVec2(mx, miRowY))
            if imgui.InvisibleButton('##togmini', imgui.ImVec2(MW, tgH)) then
                tog.miShow = not tog.miShow
                tog.saveMini()
            end
            local miHov = imgui.IsItemHovered()
            dl:AddRectFilled(P(mx, miRowY), P(mx + MW, miRowY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
            local miA = animTo('mirow', miHov and 1 or 0, 14)
            if miA > 0.01 then dl:AddRect(P(mx, miRowY), P(mx + MW, miRowY + tgH), U32(1, 1, 1, 0.10 * miA), 11 * scale) end
            drawText(dl, P(mx + 14 * scale, miRowY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('chart', 'Мини-окно'))
            dl:AddText(P(mx + 14 * scale, miRowY + tgH - lh - 9 * scale), GRAY, 'Доход и время сеанса поверх игры. Двигайте мышью')
            local mswX, mswY = mx + MW - 14 * scale - swW, miRowY + (tgH - swH) / 2
            local nowM = os.clock()
            local adt3 = math.min(0.05, nowM - tog.last3)
            tog.last3 = nowM
            local goal3 = tog.miShow and 1 or 0
            tog.t3 = tog.t3 + (goal3 - tog.t3) * (1 - math.exp(-adt3 * 16))
            if math.abs(goal3 - tog.t3) < 0.01 then tog.t3 = goal3 end
            local t3 = tog.t3
            if t3 > 0 then
                dl:AddRectFilled(P(mswX - 3 * scale, mswY - 3 * scale), P(mswX + swW + 3 * scale, mswY + swH + 3 * scale),
                    U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 * t3), swH / 2 + 3 * scale)
            end
            dl:AddRectFilled(P(mswX, mswY), P(mswX + swW, mswY + swH),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 + 0.84 * t3), swH / 2)
            dl:AddRect(P(mswX, mswY), P(mswX + swW, mswY + swH),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.40 * (1 - t3)), swH / 2)
            local mkx = mswX + swH / 2 + (swW - swH) * t3
            local mkr, mkg, mkb = ACCENT[1] + (0.07 - ACCENT[1]) * t3, ACCENT[2] + (0.08 - ACCENT[2]) * t3, ACCENT[3] + (0.10 - ACCENT[3]) * t3
            dl:AddCircleFilled(P(mkx, mswY + swH / 2), swH / 2 - 3 * scale, U32(mkr, mkg, mkb, 0.75 + 0.25 * t3), 16)
        end

        -- переключатель: быстрая карта (видна, пока зажата клавиша) + кнопка выбора клавиши
        do
            local m = tog.map
            local mpY = apY + (tgH + gap) * 2
            local chipW, chipH = math.floor(104 * scale), math.floor(30 * scale)
            local swXr = mx + MW - 14 * scale - swW
            local chipX = swXr - 16 * scale - chipW
            local chipY = mpY + (tgH - chipH) / 2

            -- три непересекающиеся кнопки: левая часть строки, выбор клавиши, сам переключатель
            imgui.SetCursorPos(imgui.ImVec2(mx, mpY))
            local togL = imgui.InvisibleButton('##togmap', imgui.ImVec2(chipX - 8 * scale - mx, tgH))
            local hovL = imgui.IsItemHovered()
            imgui.SetCursorPos(imgui.ImVec2(swXr - 8 * scale, mpY))
            local togR = imgui.InvisibleButton('##togmap2', imgui.ImVec2(mx + MW - (swXr - 8 * scale), tgH))
            local hovR = imgui.IsItemHovered()
            imgui.SetCursorPos(imgui.ImVec2(chipX, chipY))
            local keyClick = imgui.InvisibleButton('##mapkey', imgui.ImVec2(chipW, chipH))
            local hovK = imgui.IsItemHovered()
            if togL or togR then
                m.on = not m.on
                m.binding = false
                tog.saveMap()
            end
            if keyClick then m.binding = not m.binding end

            dl:AddRectFilled(P(mx, mpY), P(mx + MW, mpY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
            local mpA = animTo('maprow', (hovL or hovR or hovK) and 1 or 0, 14)
            if mpA > 0.01 then dl:AddRect(P(mx, mpY), P(mx + MW, mpY + tgH), U32(1, 1, 1, 0.10 * mpA), 11 * scale) end
            drawText(dl, P(mx + 14 * scale, mpY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('map', 'Быстрая карта'))
            local subTxt = (m.key == 0) and 'Назначьте клавишу справа' or 'Видна, пока зажата клавиша'
            dl:AddText(P(mx + 14 * scale, mpY + tgH - lh - 9 * scale), GRAY, fitText(subTxt, chipX - mx - 28 * scale))

            -- кнопка клавиши
            local chA = animTo('mapkeyh', hovK and 1 or 0, 14)
            local chW8 = animTo('mapkeyw', m.binding and 1 or 0, 14)
            local cp0, cp1 = P(chipX, chipY), P(chipX + chipW, chipY + chipH)
            dl:AddRectFilled(cp0, cp1, U32(1, 1, 1, 0.05 + 0.04 * chA), 8 * scale)
            if chW8 > 0.01 then dl:AddRectFilled(cp0, cp1, U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.22 * chW8), 8 * scale) end
            dl:AddRect(cp0, cp1, U32(lerp(1, ACCENT[1], chW8), lerp(1, ACCENT[2], chW8), lerp(1, ACCENT[3], chW8),
                lerp(0.12 + 0.10 * chA, 0.9, chW8)), 8 * scale, 15, 1)
            local kLabel, kc
            if m.binding then
                kLabel, kc = 'Нажмите...', ACCENT
            elseif m.key == 0 then
                kLabel, kc = 'Не задана', { 0.55, 0.57, 0.63 }
            else
                kLabel, kc = tog.keyName(m.key) or '?', { 0.92, 0.93, 0.96 }
            end
            kLabel = fitText(kLabel, chipW - 12 * scale)
            dl:AddText(P(chipX + (chipW - imgui.CalcTextSize(kLabel).x) / 2, chipY + (chipH - lh) / 2),
                U32(kc[1], kc[2], kc[3], 1), kLabel)
            if hovK then imgui.SetTooltip('Нажмите, затем клавишу или кнопку мыши. Esc - отмена, Backspace - сбросить') end

            -- переключатель
            local nowQ = os.clock()
            local adt4 = math.min(0.05, nowQ - tog.last4)
            tog.last4 = nowQ
            local goal4 = m.on and 1 or 0
            tog.t4 = tog.t4 + (goal4 - tog.t4) * (1 - math.exp(-adt4 * 16))
            if math.abs(goal4 - tog.t4) < 0.01 then tog.t4 = goal4 end
            local t4 = tog.t4
            local qswY = mpY + (tgH - swH) / 2
            if t4 > 0 then
                dl:AddRectFilled(P(swXr - 3 * scale, qswY - 3 * scale), P(swXr + swW + 3 * scale, qswY + swH + 3 * scale),
                    U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 * t4), swH / 2 + 3 * scale)
            end
            dl:AddRectFilled(P(swXr, qswY), P(swXr + swW, qswY + swH),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 + 0.84 * t4), swH / 2)
            dl:AddRect(P(swXr, qswY), P(swXr + swW, qswY + swH),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.40 * (1 - t4)), swH / 2)
            local qkx = swXr + swH / 2 + (swW - swH) * t4
            local qkr, qkg, qkb = ACCENT[1] + (0.07 - ACCENT[1]) * t4, ACCENT[2] + (0.08 - ACCENT[2]) * t4, ACCENT[3] + (0.10 - ACCENT[3]) * t4
            dl:AddCircleFilled(P(qkx, qswY + swH / 2), swH / 2 - 3 * scale, U32(qkr, qkg, qkb, 0.75 + 0.25 * t4), 16)
        end

        -- оформление: выбор темы во всплывающем меню
        local thHead = apY + (tgH + gap) * 3 + 6 * scale
        drawText(dl, P(mx, thHead), GRAY, icl('palette', 'Оформление'))
        local thY = thHead + lh + 8 * scale
        local ma = animTo('thmenu', tog.themeOpen and 1 or 0, nil, 0.18) -- анимация меню 0..1
        imgui.SetCursorPos(imgui.ImVec2(mx, thY))
        if imgui.InvisibleButton('##themerow', imgui.ImVec2(MW, tgH)) then tog.themeOpen = not tog.themeOpen end
        local thHov = imgui.IsItemHovered()
        dl:AddRectFilled(P(mx, thY), P(mx + MW, thY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
        local thA = animTo('themerow', thHov and 1 or 0, 14)
        if thA > 0.01 then dl:AddRect(P(mx, thY), P(mx + MW, thY + tgH), U32(1, 1, 1, 0.10 * thA), 11 * scale) end
        drawText(dl, P(mx + 14 * scale, thY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('palette', 'Тема оформления'))
        dl:AddText(P(mx + 14 * scale, thY + tgH - lh - 9 * scale), GRAY, THEMES[themeIdx].name)
        -- образцы цветов текущей темы и стрелка
        local cur = THEMES[themeIdx]
        local sdx = mx + MW - 52 * scale
        for _, c in ipairs({ cur.accent, cur.green, cur.red }) do
            dl:AddCircleFilled(P(sdx, thY + tgH / 2), 7 * scale, U32(c[1], c[2], c[3], 1), 16)
            sdx = sdx - 20 * scale
        end
        local chx, chy, chs = mx + MW - 26 * scale, thY + tgH / 2, 4 * scale
        local chc = U32(lerp(0.65, ACCENT[1], ma), lerp(0.67, ACCENT[2], ma), lerp(0.73, ACCENT[3], ma), 1)
        local cdir = 1 - 2 * ma -- стрелка плавно переворачивается
        dl:AddLine(P(chx - chs, chy - cdir * chs / 2), P(chx, chy + cdir * chs / 2), chc, 2)
        dl:AddLine(P(chx, chy + cdir * chs / 2), P(chx + chs, chy - cdir * chs / 2), chc, 2)

        -- своё всплывающее меню тем: скруглённая панель с тенью, плавное появление
        local mpad, ih, mg = 12 * scale, 34 * scale, 8 * scale
        local mcw = math.floor((MW - mpad * 2 - mg) / 2)
        local menuH = mpad * 2 + 4 * ih + 3 * mg
        local menuTop = thY + tgH + 6 * scale
        local mr0, mr1 = P(mx, menuTop), P(mx + MW, menuTop + menuH)
        -- клик мимо меню закрывает его
        if tog.themeOpen and imgui.IsMouseClicked(0) and not thHov and not imgui.IsMouseHoveringRect(mr0, mr1) then
            tog.themeOpen = false
        end
        if ma > 0.01 then
            local fdl = imgui.GetForegroundDrawList()
            local oy = (1 - ma) * -10 * scale
            local m0 = imgui.ImVec2(mr0.x, mr0.y + oy)
            local m1 = imgui.ImVec2(mr1.x, mr1.y + oy)
            local mr = 18 * scale
            for k = 3, 1, -1 do -- мягкая тень
                local e = k * 3 * scale
                fdl:AddRectFilled(imgui.ImVec2(m0.x - e, m0.y - e + 5 * scale), imgui.ImVec2(m1.x + e, m1.y + e + 5 * scale),
                    U32(0, 0, 0, 0.08 * ma), mr + e)
            end
            fdl:AddRectFilled(m0, m1, U32(math.min(1, BG[1] + 0.035), math.min(1, BG[2] + 0.035), math.min(1, BG[3] + 0.04), 0.99 * ma), mr)
            fdl:AddRect(m0, m1, U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.28 * ma), mr, 15, 1)
            for i, t in ipairs(THEMES) do
                local ix = m0.x + mpad + ((i - 1) % 2) * (mcw + mg)
                local iy = m0.y + mpad + math.floor((i - 1) / 2) * (ih + mg)
                local p0, p1 = imgui.ImVec2(ix, iy), imgui.ImVec2(ix + mcw, iy + ih)
                local hov = tog.themeOpen and imgui.IsMouseHoveringRect(p0, p1)
                local sel = (themeIdx == i)
                local hA = animTo('pc' .. i, hov and 1 or 0, 14)
                local sA = animTo('ps' .. i, sel and 1 or 0, 12)
                local ta = t.accent
                -- таблетка с цветом темы
                fdl:AddRectFilled(p0, p1, U32(t.panel[1], t.panel[2], t.panel[3], ma), ih / 2)
                if sA > 0.01 then fdl:AddRectFilled(p0, p1, U32(ta[1], ta[2], ta[3], 0.14 * sA * ma), ih / 2) end
                fdl:AddRect(p0, p1, U32(1, 1, 1, lerp(0.07, 0.22, hA) * (1 - sA) * ma), ih / 2)
                if sA > 0.01 then fdl:AddRect(p0, p1, U32(ta[1], ta[2], ta[3], 0.9 * sA * ma), ih / 2, 15, 2) end
                -- три цветные точки темы
                for k, c in ipairs({ ta, t.green, t.red }) do
                    fdl:AddCircleFilled(imgui.ImVec2(ix + 18 * scale + (k - 1) * 13 * scale, iy + ih / 2), 5.5 * scale,
                        U32(c[1], c[2], c[3], ma), 14)
                end
                local nty = iy + (ih - lh) / 2
                drawText(fdl, imgui.ImVec2(ix + 64 * scale, nty), U32(0.92, 0.93, 0.96, ma), t.name)
                if sA > 0.02 then
                    drawText(fdl, imgui.ImVec2(p1.x - 28 * scale, nty), U32(ta[1], ta[2], ta[3], sA * ma), ic('check'))
                end
                if hov and ma > 0.6 and imgui.IsMouseClicked(0) then
                    setTheme(i)
                    tog.themeOpen = false
                end
            end
        end

    end

    -- подсказка / баланс для проверки
    imgui.SetCursorPos(imgui.ImVec2(mx, H - PAD - imgui.GetTextLineHeight()))
    imgui.PushStyleColor(imgui.Col.Text, V4(0.45, 0.47, 0.54, 1))
    imgui.TextUnformatted(balance and ('Баланс: ' .. fmtMoney(balance) .. '  ·  Esc - закрыть') or 'Баланс не читается  ·  Esc - закрыть')
    imgui.PopStyleColor()

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
end

local frame = imgui.OnFrame(function() return window[0] end, draw)
frame.HideCursor = false

-- маленькая полупрозрачная плашка: расстояние до метки.
-- Показывается всегда, если включена в настройках и есть метка (независимо от сеанса);
-- пока открыто меню (/wss) её можно перетащить мышью.
local function drawDist()
    local editing = window[0]
    local mp = markerPos()
    local dist
    local rel = 0 -- угол до метки относительно взгляда камеры (по часовой, радианы); 0 = прямо
    if mp then
        local px, py = getCharCoordinates(PLAYER_PED)
        dist = math.sqrt((mp.x - px) ^ 2 + (mp.y - py) ^ 2)
        -- куда смотрит камера (как в GPS); если не удалось - по направлению персонажа
        local viewA
        local okC, cx, cy = pcall(getActiveCameraCoordinates)
        local okT, tx, ty = pcall(getActiveCameraPointAt)
        if okC and okT and cx and tx and (tx ~= cx or ty ~= cy) then
            viewA = math.atan2(tx - cx, ty - cy)
        else
            local okH, h = pcall(getCharHeading, PLAYER_PED)
            viewA = okH and h and -math.rad(h) or 0
        end
        rel = math.atan2(mp.x - px, mp.y - py) - viewA
    elseif editing then
        dist = 350 -- образец, чтобы плашку можно было двигать без метки
    else
        return
    end
    local sx, sy = getScreenResolution()

    local col = (dist <= 50) and GREEN or ACCENT
    local str = fmtInt(dist) .. ' м'

    -- размер плашки: стрелка + текст
    if fontDist then imgui.PushFont(fontDist) end
    local tw = imgui.CalcTextSize(str).x
    local tlh = imgui.GetTextLineHeight()
    if fontDist then imgui.PopFont() end
    local arrow = math.floor(tlh * 0.70)       -- размер области со стрелкой
    local gapA = 8 * scale
    local W = math.max(math.floor(108 * scale), math.floor(arrow + gapA + tw + 32 * scale))
    local H = math.floor(tlh + 16 * scale)

    -- позиция: сохранённая или по умолчанию (справа, чтобы не мешать чату), внутри экрана
    local x, y
    if distX and distY then x, y = distX * sx, distY * sy else x, y = sx - W - 16 * scale, sy * 0.30 end
    x = math.max(0, math.min(sx - W, x))
    y = math.max(0, math.min(sy - H, y))

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 11 * scale)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, V4(BG[1], BG[2], BG[3], 0.86))
    imgui.PushStyleColor(imgui.Col.Border, V4(ACCENT[1], ACCENT[2], ACCENT[3], 0.30))
    imgui.SetNextWindowPos(imgui.ImVec2(x, y), editing and imgui.Cond.Appearing or imgui.Cond.Always, imgui.ImVec2(0, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoScrollbar
    if not editing then flags = flags + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoInputs end
    imgui.Begin('###WorkStatsDist', nil, flags)

    local wp = imgui.GetWindowPos()
    local dl = imgui.GetWindowDrawList()
    local gx = wp.x + (W - (arrow + gapA + tw)) / 2
    local ccx, ccy = gx + arrow / 2, wp.y + H / 2

    -- стрелка-указатель: куда двигаться относительно камеры
    local r = arrow / 2
    local sa, ca = math.sin(rel), math.cos(rel)
    local function rot(lx, ly) return imgui.ImVec2(ccx + lx * ca - ly * sa, ccy + lx * sa + ly * ca) end
    local tip, lw, nt, rw = rot(0, -r), rot(-0.78 * r, 0.82 * r), rot(0, 0.30 * r), rot(0.78 * r, 0.82 * r)
    local ac = U32(col[1], col[2], col[3], 1)
    dl:AddTriangleFilled(tip, lw, nt, ac)
    dl:AddTriangleFilled(tip, nt, rw, ac)

    if fontDist then imgui.PushFont(fontDist) end
    dl:AddText(imgui.ImVec2(gx + arrow + gapA, wp.y + (H - tlh) / 2), U32(col[1], col[2], col[3], 1), str)
    if fontDist then imgui.PopFont() end

    -- перетаскивание: запоминаем новую позицию, сохраняем когда отпустили кнопку мыши
    if editing then
        if math.abs(wp.x - x) > 0.5 or math.abs(wp.y - y) > 0.5 then
            distX = math.max(0, math.min(sx - W, wp.x)) / sx
            distY = math.max(0, math.min(sy - H, wp.y)) / sy
            distDirty = true
        end
        if distDirty and not imgui.IsMouseDown(0) then
            distDirty = false
            saveTheme()
        end
    end

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
end

local distFrame
distFrame = imgui.OnFrame(function()
    if distFrame then distFrame.HideCursor = not window[0] end
    return showDist and (markerPos() ~= nil or window[0])
end, drawDist)
distFrame.HideCursor = true

-- мини-окно: показывается во время сеанса, пока открыто меню (/wss) его можно перетащить мышью
function tog.drawMini()
    local editing = window[0]
    local jid = running or (JOBS[selected] and JOBS[selected].id) or 'taxi'
    local job = JOBS[1]
    for _, j in ipairs(JOBS) do
        if j.id == jid then job = j end
    end
    local st = stats[job.id]
    if not st then return end
    local sx, sy = getScreenResolution()

    -- три пункта: заработано, время, заказы
    local earnedStr = icl('coins', fmtMoney(st.sEarned))
    local timeStr = icl('clock', fmtTime(st.sSecs))
    local cntStr = icl('check', tostring(st.sCount))
    local lh = imgui.GetTextLineHeight()
    local tlh = lh
    local ew = textWidth(earnedStr)
    local pad, rg = 14 * scale, 8 * scale
    local W = math.max(math.floor(170 * scale), math.floor(math.max(ew, textWidth(timeStr), textWidth(cntStr)) + pad * 2))
    local H = math.floor(tlh + lh * 2 + rg * 2 + pad * 2 - 4 * scale)

    local x, y
    if tog.miX and tog.miY then x, y = tog.miX * sx, tog.miY * sy else x, y = 16 * scale, sy * 0.30 end
    x = math.max(0, math.min(sx - W, x))
    y = math.max(0, math.min(sy - H, y))

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 11 * scale)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, V4(BG[1], BG[2], BG[3], 0.86))
    imgui.PushStyleColor(imgui.Col.Border, V4(ACCENT[1], ACCENT[2], ACCENT[3], 0.30))
    imgui.SetNextWindowPos(imgui.ImVec2(x, y), editing and imgui.Cond.Appearing or imgui.Cond.Always, imgui.ImVec2(0, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoScrollbar
    if not editing then flags = flags + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoInputs end
    imgui.Begin('###WorkStatsMini', nil, flags)

    local wp = imgui.GetWindowPos()
    local dl = imgui.GetWindowDrawList()

    local ty = wp.y + pad - 2 * scale
    drawText(dl, imgui.ImVec2(wp.x + pad, ty), U32(ACCENT[1], ACCENT[2], ACCENT[3], 1), earnedStr)
    ty = ty + tlh + rg / 2
    dl:AddLine(imgui.ImVec2(wp.x + pad, ty), imgui.ImVec2(wp.x + W - pad, ty), U32(1, 1, 1, 0.10), 1)
    ty = ty + rg / 2
    drawText(dl, imgui.ImVec2(wp.x + pad, ty), U32(0.72, 0.74, 0.80, 1), timeStr)
    ty = ty + lh + rg / 2
    dl:AddLine(imgui.ImVec2(wp.x + pad, ty), imgui.ImVec2(wp.x + W - pad, ty), U32(1, 1, 1, 0.10), 1)
    ty = ty + rg / 2
    drawText(dl, imgui.ImVec2(wp.x + pad, ty), U32(GREEN[1], GREEN[2], GREEN[3], 1), cntStr)

    -- перетаскивание: запоминаем позицию, сохраняем когда отпустили кнопку мыши
    if editing then
        if math.abs(wp.x - x) > 0.5 or math.abs(wp.y - y) > 0.5 then
            tog.miX = math.max(0, math.min(sx - W, wp.x)) / sx
            tog.miY = math.max(0, math.min(sy - H, wp.y)) / sy
            tog.miDirty = true
        end
        if tog.miDirty and not imgui.IsMouseDown(0) then
            tog.miDirty = false
            tog.saveMini()
        end
    end

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
end

tog.miFrame = imgui.OnFrame(function()
    if tog.miFrame then tog.miFrame.HideCursor = not window[0] end
    return tog.miShow and (running ~= nil or window[0])
end, tog.drawMini)
tog.miFrame.HideCursor = true

------------------------------------------------------------------
-- Быстрая карта: полупрозрачная карта поверх игры, пока зажата выбранная клавиша.
-- Картинка карты (квадратная, север сверху, весь мир San Andreas: -3000..3000)
-- скачивается с GitHub автоматически: moonloader\resource\workstats\map.jpg
------------------------------------------------------------------
tog.MAP_FRAC = 0.62 -- размер карты: доля от меньшей стороны экрана

function tog.mapTexture()
    local m = tog.map
    if m.tex then return m.tex end
    if os.clock() - m.tried < 5 then return nil end -- не чаще раза в 5 секунд
    m.tried = os.clock()
    local p = tog.mapFile()
    if p then
        local ok, tex = pcall(imgui.CreateTextureFromFile, p)
        if ok and tex ~= nil then
            m.tex, m.texPath = tex, p
            return tex
        end
    end
end

-- true, пока зажата назначенная клавиша (и это уместно: не чат, не диалог, не пауза, не меню)
function tog.mapHeld()
    local m = tog.map
    if not (m.on and m.key ~= 0) or m.binding or window[0] then return false end
    if not isSampAvailable() or sampGetGamestate() ~= 3 then return false end
    if sampIsChatInputActive() or sampIsDialogActive() then return false end
    local okM, pm = pcall(isPauseMenuActive)
    if okM and pm then return false end
    local okK, down = pcall(isKeyDown, m.key)
    return okK and down == true
end

function tog.drawMap()
    local m = tog.map
    local a = m.a
    local sx, sy = getScreenResolution()
    local S = math.floor(math.min(sx, sy) * tog.MAP_FRAC)
    local x0, y0 = math.floor((sx - S) / 2), math.floor((sy - S) / 2)
    local function C(r, g, b, al) return U32(r, g, b, (al or 1) * a) end

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 14 * scale)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, V4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.Border, V4(0, 0, 0, 0))
    imgui.SetNextWindowPos(imgui.ImVec2(x0, y0), imgui.Cond.Always, imgui.ImVec2(0, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(S, S), imgui.Cond.Always)
    imgui.Begin('###WorkStatsMap', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoInputs)

    local dl = imgui.GetWindowDrawList()
    local p0, p1 = imgui.ImVec2(x0, y0), imgui.ImVec2(x0 + S, y0 + S)
    local rr = 14 * scale
    dl:AddRectFilled(p0, p1, C(BG[1], BG[2], BG[3], 0.55), rr)

    local tex = tog.mapTexture()
    if tex then
        local col = C(1, 1, 1, 0.82)
        local uv0, uv1 = imgui.ImVec2(0, 0), imgui.ImVec2(1, 1)
        local ok = pcall(function() dl:AddImageRounded(tex, p0, p1, uv0, uv1, col, rr) end)
        if not ok then dl:AddImage(tex, p0, p1, uv0, uv1, col) end
    else
        -- заглушка: сетка и статус загрузки карты с GitHub
        for i = 1, 11 do
            local t = S * i / 12
            dl:AddLine(imgui.ImVec2(x0 + t, y0 + 8 * scale), imgui.ImVec2(x0 + t, y0 + S - 8 * scale), C(1, 1, 1, 0.05), 1)
            dl:AddLine(imgui.ImVec2(x0 + 8 * scale, y0 + t), imgui.ImVec2(x0 + S - 8 * scale, y0 + t), C(1, 1, 1, 0.05), 1)
        end
        local dls = tog.map.dl
        local l1 = (dls == 'err') and 'Не удалось скачать карту'
            or ((dls == 'loading' or dls == 'done') and 'Загрузка карты с GitHub...' or 'Нет изображения карты')
        local l2 = (dls == 'err') and 'Проверьте интернет, повтор через минуту' or 'Подождите несколько секунд'
        local w1, w2 = imgui.CalcTextSize(l1).x, imgui.CalcTextSize(l2).x
        local lhh = imgui.GetTextLineHeight()
        dl:AddText(imgui.ImVec2(x0 + (S - w1) / 2, y0 + S / 2 - lhh - 2 * scale), C(0.92, 0.93, 0.96, 1), l1)
        dl:AddText(imgui.ImVec2(x0 + (S - w2) / 2, y0 + S / 2 + 2 * scale), C(0.62, 0.64, 0.70, 1), l2)
    end
    dl:AddRect(p0, p1, C(ACCENT[1], ACCENT[2], ACCENT[3], 0.55), rr, 15, 1.5)

    -- мир (-3000..3000, север сверху) -> пиксели карты
    local function toMap(wx, wy)
        local u = math.max(0, math.min(1, (wx + 3000) / 6000))
        local v = math.max(0, math.min(1, (3000 - wy) / 6000))
        return x0 + u * S, y0 + v * S
    end

    local distTxt
    local okP, px, py = pcall(getCharCoordinates, PLAYER_PED)
    if okP and px then
        local cx, cy = toMap(px, py)
        -- иконки сервера
        for _, ico in pairs(tog.icons) do
            local ix, iy = toMap(ico.x, ico.y)
            dl:AddCircleFilled(imgui.ImVec2(ix, iy), 4.5 * scale, C(0, 0, 0, 0.7), 12)
            dl:AddCircleFilled(imgui.ImVec2(ix, iy), 3.2 * scale, C(ico.r, ico.g, ico.b, 1), 12)
        end
        -- метка (такси и т.п.) и линия до неё
        local mp = markerPos()
        if mp then
            local mx2, my2 = toMap(mp.x, mp.y)
            dl:AddLine(imgui.ImVec2(cx, cy), imgui.ImVec2(mx2, my2), C(1, 1, 1, 0.45), 2)
            local pulse = 0.5 + 0.5 * math.sin(os.clock() * 4)
            dl:AddCircleFilled(imgui.ImVec2(mx2, my2), (8 + 5 * pulse) * scale, C(RED[1], RED[2], RED[3], 0.22), 20)
            dl:AddCircleFilled(imgui.ImVec2(mx2, my2), 6 * scale, C(RED[1], RED[2], RED[3], 1), 16)
            dl:AddCircle(imgui.ImVec2(mx2, my2), 6 * scale, C(1, 1, 1, 0.95), 16, 2)
            distTxt = fmtInt(math.sqrt((mp.x - px) ^ 2 + (mp.y - py) ^ 2)) .. ' м до метки'
        end
        -- стрелка игрока (по направлению персонажа)
        local okH, hd = pcall(getCharHeading, PLAYER_PED)
        local th = math.rad(okH and hd or 0)
        local dx, dy = -math.sin(th), -math.cos(th)
        local r = 9 * scale
        local function pt(f, sd) return imgui.ImVec2(cx + dx * f - dy * sd, cy + dy * f + dx * sd) end
        local tip, lft, nt, rgt = pt(r * 1.4, 0), pt(-r * 0.9, -r * 0.85), pt(-r * 0.35, 0), pt(-r * 0.9, r * 0.85)
        dl:AddCircleFilled(imgui.ImVec2(cx, cy), r * 1.9, C(ACCENT[1], ACCENT[2], ACCENT[3], 0.20), 24)
        dl:AddTriangleFilled(tip, lft, nt, C(ACCENT[1], ACCENT[2], ACCENT[3], 1))
        dl:AddTriangleFilled(tip, nt, rgt, C(ACCENT[1], ACCENT[2], ACCENT[3], 1))
        dl:AddTriangle(tip, lft, nt, C(0, 0, 0, 0.75), 1.5)
        dl:AddTriangle(tip, nt, rgt, C(0, 0, 0, 0.75), 1.5)
    end

    -- плашка сверху
    local label = distTxt and ('Карта  ·  ' .. distTxt) or 'Карта'
    local lw = imgui.CalcTextSize(label).x
    local lh2 = imgui.GetTextLineHeight()
    local bx0, by0 = x0 + 12 * scale, y0 + 12 * scale
    dl:AddRectFilled(imgui.ImVec2(bx0, by0), imgui.ImVec2(bx0 + lw + 20 * scale, by0 + lh2 + 10 * scale),
        C(BG[1], BG[2], BG[3], 0.80), (lh2 + 10 * scale) / 2)
    dl:AddText(imgui.ImVec2(bx0 + 10 * scale, by0 + 5 * scale), C(0.92, 0.93, 0.96, 1), label)

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
end

tog.mapFrame = imgui.OnFrame(function()
    local m = tog.map
    local now = os.clock()
    local dt = math.min(0.05, now - m.last)
    m.last = now
    local goal = tog.mapHeld() and 1 or 0
    m.a = m.a + (goal - m.a) * (1 - math.exp(-dt * 18)) -- плавное появление/исчезновение
    if math.abs(goal - m.a) < 0.01 then m.a = goal end
    return m.a > 0.01
end, tog.drawMap)
tog.mapFrame.HideCursor = true

------------------------------------------------------------------
-- Инициализация
------------------------------------------------------------------
local function findFont()
    local dir = getFolderPath(0x14) .. '\\'
    for _, name in ipairs({ 'segoeui.ttf', 'trebuc.ttf', 'arial.ttf', 'tahoma.ttf' }) do
        if doesFileExist(dir .. name) then return dir .. name end
    end
end

-- ищем источник шрифта FontAwesome: библиотека fAwesome6/5 или файл .ttf
local function findIconSource()
    -- 1. файл шрифта (самый надёжный вариант)
    local wd = getWorkingDirectory()
    for _, path in ipairs({
        wd .. '\\resource\\fonts\\fa-solid-900.ttf',
        wd .. '\\resource\\fonts\\fa6-solid.ttf',
        wd .. '\\resource\\fonts\\fa-solid.ttf',
        wd .. '\\config\\fa-solid-900.ttf',
        wd .. '\\fa-solid-900.ttf',
    }) do
        if doesFileExist(path) then return { path = path, name = path } end
    end

    -- 2. библиотеки (у некоторых __index зациклен, поэтому только rawget + pcall)
    for _, m in ipairs({ 'fAwesome6_solid', 'fAwesome5', 'fAwesome6' }) do
        local okReq, fa = pcall(require, m)
        if okReq and type(fa) == 'table' then
            local okGet, getter = pcall(rawget, fa, 'get_font_data_base85')
            if okGet and type(getter) == 'function' then
                for _, style in ipairs({ 'solid', false }) do
                    local ok, data = pcall(getter, style or nil)
                    if ok and type(data) == 'string' and #data > 0 then
                        return { data = data, name = m }
                    end
                end
            end
        end
    end
end

-- добавляем шрифт иконок ОТДЕЛЬНЫМ шрифтом (без слияния)
local function addIconFont(fonts, size, src)
    local ok, res = pcall(function()
        if src.data then
            return fonts:AddFontFromMemoryCompressedBase85TTF(src.data, size, nil, iconRanges)
        end
        return fonts:AddFontFromFileTTF(src.path, size, nil, iconRanges)
    end)
    if ok and res ~= nil then return res end
end

imgui.OnInitialize(function()
    local _, sy = getScreenResolution()
    scale = math.max(0.8, math.min(2.0, sy / 1080))
    imgui.GetIO().IniFilename = nil

    local fonts = imgui.GetIO().Fonts
    local ranges = fonts:GetGlyphRangesCyrillic()
    local path = findFont()
    if path then
        local okSrc, src = pcall(findIconSource)
        if not okSrc then src = nil end
        iconRanges = new.ImWchar[3](0xF000, 0xF8FF, 0)
        fontMain  = fonts:AddFontFromFileTTF(path, math.floor(16 * scale), nil, ranges)
        fontTitle = fonts:AddFontFromFileTTF(path, math.floor(21 * scale), nil, ranges)
        fontBig   = fonts:AddFontFromFileTTF(path, math.floor(38 * scale), nil, ranges)
        fontDist  = fonts:AddFontFromFileTTF(path, math.floor(24 * scale), nil, ranges)
        if src then
            fontIcons = addIconFont(fonts, math.floor(15 * scale), src)
            iconsOk = fontIcons ~= nil
            iconSrcName = src.name or ''
            if not iconsOk then iconReport = 'не удалось загрузить шрифт иконок: ' .. iconSrcName end
        else
            iconReport = 'файл fa-solid-900.ttf не найден - иконки отключены'
        end
    end

    local st = imgui.GetStyle()
    st.WindowRounding = 14 * scale
    st.ItemSpacing = imgui.ImVec2(8 * scale, 6 * scale)
    st.Colors[imgui.Col.Text] = V4(0.88, 0.89, 0.92, 1)
end)

------------------------------------------------------------------
-- Сообщения сервера: выплаты за заказы такси
------------------------------------------------------------------
if sampev then
    function sampev.onSetCheckpoint(position, radius)
        mark.cp = { x = position.x, y = position.y, z = position.z }
    end
    function sampev.onDisableCheckpoint() mark.cp = nil end
    function sampev.onSetRaceCheckpoint(cpType, position, nextPosition, size)
        mark.rc = { x = position.x, y = position.y, z = position.z }
    end
    function sampev.onDisableRaceCheckpoint() mark.rc = nil end

    -- иконки карты от сервера: показываются на быстрой карте
    function sampev.onSetMapIcon(iconId, position, iconType, color, style)
        local b = tog.bit
        local c = color or 0
        local r, g, bl = b.band(b.rshift(c, 24), 255) / 255, b.band(b.rshift(c, 16), 255) / 255, b.band(b.rshift(c, 8), 255) / 255
        if r + g + bl < 0.05 then r, g, bl = 1, 1, 1 end
        tog.icons[iconId] = { x = position.x, y = position.y, r = r, g = g, b = bl }
    end
    function sampev.onRemoveMapIcon(iconId) tog.icons[iconId] = nil end

    function sampev.onServerMessage(color, text)
        if running ~= 'taxi' then return end
        local clean = text:gsub('{%x%x%x%x%x%x}', '')

        local raw = clean:match(TAXI_AMOUNT_PAT)
        if raw then
            local amount = tonumber((raw:gsub('%D', '')))
            if amount and amount > 0 then
                creditPayout(stats.taxi, amount)
            end
        end
    end
end

-- Esc закрывает меню и не доходит до игры
addEventHandler('onWindowMessage', function(msg, wparam)
    local m = tog.map
    if m.binding then
        -- ждём клавишу для быстрой карты (клавиатура или кнопки мыши: средняя, боковые)
        local vk
        if msg == 0x100 or msg == 0x104 then
            vk = wparam
        elseif msg == 0x207 then
            vk = 0x04
        elseif msg == 0x20B then
            local okB, xb = pcall(tog.bit.rshift, wparam, 16)
            vk = (okB and xb == 2) and 0x06 or 0x05
        elseif msg == 0x102 or msg == 0x105 then
            consumeWindowMessage(true, false) -- символ нажатой клавиши не нужен
        end
        if vk then
            consumeWindowMessage(true, false)
            m.binding = false
            if vk == 0x08 or vk == 0x2E then      -- Backspace / Delete: сбросить
                m.key = 0
                tog.saveMap()
            elseif vk ~= 0x1B then                 -- Esc: отмена
                m.key = vk
                tog.saveMap()
            end
        end
        return
    end
    if not window[0] then return end
    if msg == 0x100 and wparam == 0x1B then
        consumeWindowMessage(true, false)
        setOpen(false)
    end
end)

------------------------------------------------------------------
-- Основной поток
------------------------------------------------------------------
function main()
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('wss', function() setOpen(not window[0]) end)
    say('загружен. /wss - открыть меню статистики работ')
    if not sampev then say('не найдена библиотека SAMP.Lua - доход такси считаться не будет') end
    if tog.recovered then
        say(('найден незавершённый сеанс (после вылета игры): сохранён в историю, сеансов: %d'):format(tog.recovered))
    end
    tog.checkUpdate(true) -- тихая проверка обновлений при запуске

    while true do
        wait(200)
        tick()
        if not window[0] and locked then
            lockPlayerControl(false)
            locked = false
        end
    end
end

function onScriptTerminate(scr, quit)
    if scr == thisScript() then
        pcall(tog.finishAll) -- незавершённые сеансы - в историю (выход из игры, перезагрузка скрипта)
        saveStats()
        if locked then lockPlayerControl(false) end
    end
end
