script_name('WorkStats')
script_author('17avangard')
script_description('Подсчёт заработка за сеанс на работах Arizona RP. Команда: /wss')
script_version('1.34')

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
    globe = 0xF0AC,      -- earth-americas (язык)
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

-- autofind: раз в 3 секунды повторяет /find ID (ID берётся из последнего /find или /af ID)
tog.af = { on = false, id = nil, last = 0, t = 0, lastT = os.clock() }
tog.afPath = getWorkingDirectory() .. '\\config\\work_stats_af.cfg'
function tog.saveAf()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(tog.afPath, 'w')
    if not f then return end
    f:write((tog.af.on and '1' or '0') .. '\n' .. tostring(tog.af.id or '') .. '\n')
    f:close()
end
function tog.loadAf()
    local f = io.open(tog.afPath, 'r')
    if not f then return end
    local on, id = f:read('*l'), tonumber(f:read('*l') or '')
    f:close()
    tog.af.on = (on == '1')
    tog.af.id = id
end
tog.loadAf()
tog.af.t = tog.af.on and 1 or 0

-- стиль меню: 'classic' (прежний) или 'aurora' (новый WorkHelper)
tog.style, tog.styleOpen = 'classic', false
tog.stylePath = getWorkingDirectory() .. '\\config\\work_stats_style.cfg'
function tog.saveStyle()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(tog.stylePath, 'w')
    if not f then return end
    f:write(tog.style .. '\n')
    f:close()
end
function tog.loadStyle()
    local f = io.open(tog.stylePath, 'r')
    if not f then return end
    local v = f:read('*l')
    f:close()
    if v == 'aurora' then tog.style = 'aurora' end
end
tog.loadStyle()
function tog.afTick()
    local a = tog.af
    if not a.on or not a.id then return end
    if not isSampAvailable() or sampGetGamestate() ~= 3 then return end
    local now = os.clock()
    if now - a.last < 3 then return end
    a.last = now
    sampSendChat('/find ' .. a.id)
end

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

------------------------------------------------------------------
-- Локализация: ru / en / uk (выбор в настройках, хранится в work_stats_lang.cfg)
------------------------------------------------------------------
tog.LANGS = { 'ru', 'en', 'uk' }
tog.LANG_NAME = { ru = 'Русский', en = 'English', uk = 'Українська' }
tog.lang = 'ru'
tog.langPath = getWorkingDirectory() .. '\\config\\work_stats_lang.cfg'

tog.TR = {
    ru = {
        job_taxi = 'Таксист', job_oil = 'Нефтевышка', job_collect = 'Инкассатор',
        theme1 = 'Небо', theme2 = 'Фиалка', theme3 = 'Изумруд', theme4 = 'Океан',
        theme5 = 'Закат', theme6 = 'Сакура', theme7 = 'Золото', theme8 = 'AMOLED',
        sub_title = 'Статистика работ', jobs_hdr = 'РАБОТЫ',
        del_tip = 'Удалить работу', del_tip2 = 'Нажмите ещё раз - удалить работу и её историю',
        player = 'Игрок', settings = 'Настройки',
        upd_checking = 'Проверка...', upd_avail = 'Обновить до v%s', upd_loading = 'Скачивание...',
        upd_latest = 'Версия актуальна (v%s)', upd_err = 'Ошибка. Повторить', upd_check = 'Проверить обновления',
        tab_session = 'Сеанс', tab_history = 'История',
        chip_run = 'Сеанс идёт', chip_pause = 'На паузе',
        earned_session = 'Заработано за сеанс', net_profit = 'Чистая прибыль',
        time = 'Время', orders = 'Заказов', spent = 'Потрачено',
        rec_title = 'Незавершённый сеанс от %s', rec_line = 'Заработано %s  ·  %s  ·  заказов: %d',
        btn_continue = 'Продолжить', btn_to_history = 'В историю', btn_stop = 'Остановить',
        btn_start = 'Начать сеанс', btn_finish = 'Завершить сеанс',
        h_date = 'Дата', h_time = 'Время', h_orders = 'Заказов', h_income = 'Доход', h_expense = 'Расход', h_total = 'Итог',
        hist_empty = 'История пуста. Нажмите "Завершить сеанс", и он появится здесь.',
        clear_confirm = 'Нажмите ещё раз для подтверждения', clear_btn = 'Очистить историю и итоги',
        alltime = 'За всё время: +%s  /  -%s  ·  итог %s%s  ·  %s  ·  выплат: %d',
        set_general = 'Общие настройки',
        set_dist = 'Расстояние до метки', set_dist_sub = 'Показывать при наличии метки. Двигайте плашку мышью',
        set_pause = 'Автопауза', set_pause_sub = 'Пауза, если долго нет выплат',
        set_mini = 'Мини-окно', set_mini_sub = 'Доход и время сеанса поверх игры. Двигайте мышью',
        set_af = 'Autofind', set_af_sub = 'Повторять /find %d раз в 3 секунды', set_af_noid = 'Сначала введите /find ID или /af ID',
        set_style = 'Стиль меню', set_style_sub = 'Классический или новый WorkHelper', style_classic = 'Классический', style_aurora = 'WorkHelper', sub_aur = 'Ваш помощник в работе',
        set_map = 'Быстрая карта', map_sub_none = 'Назначьте клавишу справа', map_sub = 'Видна, пока зажата клавиша',
        key_press = 'Нажмите...', key_none = 'Не задана',
        key_tip = 'Нажмите, затем клавишу или кнопку мыши. Esc - отмена, Backspace - сбросить',
        set_lang = 'Язык', set_lang_sub = 'Язык интерфейса и сообщений',
        set_look = 'Оформление', set_theme = 'Тема оформления', set_theme_sub = 'Цветовая схема интерфейса', set_custom = 'Кастомизация',
        footer_bal = 'Баланс: %s  ·  Esc - закрыть', footer_nobal = 'Баланс не читается  ·  Esc - закрыть',
        unit_m = 'м', map_title = 'Карта', map_dist = '%s м до метки',
        map_err1 = 'Не удалось скачать карту', map_err2 = 'Проверьте интернет, повтор через минуту',
        map_load1 = 'Загрузка карты с GitHub...', map_load2 = 'Подождите несколько секунд',
        map_none = 'Нет изображения карты',
        msg_loaded = 'загружен. /wss - открыть меню статистики работ',
        msg_nosamp = 'не найдена библиотека SAMP.Lua - доход такси считаться не будет',
        msg_recovered = 'найден незавершённый сеанс (выход, вылет или кик). /wss - продолжить или сохранить в историю',
        msg_conn_lost = 'соединение потеряно - сеанс помечен незавершённым',
        msg_pending = 'есть незавершённый сеанс. /wss - продолжить или сохранить в историю',
        msg_autopause = 'автопауза: нет выплат %d мин. Время простоя вычтено',
        msg_upd_avail = 'доступно обновление v%s: /wss - Настройки',
        msg_upd_done = 'обновлено до v%s, перезагрузка...',
    },
    en = {
        job_taxi = 'Taxi driver', job_oil = 'Oil rig', job_collect = 'Collector',
        theme1 = 'Sky', theme2 = 'Violet', theme3 = 'Emerald', theme4 = 'Ocean',
        theme5 = 'Sunset', theme6 = 'Sakura', theme7 = 'Gold', theme8 = 'AMOLED',
        sub_title = 'Work statistics', jobs_hdr = 'JOBS',
        del_tip = 'Delete job', del_tip2 = 'Click again - delete the job and its history',
        player = 'Player', settings = 'Settings',
        upd_checking = 'Checking...', upd_avail = 'Update to v%s', upd_loading = 'Downloading...',
        upd_latest = 'Up to date (v%s)', upd_err = 'Error. Retry', upd_check = 'Check for updates',
        tab_session = 'Session', tab_history = 'History',
        chip_run = 'Session active', chip_pause = 'Paused',
        earned_session = 'Earned this session', net_profit = 'Net profit',
        time = 'Time', orders = 'Orders', spent = 'Spent',
        rec_title = 'Unfinished session from %s', rec_line = 'Earned %s  ·  %s  ·  orders: %d',
        btn_continue = 'Continue', btn_to_history = 'To history', btn_stop = 'Stop',
        btn_start = 'Start session', btn_finish = 'Finish session',
        h_date = 'Date', h_time = 'Time', h_orders = 'Orders', h_income = 'Income', h_expense = 'Expenses', h_total = 'Total',
        hist_empty = 'History is empty. Press "Finish session" and it will appear here.',
        clear_confirm = 'Click again to confirm', clear_btn = 'Clear history and totals',
        alltime = 'All time: +%s  /  -%s  ·  total %s%s  ·  %s  ·  payouts: %d',
        set_general = 'General settings',
        set_dist = 'Distance to marker', set_dist_sub = 'Shown when a marker exists. Drag the badge with the mouse',
        set_pause = 'Auto-pause', set_pause_sub = 'Pause if there are no payouts for a long time',
        set_mini = 'Mini window', set_mini_sub = 'Session income and time over the game. Drag with the mouse',
        set_af = 'Autofind', set_af_sub = 'Repeat /find %d every 3 seconds', set_af_noid = 'First type /find ID or /af ID',
        set_style = 'Menu style', set_style_sub = 'Classic or the new WorkHelper', style_classic = 'Classic', style_aurora = 'WorkHelper', sub_aur = 'Your work helper',
        set_map = 'Quick map', map_sub_none = 'Assign a key on the right', map_sub = 'Visible while the key is held',
        key_press = 'Press...', key_none = 'Not set',
        key_tip = 'Click, then press a key or mouse button. Esc - cancel, Backspace - clear',
        set_lang = 'Language', set_lang_sub = 'Interface and message language',
        set_look = 'Appearance', set_theme = 'Theme', set_theme_sub = 'Interface color scheme', set_custom = 'Customization',
        footer_bal = 'Balance: %s  ·  Esc - close', footer_nobal = 'Balance unavailable  ·  Esc - close',
        unit_m = 'm', map_title = 'Map', map_dist = '%s m to marker',
        map_err1 = 'Failed to download the map', map_err2 = 'Check your connection, retry in a minute',
        map_load1 = 'Loading map from GitHub...', map_load2 = 'Please wait a few seconds',
        map_none = 'No map image',
        msg_loaded = 'loaded. /wss - open the work statistics menu',
        msg_nosamp = 'SAMP.Lua library not found - taxi income will not be counted',
        msg_recovered = 'found an unfinished session (quit, crash or kick). /wss - continue or save to history',
        msg_conn_lost = 'connection lost - session marked as unfinished',
        msg_pending = 'you have an unfinished session. /wss - continue or save to history',
        msg_autopause = 'auto-pause: no payouts for %d min. Idle time subtracted',
        msg_upd_avail = 'update v%s available: /wss - Settings',
        msg_upd_done = 'updated to v%s, reloading...',
    },
    uk = {
        job_taxi = 'Таксист', job_oil = 'Нафтова вишка', job_collect = 'Інкасатор',
        theme1 = 'Небо', theme2 = 'Фіалка', theme3 = 'Смарагд', theme4 = 'Океан',
        theme5 = 'Захід', theme6 = 'Сакура', theme7 = 'Золото', theme8 = 'AMOLED',
        sub_title = 'Статистика робіт', jobs_hdr = 'РОБОТИ',
        del_tip = 'Видалити роботу', del_tip2 = 'Натисніть ще раз - видалити роботу та її історію',
        player = 'Гравець', settings = 'Налаштування',
        upd_checking = 'Перевірка...', upd_avail = 'Оновити до v%s', upd_loading = 'Завантаження...',
        upd_latest = 'Версія актуальна (v%s)', upd_err = 'Помилка. Повторити', upd_check = 'Перевірити оновлення',
        tab_session = 'Сеанс', tab_history = 'Історія',
        chip_run = 'Сеанс триває', chip_pause = 'На паузі',
        earned_session = 'Зароблено за сеанс', net_profit = 'Чистий прибуток',
        time = 'Час', orders = 'Замовлень', spent = 'Витрачено',
        rec_title = 'Незавершений сеанс від %s', rec_line = 'Зароблено %s  ·  %s  ·  замовлень: %d',
        btn_continue = 'Продовжити', btn_to_history = 'В історію', btn_stop = 'Зупинити',
        btn_start = 'Почати сеанс', btn_finish = 'Завершити сеанс',
        h_date = 'Дата', h_time = 'Час', h_orders = 'Замовлень', h_income = 'Дохід', h_expense = 'Витрати', h_total = 'Підсумок',
        hist_empty = "Історія порожня. Натисніть «Завершити сеанс», і він з'явиться тут.",
        clear_confirm = 'Натисніть ще раз для підтвердження', clear_btn = 'Очистити історію та підсумки',
        alltime = 'За весь час: +%s  /  -%s  ·  підсумок %s%s  ·  %s  ·  виплат: %d',
        set_general = 'Загальні налаштування',
        set_dist = 'Відстань до мітки', set_dist_sub = 'Показувати за наявності мітки. Рухайте плашку мишею',
        set_pause = 'Автопауза', set_pause_sub = 'Пауза, якщо довго немає виплат',
        set_mini = 'Міні-вікно', set_mini_sub = 'Дохід і час сеансу поверх гри. Рухайте мишею',
        set_af = 'Autofind', set_af_sub = 'Повторювати /find %d кожні 3 секунди', set_af_noid = 'Спершу введіть /find ID або /af ID',
        set_style = 'Стиль меню', set_style_sub = 'Класичний або новий WorkHelper', style_classic = 'Класичний', style_aurora = 'WorkHelper', sub_aur = 'Ваш помічник у роботі',
        set_map = 'Швидка карта', map_sub_none = 'Призначте клавішу праворуч', map_sub = 'Видно, поки затиснута клавіша',
        key_press = 'Натисніть...', key_none = 'Не задано',
        key_tip = 'Натисніть, потім клавішу або кнопку миші. Esc - скасувати, Backspace - скинути',
        set_lang = 'Мова', set_lang_sub = 'Мова інтерфейсу та повідомлень',
        set_look = 'Оформлення', set_theme = 'Тема оформлення', set_theme_sub = 'Кольорова схема інтерфейсу', set_custom = 'Кастомізація',
        footer_bal = 'Баланс: %s  ·  Esc - закрити', footer_nobal = 'Баланс не читається  ·  Esc - закрити',
        unit_m = 'м', map_title = 'Карта', map_dist = '%s м до мітки',
        map_err1 = 'Не вдалося завантажити карту', map_err2 = 'Перевірте інтернет, повтор через хвилину',
        map_load1 = 'Завантаження карти з GitHub...', map_load2 = 'Зачекайте кілька секунд',
        map_none = 'Немає зображення карти',
        msg_loaded = 'завантажено. /wss - відкрити меню статистики робіт',
        msg_nosamp = 'не знайдено бібліотеку SAMP.Lua - дохід таксі не рахуватиметься',
        msg_recovered = 'знайдено незавершений сеанс (вихід, виліт або кік). /wss - продовжити або зберегти в історію',
        msg_conn_lost = "з'єднання втрачено - сеанс позначено незавершеним",
        msg_pending = 'є незавершений сеанс. /wss - продовжити або зберегти в історію',
        msg_autopause = 'автопауза: немає виплат %d хв. Час простою віднято',
        msg_upd_avail = 'доступне оновлення v%s: /wss - Налаштування',
        msg_upd_done = 'оновлено до v%s, перезавантаження...',
    },
}

-- перевод по ключу; при нехватке строки берётся русский вариант
function tog.L(key, ...)
    local t = tog.TR[tog.lang]
    local s = (t and t[key]) or tog.TR.ru[key] or key
    if select('#', ...) > 0 then return s:format(...) end
    return s
end

-- название работы: встроенные переводятся, пользовательские остаются как введены
function tog.jobName(j)
    if j.builtin then return tog.L('job_' .. j.id) end
    return j.name
end

function tog.saveLang()
    pcall(createDirectory, getWorkingDirectory() .. '\\config')
    local f = io.open(tog.langPath, 'w')
    if not f then return end
    f:write(tog.lang .. '\n')
    f:close()
end

function tog.setLang(code)
    if tog.TR[code] and tog.lang ~= code then
        tog.lang = code
        tog.saveLang()
    end
end

function tog.loadLang()
    local f = io.open(tog.langPath, 'r')
    if not f then return end
    local code = (f:read('*l') or ''):match('^%s*(%a+)')
    f:close()
    if code and tog.TR[code] then tog.lang = code end
end
tog.loadLang()

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
local tab = 1             -- 1 = сеанс, 2 = история, 4 = настройки, 5 = организация
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
    sampAddChatMessage(u8:decode('[' .. (tog.style == 'aurora' and 'WorkHelper' or 'WorkStats') .. '] ' .. text), 0xFF779ECB)
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
    return firstChar(tog.jobName(j))
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
    if not v then tog.themeOpen = false; tog.langOpen = false; tog.styleOpen = false; tog.map.binding = false end
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
        log[#log + 1] = { job = id, ts = os.date('%d.%m_%H:%M:%S'), secs = math.floor(st.sSecs),
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
    if tog.pendingRecover then tog.pendingRecover[j.id] = nil end
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
-- Защита сеансов. Незавершённый сеанс НЕ попадает в историю сам:
--  * каждые 5 секунд он записывается в файл work_stats_active.cfg;
--  * выход из игры (/q), вылет, перезагрузка скрипта, кик, потеря соединения -
--    сеанс остаётся «незавершённым»;
--  * при следующем заходе (или сразу после переподключения) на вкладке «Сеанс»
--    нужной работы появляется баннер: «Продолжить» или «В историю».
-- Незавершённые сеансы хранятся в tog.pendingRecover и переживают сколько угодно перезапусков,
-- пока вы не решите их судьбу.
------------------------------------------------------------------
tog.activePath = getWorkingDirectory() .. '\\config\\work_stats_active.cfg'
tog.activeOn, tog.lastActive, tog.offSince, tog.recovered = false, os.clock(), nil, nil
tog.notify = false -- после кика/обрыва: напомнить в чате, когда соединение вернётся

function tog.hasData(st)
    return st and (st.sEarned > 0 or st.sSpent > 0 or st.sSecs > 5)
end

-- записать текущие сеансы и все ещё не решённые незавершённые; если их нет - удалить файл.
-- Возвращает true, если файл записан
function tog.saveActive()
    local lines = {}
    local nowTs = os.date('%d.%m_%H:%M:%S')
    for _, j in ipairs(JOBS) do
        local st = stats[j.id]
        if tog.hasData(st) then
            lines[#lines + 1] = ('%s %d %d %d %d %s'):format(j.id, math.floor(st.sSecs), math.floor(st.sEarned),
                math.floor(st.sSpent), st.sCount, nowTs)
        end
        local r = tog.pendingRecover and tog.pendingRecover[j.id]
        if r then
            lines[#lines + 1] = ('%s %d %d %d %d %s'):format(j.id, math.floor(r.secs), math.floor(r.earned),
                math.floor(r.spent), r.count, r.ts)
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

tog.pendingRecover = {} -- [id] = { secs, earned, spent, count, ts }

-- положить сеанс в «незавершённые» (если там уже есть сеанс этой работы - суммируем)
function tog.stash(id, r)
    local p = tog.pendingRecover[id]
    if p then
        p.secs, p.earned, p.spent, p.count = p.secs + r.secs, p.earned + r.earned, p.spent + r.spent, p.count + r.count
    else
        tog.pendingRecover[id] = r
    end
end

-- при запуске: читаем файл прошлых сеансов (выход, вылет, перезагрузка) и ставим их в «незавершённые»
function tog.recoverActive()
    local f = io.open(tog.activePath, 'r')
    if not f then return end
    local head = f:read('*l') or ''
    local savedAt = tonumber(head:match('^T (%d+)')) or os.time()
    local headTs = os.date('%d.%m_%H:%M:%S', savedAt)
    local n = 0
    for line in f:lines() do
        local id, secs, earned, spent, count, ts = line:match('^(%w+) (%d+) (%d+) (%d+) (%d+) ?(%S*)')
        if id and stats[id] then
            tog.stash(id, { secs = tonumber(secs), earned = tonumber(earned), spent = tonumber(spent),
                            count = tonumber(count), ts = (ts ~= '' and ts) or headTs })
            n = n + 1
        end
    end
    f:close()
    if n > 0 then
        tog.activeOn = true -- файл остаётся, пока вы не решите судьбу сеанса
        tog.recovered = n
        -- сразу выбираем работу с незавершённым сеансом, чтобы баннер был виден
        for i, j in ipairs(JOBS) do
            if tog.pendingRecover[j.id] then selected = i; break end
        end
    else
        os.remove(tog.activePath)
    end
end
tog.recoverActive()

-- человек решил: продолжить найденный сеанс (true) или сохранить его в историю (false)
function tog.resolveRecover(id, continueIt)
    local r = tog.pendingRecover[id]
    if not r then return end
    tog.pendingRecover[id] = nil
    if continueIt then
        local s = stats[id]
        s.sEarned, s.sSecs = s.sEarned + r.earned, s.sSecs + r.secs
        s.sCount, s.sSpent = s.sCount + r.count, s.sSpent + r.spent
        running = id
        tog.act = os.clock()
        lastMoney = readMoney()
        lastTick = os.clock()
        for i, j in ipairs(JOBS) do
            if j.id == id then selected = i end
        end
    else
        log[#log + 1] = { job = id, ts = r.ts, secs = math.floor(r.secs), earned = math.floor(r.earned),
                          spent = math.floor(r.spent), count = r.count }
        while #log > 300 do table.remove(log, 1) end
        saveLog()
    end
    tog.saveActive()
    saveStats()
end

-- кик / обрыв связи: сеансы НЕ идут в историю, а помечаются незавершёнными
-- (баннер «Продолжить / В историю» на вкладке «Сеанс»)
function tog.suspendAll(reason)
    local n, last = 0, nil
    for i, j in ipairs(JOBS) do
        local st = stats[j.id]
        if tog.hasData(st) then
            tog.stash(j.id, { secs = math.floor(st.sSecs), earned = math.floor(st.sEarned),
                spent = math.floor(st.sSpent), count = st.sCount, ts = os.date('%d.%m_%H:%M:%S') })
            resetSession(j.id)
            n, last = n + 1, i
        end
    end
    running = nil
    if n > 0 then
        selected = last
        tog.notify = true
        tog.saveActive()
        saveStats()
        if reason then pcall(say, reason) end
    end
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
                if u.silent then say(tog.L('msg_upd_avail', v)) end
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
                u.reloadAt = os.clock() + 1.5 -- даём закрыться меню и дорисоваться кадру
                say(tog.L('msg_upd_done', tostring(u.remote)))
                setOpen(false)
            else
                u.st = 'err'
            end
        elseif os.clock() - u.t0 > 60 then
            u.st = 'err'
        end
    elseif u.st == 'reload' then
        if u.reloadAt and os.clock() >= u.reloadAt and not window[0] then
            u.reloadAt = nil
            -- если запущен ML-AutoReboot, он сам перезагрузит скрипт при смене файла
            local okF, other = pcall(script.find, 'ML-AutoReboot')
            if not (okF and other) then thisScript():reload() end
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
    tog.afTick()

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

    -- кик / обрыв соединения: сеанс не идёт в историю, а помечается незавершённым
    -- (потом его можно продолжить на вкладке «Сеанс»)
    if isSampAvailable() and sampGetGamestate() ~= 3 then
        tog.offSince = tog.offSince or now
        if now - tog.offSince > 3 then
            tog.suspendAll(tog.L('msg_conn_lost'))
            tog.icons = {}
        end
    else
        tog.offSince = nil
        -- соединение вернулось: напоминаем, что есть сеанс, который можно продолжить
        if tog.notify and next(tog.pendingRecover) then
            tog.notify = false
            say(tog.L('msg_pending'))
        end
    end

    -- автопауза: долго нет выплат
    if tog.pause and running and now - tog.act > tog.pauseSec then
        local s = stats[running]
        s.sSecs = math.max(0, s.sSecs - tog.pauseSec)
        s.secs = math.max(0, s.secs - tog.pauseSec)
        running = nil
        saveStats()
        say(tog.L('msg_autopause', tog.pauseSec / 60))
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
        dl:AddRectFilled(pos, p2, tog.aU(math.min(1, ACCENT[1] * k), math.min(1, ACCENT[2] * k), math.min(1, ACCENT[3] * k), 1), r)
        if tog.style == 'aurora' then
            tog.aHalf(dl, pos, p2, tog.aU(1, 1, 1, 0.14), r, true) -- блик сверху
        end
        tc = tog.aU(0.07, 0.08, 0.10, 1)
    else
        dl:AddRectFilled(pos, p2, tog.aU(1, 1, 1, 0.03 + 0.03 * hA + 0.02 * aA), r)
        dl:AddRect(pos, p2, tog.aU(1, 1, 1, 0.09 + 0.07 * hA), r)
        tc = tog.aU(0.82, 0.84, 0.88, 1)
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
    if tog.style == 'aurora' then
        dl:AddRectFilled(pos, imgui.ImVec2(pos.x + w, pos.y + h), U32(1, 1, 1, 0.045), 14 * scale)
        dl:AddRect(pos, imgui.ImVec2(pos.x + w, pos.y + h), U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.20), 14 * scale)
    else
        dl:AddRectFilled(pos, imgui.ImVec2(pos.x + w, pos.y + h), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
    end
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

------------------------------------------------------------------
-- Выпадающие списки (язык, тема). Список - отдельное окно поверх меню: клики не
-- проваливаются на элементы под ним, он не выходит за границы основного окна,
-- а длинный список плавно прокручивается колесом мыши.
------------------------------------------------------------------
tog.dd, tog.ddIn, tog.ddReq = {}, {}, {}

function tog.ddRender()
    local reqs = tog.ddReq
    tog.ddReq = {}
    for _, d in ipairs(reqs) do
        local st = tog.dd[d.id]
        if not st then
            st = { target = 0, cur = 0, last = os.clock(), was = false }
            tog.dd[d.id] = st
        end
        local a = d.alpha
        if a <= 0.01 then
            st.was = false
            tog.ddIn[d.id] = false
        else
            local ipad, ih, ig = 6 * scale, 28 * scale, 2 * scale
            local n = #d.items
            local contentH = n * ih + (n - 1) * ig
            local desired = math.min(contentH + ipad * 2, d.maxRows * (ih + ig) - ig + ipad * 2)
            local below, above = d.bound - d.y, d.yUp - d.top
            local up = below < desired and above > below
            local maxH = math.max(math.min(desired, up and above or below), ih + ipad * 2)
            local py = up and (d.yUp - maxH) or d.y
            local innerH = maxH - ipad * 2
            local maxScroll = math.max(0, contentH - innerH)
            -- при открытии выбранный пункт сразу оказывается в видимой части
            if d.open and not st.was then
                local si = 1
                for i, it in ipairs(d.items) do
                    if it.sel then si = i end
                end
                st.target = math.max(0, math.min(maxScroll, (si - 1) * (ih + ig) - (innerH - ih) / 2))
                st.cur = st.target
            end
            st.was = d.open
            local now = os.clock()
            local dt = math.min(0.05, now - st.last)
            st.last = now

            imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12 * scale)
            imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
            imgui.PushStyleColor(imgui.Col.WindowBg, V4(0, 0, 0, 0))
            imgui.PushStyleColor(imgui.Col.Border, V4(0, 0, 0, 0))
            imgui.SetNextWindowPos(imgui.ImVec2(d.x, py + (1 - a) * (up and 8 or -8) * scale), imgui.Cond.Always)
            imgui.SetNextWindowSize(imgui.ImVec2(d.w, maxH), imgui.Cond.Always)
            local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
                + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoScrollbar
                + imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoMove
            if not d.open then flags = flags + imgui.WindowFlags.NoInputs end
            imgui.Begin('###WSdd' .. d.id, nil, flags)

            local wp = imgui.GetWindowPos()
            local pdl = imgui.GetWindowDrawList()
            local lh = imgui.GetTextLineHeight()
            local hovWin = imgui.IsWindowHovered()
            local w0 = imgui.ImVec2(wp.x, wp.y)
            local w1 = imgui.ImVec2(wp.x + d.w, wp.y + maxH)
            local rad = 12 * scale
            pdl:AddRectFilled(w0, w1, U32(math.min(1, BG[1] + 0.035), math.min(1, BG[2] + 0.035), math.min(1, BG[3] + 0.04), 0.99 * a), rad)
            pdl:AddRect(imgui.ImVec2(wp.x + 0.5, wp.y + 0.5), imgui.ImVec2(w1.x - 0.5, w1.y - 0.5),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.35 * a), rad, 15, 1)

            -- плавная прокрутка колесом мыши
            if hovWin and d.open and maxScroll > 0 then
                local wheel = imgui.GetIO().MouseWheel
                if wheel ~= 0 then st.target = st.target - wheel * (ih + ig) * 1.5 end
            end
            st.target = math.max(0, math.min(maxScroll, st.target))
            st.cur = st.cur + (st.target - st.cur) * (1 - math.exp(-dt * 14))
            if math.abs(st.target - st.cur) < 0.3 then st.cur = st.target end

            local c0 = imgui.ImVec2(wp.x, wp.y + ipad)
            local c1 = imgui.ImVec2(wp.x + d.w, wp.y + maxH - ipad)
            imgui.PushClipRect(c0, c1, true)
            local right = wp.x + d.w - ipad - ((maxScroll > 0) and 6 * scale or 0)
            local picked
            for i, it in ipairs(d.items) do
                local iy = wp.y + ipad + (i - 1) * (ih + ig) - st.cur
                if iy + ih > c0.y and iy < c1.y then
                    local q0, q1 = imgui.ImVec2(wp.x + ipad, iy), imgui.ImVec2(right, iy + ih)
                    local hov = d.open and hovWin and imgui.IsMouseHoveringRect(q0, q1)
                    local hA = animTo('ddh' .. d.id .. i, hov and 1 or 0, 14)
                    local sA = animTo('dds' .. d.id .. i, it.sel and 1 or 0, 12)
                    local ac = it.accent or ACCENT
                    pdl:AddRectFilled(q0, q1, U32(1, 1, 1, 0.07 * hA * (1 - sA) * a), 8 * scale)
                    if sA > 0.01 then pdl:AddRectFilled(q0, q1, U32(ac[1], ac[2], ac[3], 0.16 * sA * a), 8 * scale) end
                    local tx = q0.x + 12 * scale
                    if it.dots then
                        for k, c in ipairs(it.dots) do
                            pdl:AddCircleFilled(imgui.ImVec2(q0.x + 16 * scale + (k - 1) * 12 * scale, iy + ih / 2), 4.5 * scale,
                                U32(c[1], c[2], c[3], a), 14)
                        end
                        tx = q0.x + 16 * scale + 3 * 12 * scale
                    end
                    local ty = iy + (ih - lh) / 2
                    local tr, tg, tb = mixRGB({ 0.82, 0.84, 0.88 }, { 0.96, 0.97, 0.99 }, hA)
                    pdl:AddText(imgui.ImVec2(tx, ty), U32(lerp(tr, ac[1], sA), lerp(tg, ac[2], sA), lerp(tb, ac[3], sA), a), it.name)
                    if sA > 0.02 then
                        drawText(pdl, imgui.ImVec2(q1.x - 24 * scale, ty), U32(ac[1], ac[2], ac[3], sA * a), ic('check'))
                    end
                    if hov and a > 0.6 and imgui.IsMouseClicked(0) then picked = i end
                end
            end
            -- ползунок прокрутки
            if maxScroll > 0 then
                local barH = math.max(18 * scale, innerH * innerH / contentH)
                local by0 = wp.y + ipad + (innerH - barH) * (st.cur / maxScroll)
                pdl:AddRectFilled(imgui.ImVec2(wp.x + d.w - 6 * scale, by0), imgui.ImVec2(wp.x + d.w - 3 * scale, by0 + barH),
                    U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.45 * a), 2 * scale)
            end
            imgui.PopClipRect()

            tog.ddIn[d.id] = imgui.IsMouseHoveringRect(w0, w1, false)
            imgui.End()
            imgui.PopStyleColor(2)
            imgui.PopStyleVar(2)
            if picked then
                d.pick(picked)
                tog[d.okey] = false
            end
        end
    end
end

------------------------------------------------------------------
-- WorkHelper: НОВЫЙ макет меню (не перекраска классики).
-- Без боковой панели: шапка с чипами работ, герой-карта с живой линией пульса,
-- плитки метрик, сегмент-переключатель и нижняя панель действий.
------------------------------------------------------------------
tog.TR.ru.per_hour, tog.TR.en.per_hour, tog.TR.uk.per_hour = 'В час', 'Per hour', 'За годину'

------------------------------------------------------------------
-- Общие помощники анимации и «чёткой» отрисовки
------------------------------------------------------------------
tog.auA, tog.auC, tog.auCT = 1, 1, 10          -- общая прозрачность окна / элемента, время с последней смены вкладки
tog.auT0, tog.auLast, tog.auKT, tog.auKey = 0, -10, 0, ''
tog.auNum, tog.auHL, tog.auRec = {}, nil, nil

function tog.aU(r, g, b, a) return U32(r, g, b, (a or 1) * tog.auA * tog.auC) end

-- прямоугольники по целым пикселям: заливка без «мыла», обводка ровно по краю заливки
function tog.aF(dl, p0, p1, col, rr, fl)
    local a = imgui.ImVec2(math.floor(p0.x + 0.5), math.floor(p0.y + 0.5))
    local b = imgui.ImVec2(math.floor(p1.x + 0.5), math.floor(p1.y + 0.5))
    if fl then dl:AddRectFilled(a, b, col, rr or 0, fl)
    elseif rr then dl:AddRectFilled(a, b, col, rr)
    else dl:AddRectFilled(a, b, col) end
end
function tog.aR(dl, p0, p1, col, rr, fl, th)
    local a = imgui.ImVec2(math.floor(p0.x + 0.5) + 0.5, math.floor(p0.y + 0.5) + 0.5)
    local b = imgui.ImVec2(math.floor(p1.x + 0.5) - 0.5, math.floor(p1.y + 0.5) - 0.5)
    if th then dl:AddRect(a, b, col, rr or 0, fl or 15, th)
    elseif rr then dl:AddRect(a, b, col, rr)
    else dl:AddRect(a, b, col) end
end

-- половина скруглённого прямоугольника (top=true - верхняя, false - нижняя) через обрезку:
-- не зависит от флагов углов конкретной версии imgui
function tog.aHalf(dl, p0, p1, col, rr, top)
    local V2 = imgui.ImVec2
    local a = V2(math.floor(p0.x + 0.5), math.floor(p0.y + 0.5))
    local b = V2(math.floor(p1.x + 0.5), math.floor(p1.y + 0.5))
    local my = math.floor((a.y + b.y) / 2)
    if top then dl:PushClipRect(a, V2(b.x, my), true) else dl:PushClipRect(V2(a.x, my), b, true) end
    dl:AddRectFilled(a, b, col, rr)
    dl:PopClipRect()
end

-- каскадное появление элемента номер i (0 - первый): задаёт прозрачность и возвращает прогресс 0..1
function tog.auSt(i)
    local p = math.max(0, math.min(1, (tog.auCT - 0.07 * i) / 0.45))
    local e = 1 - (1 - p) ^ 3
    tog.auC = e
    return e
end

-- плавно «накручивающееся» число
function tog.auN(key, target)
    local e = tog.auNum[key]
    if not e then e = { v = target }; tog.auNum[key] = e end
    e.v = e.v + (target - e.v) * (1 - math.exp(-hvDt * 7))
    if math.abs(target - e.v) < 0.5 then e.v = target end
    return e.v
end

-- форма одного "удара" пульса (ЭКГ), p - фаза 0..1
function tog.auBeat(p)
    p = p % 1
    local e = math.exp
    return 0.12 * e(-((p - 0.18) ^ 2) / 0.004) - 0.14 * e(-((p - 0.36) ^ 2) / 0.0012)
        + 1.00 * e(-((p - 0.40) ^ 2) / 0.0008) - 0.32 * e(-((p - 0.44) ^ 2) / 0.0012)
        + 0.22 * e(-((p - 0.66) ^ 2) / 0.006)
end

function tog.auLogo(dl, x, y, lg)
    local V2 = imgui.ImVec2
    local t = os.clock()
    local br = 0.5 + 0.5 * math.sin(t * 1.6)
    for gi = 1, 6 do -- дышащее свечение
        tog.aF(dl, V2(x - gi * 1.6 * scale, y - gi * 1.6 * scale), V2(x + lg + gi * 1.6 * scale, y + lg + gi * 1.6 * scale),
            tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.012 + 0.02 * br), (12 + gi * 1.6) * scale)
    end
    local r = 12 * scale
    local p0, p1 = V2(x, y), V2(x + lg, y + lg)
    tog.aF(dl, p0, p1, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 1), r)
    tog.aHalf(dl, p0, p1, tog.aU(0.10, 0.12, 0.30, 0.22), r, false) -- тень снизу
    tog.aHalf(dl, p0, p1, tog.aU(1, 1, 1, 0.16), r, true)           -- блик сверху
    tog.aR(dl, p0, p1, tog.aU(1, 1, 1, 0.22), r)                    -- тонкая светлая кромка

    -- блик, пробегающий по значку раз в несколько секунд
    local ph = (t % 4.5) / 1.5
    if ph < 1 then
        dl:PushClipRect(V2(x + 2 * scale, y + 2 * scale), V2(x + lg - 2 * scale, y + lg - 2 * scale), true)
        local bx = x + lg * (-0.35 + 1.7 * ph)
        local sw, sl = lg * 0.16, lg * 0.5
        dl:AddQuadFilled(V2(bx, y), V2(bx + sw, y), V2(bx + sw - sl, y + lg), V2(bx - sl, y + lg),
            tog.aU(1, 1, 1, 0.28 * math.sin(math.pi * ph)))
        dl:PopClipRect()
    end

    -- три растущих столбика (доход), слегка «дышат»
    local base, bw = y + lg * 0.80, lg * 0.17
    local hs = { 0.20, 0.34, 0.48 }
    for k = 1, 3 do
        local bx = x + lg * (0.20 + (k - 1) * 0.20)
        local hgt = lg * hs[k] * (0.93 + 0.07 * math.sin(t * 2.2 + k * 0.9))
        tog.aF(dl, V2(bx, base - hgt), V2(bx + bw, base), tog.aU(0.07, 0.08, 0.12, 0.50 + 0.17 * k), 2 * scale)
    end

    -- мерцающая искра («помощник»)
    local tw = 0.5 + 0.5 * math.sin(t * 3.2)
    local px, py = x + lg * 0.76, y + lg * 0.17
    local sr = lg * (0.06 + 0.04 * tw)
    local sc = tog.aU(1, 1, 1, 0.55 + 0.45 * tw)
    dl:AddLine(V2(px - sr, py), V2(px + sr, py), sc, 1.6 * scale)
    dl:AddLine(V2(px, py - sr), V2(px, py + sr), sc, 1.6 * scale)
    dl:AddCircleFilled(V2(px, py), 1.4 * scale, sc, 8)
end

-- переключатель (абсолютные экранные координаты)
function tog.auSwitch(dl, id, x, y, on)
    local V2 = imgui.ImVec2
    local w, h = 40 * scale, 22 * scale
    local t = animTo('auSw' .. id, on and 1 or 0, 16)
    if t > 0 then
        tog.aF(dl, V2(x - 3 * scale, y - 3 * scale), V2(x + w + 3 * scale, y + h + 3 * scale),
            tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 * t), h / 2 + 3 * scale)
    end
    tog.aF(dl, V2(x, y), V2(x + w, y + h), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 + 0.84 * t), h / 2)
    tog.aR(dl, V2(x, y), V2(x + w, y + h), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.40 * (1 - t)), h / 2)
    dl:AddCircleFilled(V2(x + h / 2 + (w - h) * t, y + h / 2), h / 2 - 3 * scale,
        tog.aU(ACCENT[1] + (0.07 - ACCENT[1]) * t, ACCENT[2] + (0.08 - ACCENT[2]) * t, ACCENT[3] + (0.10 - ACCENT[3]) * t, 0.75 + 0.25 * t), 16)
end

-- плитка настройки: иконка-бейдж, заголовок, подпись, (необязательно) переключатель. Возвращает клик
function tog.auTile(dl, id, x, y, w, h, icon, title, sub, on, extra)
    local V2 = imgui.ImVec2
    imgui.SetCursorScreenPos(V2(x, y))
    local clicked = imgui.InvisibleButton('##au' .. id, V2(w, h))
    local hovered = imgui.IsItemHovered()
    local hA = animTo('auTh' .. id, hovered and 1 or 0, 14)
    local lh = imgui.GetTextLineHeight()
    local p0, p1 = V2(x, y), V2(x + w, y + h)
    tog.aF(dl, p0, p1, tog.aU(1, 1, 1, 0.04 + 0.025 * hA), 14 * scale)
    tog.aR(dl, p0, p1, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.14 + 0.24 * hA), 14 * scale)
    local bs = 36 * scale
    local b0 = V2(x + 14 * scale, y + (h - bs) / 2)
    tog.aF(dl, b0, V2(b0.x + bs, b0.y + bs), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 + 0.08 * hA), 11 * scale)
    drawBadgeGlyph(dl, b0.x + bs / 2, b0.y + bs / 2, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 1), ic(icon))
    local tx = b0.x + bs + 12 * scale
    local aw = x + w - 14 * scale - tx - ((on ~= nil) and 54 * scale or 0) - (extra or 0)
    local subF = fitText(sub, aw)
    dl:AddText(V2(tx, y + h / 2 - lh - 1 * scale), tog.aU(0.92, 0.93, 0.96, 1), fitText(title, aw))
    dl:AddText(V2(tx, y + h / 2 + 2 * scale), tog.aU(0.55, 0.57, 0.63, 1), subF)
    if hovered and subF ~= sub then imgui.SetTooltip(sub) end
    if on ~= nil then tog.auSwitch(dl, id, x + w - 14 * scale - 40 * scale, y + (h - 22 * scale) / 2, on) end
    return clicked
end

-- плитка с выпадающим списком (окно списка рисует tog.ddRender)
function tog.auField(dl, c, id, okey, x, y, w, h, selW, icon, title, sub, curText, dots, items, pick)
    local V2 = imgui.ImVec2
    local lh = imgui.GetTextLineHeight()
    local selH = math.floor(30 * scale)
    local selX, selY = x + w - 14 * scale - selW, y + (h - selH) / 2
    imgui.SetCursorScreenPos(V2(selX, selY))
    local clicked = imgui.InvisibleButton('##ausel' .. id, V2(selW, selH))
    local hov = imgui.IsItemHovered()
    if clicked then
        local v = not tog[okey]
        tog.langOpen, tog.themeOpen, tog.styleOpen = false, false, false
        tog[okey] = v
    end
    tog.auTile(dl, 'f' .. id, x, y, w, h, icon, title, sub, nil, selW + 18 * scale)
    local isOpen = tog[okey]
    local a = animTo('auFa' .. id, isOpen and 1 or 0, nil, 0.16)
    local sh = animTo('auFs' .. id, hov and 1 or 0, 14)
    local s0, s1 = V2(selX, selY), V2(selX + selW, selY + selH)
    tog.aF(dl, s0, s1, tog.aU(1, 1, 1, 0.05 + 0.04 * sh), 8 * scale)
    if a > 0.01 then tog.aF(dl, s0, s1, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.14 * a), 8 * scale) end
    tog.aR(dl, s0, s1, tog.aU(lerp(1, ACCENT[1], a), lerp(1, ACCENT[2], a), lerp(1, ACCENT[3], a), lerp(0.12 + 0.10 * sh, 0.9, a)), 8 * scale, 15, 1)
    local tx = selX + 12 * scale
    if dots then
        for k, col in ipairs(dots) do
            dl:AddCircleFilled(V2(selX + 16 * scale + (k - 1) * 12 * scale, selY + selH / 2), 4.5 * scale, tog.aU(col[1], col[2], col[3], 1), 14)
        end
        tx = selX + 16 * scale + 3 * 12 * scale
    end
    dl:AddText(V2(tx, selY + (selH - lh) / 2), tog.aU(0.92, 0.93, 0.96, 1), fitText(curText, selX + selW - 34 * scale - tx))
    local chx, chy, chs = selX + selW - 17 * scale, selY + selH / 2, 3.5 * scale
    local cdir = 1 - 2 * a
    local chc = tog.aU(lerp(0.65, ACCENT[1], a), lerp(0.67, ACCENT[2], a), lerp(0.73, ACCENT[3], a), 1)
    dl:AddLine(V2(chx - chs, chy - cdir * chs / 2), V2(chx, chy + cdir * chs / 2), chc, 2)
    dl:AddLine(V2(chx, chy + cdir * chs / 2), V2(chx + chs, chy - cdir * chs / 2), chc, 2)
    if isOpen and imgui.IsMouseClicked(0) and not hov and not tog.ddIn[id] then tog[okey] = false end
    tog.ddReq[#tog.ddReq + 1] = { id = id, okey = okey, alpha = a, open = isOpen, x = selX, y = selY + selH + 4 * scale, w = selW,
        bound = c.wp.y + c.H - 10 * scale, yUp = selY - 4 * scale, top = c.wp.y + 10 * scale, maxRows = 5, items = items, pick = pick }
end

-- плитка метрики (значок, подпись, крупное значение)
function tog.auStat(dl, x, y, w, h, icon, label, value, col)
    local V2 = imgui.ImVec2
    local p0, p1 = V2(x, y), V2(x + w, y + h)
    local hA = animTo('auStH' .. icon, imgui.IsMouseHoveringRect(p0, p1) and 1 or 0, 14)
    tog.aF(dl, p0, p1, tog.aU(1, 1, 1, 0.04 + 0.03 * hA), 16 * scale)
    tog.aR(dl, p0, p1, tog.aU(col[1], col[2], col[3], 0.22 + 0.28 * hA), 16 * scale)
    local bs = 34 * scale
    local b0 = V2(x + 16 * scale, y + 16 * scale)
    tog.aF(dl, b0, V2(b0.x + bs, b0.y + bs), tog.aU(col[1], col[2], col[3], 0.16), 11 * scale)
    drawBadgeGlyph(dl, b0.x + bs / 2, b0.y + bs / 2, tog.aU(col[1], col[2], col[3], 1), ic(icon))
    dl:AddText(V2(x + 16 * scale, b0.y + bs + 10 * scale), tog.aU(0.55, 0.57, 0.63, 1), fitText(label, w - 32 * scale))
    if fontTitle then imgui.PushFont(fontTitle) end
    dl:AddText(V2(x + 16 * scale, y + h - imgui.GetTextLineHeight() - 16 * scale), tog.aU(0.93, 0.94, 0.97, 1), fitText(value, w - 32 * scale))
    if fontTitle then imgui.PopFont() end
end

------------------------------------------------------------------
-- Шапка: логотип + чипы работ (или «назад» + заголовок в настройках) и кнопки справа
------------------------------------------------------------------
function tog.auHeader(c)
    local V2 = imgui.ImVec2
    local L, wp, dl, W, PAD = tog.L, c.wp, c.dl, c.W, c.PAD
    local cb = math.floor(34 * scale)
    local hy = math.floor(18 * scale)

    -- правая группа: [обновление] [карточка игрока] [шестерёнка] [закрыть]
    local rx = W - PAD - cb
    imgui.SetCursorPos(V2(rx, hy))
    if styledButton('##auclose', ic('winclose'), cb, cb, false) then setOpen(false) end
    rx = rx - 8 * scale - cb
    imgui.SetCursorPos(V2(rx, hy))
    if styledButton('##augear', ic('gear'), cb, cb, tab == 4) then
        if tab == 4 then
            tab = tog.prevTab or 1
            tog.themeOpen, tog.langOpen, tog.styleOpen = false, false, false
        else
            tog.prevTab = tab
            tab = 4
        end
    end

    -- карточка игрока слева от шестерёнки: иконка аккаунта, ник и ID
    do
        local nick = (me.nick ~= '') and me.nick or L('player')
        local idStr = (me.id >= 0) and ('ID ' .. me.id) or 'ID -'
        local lhH = imgui.GetTextLineHeight()
        local av = cb - 8 * scale
        local nickW = math.min(imgui.CalcTextSize(nick).x, 84 * scale)
        local idW = imgui.CalcTextSize(idStr).x + 14 * scale
        local cw = math.floor(4 * scale + av + 8 * scale + nickW + 8 * scale + idW + 6 * scale)
        rx = rx - 8 * scale - cw
        local x0, y0 = wp.x + rx, wp.y + hy
        local p0, p1 = V2(x0, y0), V2(x0 + cw, y0 + cb)
        local hov = imgui.IsMouseHoveringRect(p0, p1)
        local hA = animTo('auPlayer', hov and 1 or 0, 14)
        tog.aF(dl, p0, p1, tog.aU(1, 1, 1, 0.05 + 0.03 * hA), cb / 2)
        tog.aR(dl, p0, p1, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.22 + 0.20 * hA), cb / 2)

        -- аватар с иконкой аккаунта и точкой «в сети»
        local ac = V2(x0 + 4 * scale + av / 2, y0 + cb / 2)
        dl:AddCircleFilled(ac, av / 2, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.20), 24)
        dl:AddCircle(ac, av / 2, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.65), 24, 1.2)
        local glyph = (iconsOk and ic('user') ~= '') and ic('user') or firstChar(nick)
        drawBadgeGlyph(dl, ac.x, ac.y, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 1), glyph)
        if me.id >= 0 then
            local dp = V2(ac.x + av * 0.36, ac.y + av * 0.36)
            dl:AddCircleFilled(dp, 4.4 * scale, tog.aU(0.05, 0.054, 0.078, 1), 12)
            dl:AddCircleFilled(dp, 3.0 * scale, tog.aU(GREEN[1], GREEN[2], GREEN[3], 1), 12)
        end

        -- ник и ID
        local nx = x0 + 4 * scale + av + 8 * scale
        dl:AddText(V2(nx, y0 + (cb - lhH) / 2), tog.aU(0.92, 0.93, 0.96, 1), fitText(nick, nickW))
        local ix = nx + nickW + 8 * scale
        local ch = lhH + 6 * scale
        tog.aF(dl, V2(ix, y0 + (cb - ch) / 2), V2(ix + idW, y0 + (cb + ch) / 2), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.16), ch / 2)
        dl:AddText(V2(ix + 7 * scale, y0 + (cb - lhH) / 2), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 1), idStr)
        if hov then imgui.SetTooltip(nick .. '  ·  ' .. idStr) end
    end

    if tab == 4 then
        local up, lbl = tog.up, nil
        if up.st == 'checking' then lbl = L('upd_checking')
        elseif up.st == 'avail' then lbl = icl('download', L('upd_avail', tostring(up.remote)))
        elseif up.st == 'loading' or up.st == 'reload' then lbl = L('upd_loading')
        elseif up.st == 'latest' then lbl = L('upd_latest', thisScript().version)
        elseif up.st == 'err' then lbl = L('upd_err')
        else lbl = icl('sync', L('upd_check')) end
        local ubw = math.floor(textWidth(lbl) + 32 * scale)
        rx = rx - 8 * scale - ubw
        imgui.SetCursorPos(V2(rx, hy))
        if styledButton('##auupd', lbl, ubw, cb, up.st == 'avail') then
            if up.st == 'avail' then
                tog.upStart('loading')
            elseif up.st ~= 'checking' and up.st ~= 'loading' and up.st ~= 'reload' then
                tog.checkUpdate(false)
            end
        end
    end

    if tab == 4 then
        imgui.SetCursorPos(V2(PAD, hy))
        if styledButton('##auback', ic('back'), cb, cb, false) then
            tab = tog.prevTab or 1
            tog.themeOpen, tog.langOpen, tog.styleOpen = false, false, false
        end
        if fontTitle then imgui.PushFont(fontTitle) end
        local tlh = imgui.GetTextLineHeight()
        dl:AddText(V2(wp.x + PAD + cb + 14 * scale, wp.y + hy + (cb - tlh) / 2), tog.aU(0.94, 0.95, 0.98, 1), L('settings'))
        if fontTitle then imgui.PopFont() end
    else
        tog.auLogo(dl, wp.x + PAD, wp.y + hy, cb)
        if fontTitle then imgui.PushFont(fontTitle) end
        local tlh = imgui.GetTextLineHeight()
        local nx = wp.x + PAD + cb + 10 * scale
        local wW = imgui.CalcTextSize('Work').x
        local pW = imgui.CalcTextSize('Helper').x
        dl:AddText(V2(nx, wp.y + hy + (cb - tlh) / 2), tog.aU(0.95, 0.96, 0.99, 1), 'Work')
        dl:AddText(V2(nx + wW, wp.y + hy + (cb - tlh) / 2), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 1), 'Helper')
        if fontTitle then imgui.PopFont() end

        -- чипы работ
        local chipsX = nx + wW + pW + 26 * scale
        local availW = wp.x + rx - 14 * scale - chipsX
        local n, gapC = #JOBS, 6 * scale
        local nat, tot = {}, 0
        for i, j in ipairs(JOBS) do
            nat[i] = (10 + 22 + 8 + (j.builtin and 14 or 34)) * scale + imgui.CalcTextSize(tog.jobName(j)).x
            tot = tot + nat[i]
        end
        local gaps = gapC * (n - 1)
        local k = (tot + gaps > availW) and math.max(0.3, (availW - gaps) / tot) or 1
        local cy = wp.y + hy
        local cxs, cws, cxx = {}, {}, chipsX
        for i = 1, n do
            cws[i] = math.floor(math.max(60 * scale, nat[i] * k))
            cxs[i] = math.floor(cxx)
            cxx = cxx + cws[i] + gapC
        end
        -- скользящая подсветка: плавно переезжает к выбранной работе и перекрашивается
        local si = math.max(1, math.min(n, selected))
        local scol = JOB_COLORS[JOBS[si].id] or ACCENT
        local hl = tog.auHL
        if not hl then
            hl = { x = cxs[si], w = cws[si], c = { scol[1], scol[2], scol[3] } }
            tog.auHL = hl
        end
        local ka = 1 - math.exp(-hvDt * 13)
        hl.x = hl.x + (cxs[si] - hl.x) * ka
        hl.w = hl.w + (cws[si] - hl.w) * ka
        for q = 1, 3 do hl.c[q] = hl.c[q] + (scol[q] - hl.c[q]) * ka end
        local hp0, hp1 = V2(hl.x, cy), V2(hl.x + hl.w, cy + cb)
        tog.aF(dl, hp0, hp1, tog.aU(hl.c[1], hl.c[2], hl.c[3], 0.20), cb / 2)
        tog.aR(dl, hp0, hp1, tog.aU(hl.c[1], hl.c[2], hl.c[3], 0.60), cb / 2)

        local pend
        for i, j in ipairs(JOBS) do
            local x, w = cxs[i], cws[i]
            local p0, p1 = V2(x, cy), V2(x + w, cy + cb)
            local col = JOB_COLORS[j.id] or ACCENT
            local sel = (selected == i)
            local xs = math.floor(22 * scale)
            local xp = V2(p1.x - xs - 6 * scale, cy + (cb - xs) / 2)
            local xc, xh, armed = false, false, false
            if not j.builtin then -- крестик создаём первым: он перехватывает клик
                imgui.SetCursorScreenPos(xp)
                xc = imgui.InvisibleButton('##audel' .. i, V2(xs, xs))
                xh = imgui.IsItemHovered()
                armed = (confirmDel == j.id) and (os.clock() - confirmDelT < 3)
            end
            imgui.SetCursorScreenPos(p0)
            if imgui.InvisibleButton('##aujob' .. i, V2(w, cb)) then selected = i end
            local hov = imgui.IsItemHovered()
            local hA = animTo('auJh' .. j.id, (hov or xh) and 1 or 0, 14)
            local sA = animTo('auJs' .. j.id, sel and 1 or 0, 12)
            if hA * (1 - sA) > 0.01 then tog.aF(dl, p0, p1, tog.aU(1, 1, 1, 0.06 * hA * (1 - sA)), cb / 2) end
            local br = 11 * scale
            local bc = V2(p0.x + 10 * scale + br, p0.y + cb / 2)
            dl:AddCircleFilled(bc, br * (1 + 0.07 * hA), tog.aU(col[1], col[2], col[3], lerp(0.25, 0.95, sA)), 24)
            drawBadgeGlyph(dl, bc.x, bc.y, tog.aU(lerp(col[1], 0.07, sA), lerp(col[2], 0.08, sA), lerp(col[3], 0.10, sA), 1), jobGlyph(j))
            local ix, iy = bc.x + br * 0.75, bc.y - br * 0.75
            if running == j.id then
                local pulse = 0.5 + 0.5 * math.sin(os.clock() * 4)
                dl:AddCircleFilled(V2(ix, iy), (4 + 2.5 * pulse) * scale, tog.aU(GREEN[1], GREEN[2], GREEN[3], 0.25), 14)
                dl:AddCircleFilled(V2(ix, iy), 3.5 * scale, tog.aU(GREEN[1], GREEN[2], GREEN[3], 1), 12)
            elseif tog.pendingRecover[j.id] then
                dl:AddCircle(V2(ix, iy), 4 * scale, tog.aU(col[1], col[2], col[3], 1), 14, 1.6)
            end
            local reserve = (j.builtin and 14 or 34) * scale
            local nameX = bc.x + br + 8 * scale
            local nr, ng, nb = lerp(0.62, 0.95, sA), lerp(0.64, 0.96, sA), lerp(0.70, 0.99, sA)
            dl:AddText(V2(nameX, cy + (cb - imgui.GetTextLineHeight()) / 2), tog.aU(nr, ng, nb, 1),
                fitText(tog.jobName(j), p1.x - reserve - nameX))
            if not j.builtin then
                local dv = animTo('auJd' .. j.id, (hov or xh or armed) and 1 or 0, 16)
                if dv > 0.01 then
                    local rc = armed and RED or { 1, 1, 1 }
                    tog.aF(dl, xp, V2(xp.x + xs, xp.y + xs), tog.aU(rc[1], rc[2], rc[3], (armed and 0.22 or 0.08) * dv), 7 * scale)
                    local xg = ic('trash')
                    local ir = armed and RED or { 0.80, 0.82, 0.88 }
                    drawText(dl, V2(xp.x + (xs - textWidth(xg)) / 2, xp.y + (xs - imgui.GetTextLineHeight()) / 2),
                        tog.aU(ir[1], ir[2], ir[3], dv), xg)
                end
                if xh then imgui.SetTooltip(armed and L('del_tip2') or L('del_tip')) end
                if xc then
                    if armed then pend = i; confirmDel = nil else confirmDel, confirmDelT = j.id, os.clock() end
                end
            end
        end
        if pend then removeJob(pend) end
    end
    local dyl = math.floor(wp.y + hy + cb + 14 * scale) + 0.5
    dl:AddLine(V2(math.floor(wp.x + PAD), dyl), V2(math.floor(wp.x + W - PAD), dyl), tog.aU(1, 1, 1, 0.07), 1)
end

------------------------------------------------------------------
-- Вкладка «Сеанс»: герой-карта с линией пульса + 4 плитки метрик + баннер незавершённого сеанса
------------------------------------------------------------------
function tog.auSession(c, rec, bannerH)
    local V2 = imgui.ImVec2
    local L, wp, dl, PAD, W, lh, gap = tog.L, c.wp, c.dl, c.PAD, c.W, c.lh, c.gap
    local job, s = c.job, c.s
    local isRun = (running == job.id)
    local jc = JOB_COLORS[job.id] or ACCENT
    local GRAY = tog.aU(0.55, 0.57, 0.63, 1)
    local MW = W - PAD * 2
    local bodyH = c.bodyB - c.top
    local lw = math.floor(MW * 0.58)
    local x0, y0 = wp.x + PAD, wp.y + c.top
    local rr = 18 * scale

    tog.auSt(0)
    -- герой-карта
    local p0, p1 = V2(x0, y0), V2(x0 + lw, y0 + bodyH)
    tog.aF(dl, p0, p1, tog.aU(1, 1, 1, 0.04), rr)
    dl:PushClipRect(V2(x0 + 6 * scale, y0 + 6 * scale), V2(x0 + lw - 6 * scale, y0 + bodyH - 6 * scale), true)
    for i = 1, 28 do
        dl:AddCircleFilled(V2(x0 + lw * 0.88, y0 + bodyH * 0.08), 230 * scale * i / 28, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.0036), 64)
    end
    dl:PopClipRect()
    tog.aR(dl, p0, p1, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.26), rr)

    local ix = x0 + 22 * scale
    drawText(dl, V2(ix, y0 + 18 * scale), GRAY, icl('coins', L('earned_session')))

    -- статус справа сверху
    local chipTxt = isRun and L('chip_run') or L('chip_pause')
    local cc = isRun and GREEN or { 0.60, 0.62, 0.68 }
    local chW, chH = imgui.CalcTextSize(chipTxt).x + 30 * scale, lh + 8 * scale
    local chX, chY = x0 + lw - 18 * scale - chW, y0 + 14 * scale
    tog.aF(dl, V2(chX, chY), V2(chX + chW, chY + chH), tog.aU(cc[1], cc[2], cc[3], 0.15), chH / 2)
    local pulse = isRun and (0.5 + 0.5 * math.sin(os.clock() * 4)) or 0
    dl:AddCircleFilled(V2(chX + 13 * scale, chY + chH / 2), (3 + 2 * pulse) * scale, tog.aU(cc[1], cc[2], cc[3], 0.30 + 0.70 * (1 - pulse * 0.4)), 10)
    dl:AddText(V2(chX + 22 * scale, chY + (chH - lh) / 2), tog.aU(cc[1], cc[2], cc[3], 1), chipTxt)

    -- крупная сумма
    local bigY = y0 + 18 * scale + lh + 8 * scale
    if fontBig then imgui.PushFont(fontBig) end
    local blh = imgui.GetTextLineHeight()
    dl:AddText(V2(ix, bigY), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 1), fmtMoney(math.floor(tog.auN('e' .. job.id, s.sEarned) + 0.5)))
    if fontBig then imgui.PopFont() end

    -- чистая прибыль
    local profit = math.floor(tog.auN('p' .. job.id, s.sEarned - s.sSpent) + 0.5)
    local pStr = ((profit >= 0) and '+' or '-') .. fmtMoney(math.abs(profit))
    local pc = (profit >= 0) and GREEN or RED
    local py = bigY + blh + 6 * scale
    if fontTitle then imgui.PushFont(fontTitle) end
    local tlh = imgui.GetTextLineHeight()
    local pw = imgui.CalcTextSize(pStr).x
    dl:AddText(V2(ix, py), tog.aU(pc[1], pc[2], pc[3], 1), pStr)
    if fontTitle then imgui.PopFont() end
    drawText(dl, V2(ix + pw + 12 * scale, py + tlh - lh - 2 * scale), GRAY, icl('chart', L('net_profit')))

    -- линия пульса: бежит при идущем сеансе, почти ровная на паузе
    local wTop, wBot = py + tlh + 14 * scale, y0 + bodyH - 18 * scale
    if wBot - wTop > 26 * scale then
        local wx0, wx1 = x0 + 22 * scale, x0 + lw - 22 * scale
        local mid, half = (wTop + wBot) / 2, (wBot - wTop) / 2
        local amp = animTo('auAmp', isRun and 1 or 0.07, 5)
        local t = os.clock() * (isRun and 0.5 or 0.12)
        dl:AddLine(V2(wx0, mid), V2(wx1, mid), tog.aU(1, 1, 1, 0.06), 1)
        local N, prev = 180, nil
        for k = 0, N do
            local u = k / N
            local pt = V2(wx0 + u * (wx1 - wx0), mid - tog.auBeat(u * 2.4 + t) * amp * half * 0.92)
            if prev then
                local al = math.sin(math.pi * u)
                dl:AddLine(prev, pt, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.10 * al), 6 * scale)
                dl:AddLine(prev, pt, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], al), 2.2 * scale)
            end
            prev = pt
        end
    end

    -- плитки метрик 2x2
    local gx = x0 + lw + gap
    local gw = MW - lw - gap
    local tw2 = math.floor((gw - gap) / 2)
    local th2 = math.floor((bodyH - gap) / 2)
    local e1 = tog.auSt(1)
    tog.auStat(dl, gx, y0 + (1 - e1) * 12 * scale, tw2, th2, 'clock', L('time'), fmtTime(s.sSecs), { 0.92, 0.93, 0.96 })
    local e2 = tog.auSt(2)
    tog.auStat(dl, gx + tw2 + gap, y0 + (1 - e2) * 12 * scale, tw2, th2, 'check', L('orders'),
        tostring(math.floor(tog.auN('c' .. job.id, s.sCount) + 0.5)), GREEN)
    local e3 = tog.auSt(3)
    tog.auStat(dl, gx, y0 + th2 + gap + (1 - e3) * 12 * scale, tw2, th2, 'wallet', L('spent'),
        fmtMoney(math.floor(tog.auN('s' .. job.id, s.sSpent) + 0.5)), RED)
    local e4 = tog.auSt(4)
    tog.auStat(dl, gx + tw2 + gap, y0 + th2 + gap + (1 - e4) * 12 * scale, tw2, th2, 'chart', L('per_hour'),
        fmtMoney(math.floor(tog.auN('h' .. job.id, perHour(s.sEarned, s.sSecs)) + 0.5)), ACCENT)
    tog.auC = 1

    -- баннер незавершённого сеанса
    if rec then
        local by0 = wp.y + c.bodyB + gap
        tog.auC = c.aB or 1
        imgui.PushClipRect(V2(x0 - 2 * scale, by0), V2(x0 + MW + 2 * scale, by0 + bannerH), true)
        tog.aF(dl, V2(x0, by0), V2(x0 + MW, by0 + bannerH), tog.aU(jc[1], jc[2], jc[3], 0.12), 16 * scale)
        tog.aR(dl, V2(x0, by0), V2(x0 + MW, by0 + bannerH), tog.aU(jc[1], jc[2], jc[3], 0.38), 16 * scale)
        local bpad, bwid, bth = 16 * scale, math.floor(150 * scale), math.floor(34 * scale)
        local textW = MW - bpad * 2 - bwid * 2 - gap * 2
        local l1 = icl('hourglass', L('rec_title', (rec.ts:gsub('_', ' '))))
        local l2 = L('rec_line', fmtMoney(rec.earned), fmtTime(rec.secs), rec.count)
        local ty = by0 + (bannerH - lh * 2 - 4 * scale) / 2
        drawText(dl, V2(x0 + bpad, ty), tog.aU(0.92, 0.93, 0.96, 1), fitText(l1, textW))
        dl:AddText(V2(x0 + bpad, ty + lh + 4 * scale), GRAY, fitText(l2, textW))
        local relY = c.bodyB + gap + (bannerH - bth) / 2
        imgui.SetCursorPos(V2(PAD + MW - bpad - bwid * 2 - gap, relY))
        if styledButton('##aurecCont', icl('play', L('btn_continue')), bwid, bth, true) then tog.resolveRecover(job.id, true) end
        imgui.SetCursorPos(V2(PAD + MW - bpad - bwid, relY))
        if styledButton('##aurecDrop', icl('history', L('btn_to_history')), bwid, bth, false) then tog.resolveRecover(job.id, false) end
        imgui.PopClipRect()
        tog.auC = 1
    end
end

------------------------------------------------------------------
-- Вкладка «История»: итоги-пилюля сверху и список сеансов карточками
------------------------------------------------------------------
function tog.auHistory(c)
    local V2 = imgui.ImVec2
    local L, wp, dl, PAD, W, lh, gap = tog.L, c.wp, c.dl, c.PAD, c.W, c.lh, c.gap
    local job, s = c.job, c.s
    local jc = JOB_COLORS[job.id] or ACCENT
    local GRAY = tog.aU(0.55, 0.57, 0.63, 1)
    local MW = W - PAD * 2
    local x0, y0 = wp.x + PAD, wp.y + c.top

    tog.auSt(0)
    -- итоги за всё время
    local allNet = s.total - s.spent
    local sumStr = L('alltime'):format(fmtMoney(s.total), fmtMoney(s.spent), (allNet >= 0) and '+' or '-',
        fmtMoney(math.abs(allNet)), fmtTime(s.secs), s.count)
    sumStr = fitText(sumStr, MW - 36 * scale)
    local sh = math.floor(lh + 18 * scale)
    tog.aF(dl, V2(x0, y0), V2(x0 + MW, y0 + sh), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.10), sh / 2)
    tog.aR(dl, V2(x0, y0), V2(x0 + MW, y0 + sh), tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.26), sh / 2)
    dl:AddText(V2(x0 + (MW - imgui.CalcTextSize(sumStr).x) / 2, y0 + (sh - lh) / 2), tog.aU(0.84, 0.86, 0.90, 1), sumStr)

    -- столбцы
    local weights = { 1.85, 1.0, 1.0, 1.4, 1.4, 1.4 }
    local alignR = { false, false, true, true, true, true }
    local wsum = 0
    for _, w in ipairs(weights) do wsum = wsum + w end
    local colPad = 18 * scale
    local colL, colW, cx = {}, {}, colPad
    for i = 1, 6 do
        colW[i] = (MW - colPad * 2) * weights[i] / wsum
        colL[i] = cx
        cx = cx + colW[i]
    end
    local function colX(i, str)
        if alignR[i] then return colL[i] + colW[i] - imgui.CalcTextSize(str).x end
        return colL[i]
    end
    local heads = { L('h_date'), L('h_time'), L('h_orders'), L('h_income'), L('h_expense'), L('h_total') }
    local hy = y0 + sh + gap
    for i = 1, 6 do dl:AddText(V2(x0 + colX(i, heads[i]), hy), GRAY, heads[i]) end

    local items = {}
    for i = #log, 1, -1 do
        if log[i].job == job.id then items[#items + 1] = log[i] end
    end

    local listTop = c.top + sh + gap + lh + 8 * scale
    local listH = c.bodyB - listTop
    local rowH = math.floor(lh + 20 * scale)
    local rg = 6 * scale

    imgui.SetCursorPos(V2(PAD, listTop))
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(0, 0, 0, 0))
    imgui.BeginChild('##auhist', V2(MW, listH), false, imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoScrollbar)
    local cdl = imgui.GetWindowDrawList()
    local cwp = imgui.GetWindowPos()

    -- плавная прокрутка колесом
    do
        local now = os.clock()
        local dt = math.min(0.05, now - hs.last)
        hs.last = now
        if hs.job ~= job.id then
            hs.job, hs.target, hs.cur, hs.set = job.id, 0, 0, 0
            imgui.SetScrollY(0)
        else
            local maxY = imgui.GetScrollMaxY()
            if imgui.IsWindowHovered() then
                local wheel = imgui.GetIO().MouseWheel
                if wheel ~= 0 then hs.target = hs.target - wheel * (rowH + rg) * 2 end
            end
            hs.target = math.max(0, math.min(maxY, hs.target))
            hs.cur = hs.cur + (hs.target - hs.cur) * (1 - math.exp(-dt * 14))
            if math.abs(hs.target - hs.cur) < 0.5 then hs.cur = hs.target end
            imgui.SetScrollY(hs.cur)
            hs.set = hs.cur
        end
    end

    if #items == 0 then
        cdl:AddText(V2(cwp.x + 6 * scale, cwp.y + 10 * scale), tog.aU(0.50, 0.52, 0.58, 1), fitText(L('hist_empty'), MW - 12 * scale))
    else
        local sy = imgui.GetScrollY()
        local hovW = imgui.IsWindowHovered()
        for i, e in ipairs(items) do
            local ry0 = cwp.y + (i - 1) * (rowH + rg) - sy
            if ry0 + rowH > cwp.y and ry0 < cwp.y + listH then
                local ee = tog.auSt(math.min(i, 9) + 1)
                local rx0 = cwp.x + (1 - ee) * 16 * scale
                local a, b = V2(rx0, ry0), V2(rx0 + MW, ry0 + rowH)
                local hov = hovW and imgui.IsMouseHoveringRect(a, b)
                local hA = animTo('auHr' .. i, hov and 1 or 0, 14)
                tog.aF(cdl, a, b, tog.aU(1, 1, 1, 0.035 + 0.045 * hA), 12 * scale)
                tog.aF(cdl, V2(rx0, ry0 + 10 * scale), V2(rx0 + 3 * scale, ry0 + rowH - 10 * scale),
                    tog.aU(jc[1], jc[2], jc[3], 1), 2)
                local net = e.earned - e.spent
                local vals = { (e.ts:gsub('_', ' ')), fmtTime(e.secs), tostring(e.count), '+' .. fmtMoney(e.earned),
                    '-' .. fmtMoney(e.spent), ((net >= 0) and '+' or '-') .. fmtMoney(math.abs(net)) }
                local gC, rC, wC = { GREEN[1], GREEN[2], GREEN[3] }, { RED[1], RED[2], RED[3] }, { 0.80, 0.82, 0.88 }
                local cols = { wC, wC, wC, gC, rC, (net >= 0) and gC or rC }
                for k = 1, 6 do
                    local cl = cols[k]
                    cdl:AddText(V2(rx0 + colX(k, vals[k]), ry0 + (rowH - lh) / 2), tog.aU(cl[1], cl[2], cl[3], 1), vals[k])
                end
            end
        end
        imgui.SetCursorPos(V2(0, #items * (rowH + rg)))
        imgui.Dummy(V2(0, 0))
    end
    imgui.EndChild()
    imgui.PopStyleColor()
end

------------------------------------------------------------------
-- Вкладка «Настройки»: сетка плиток 2 колонки
------------------------------------------------------------------
function tog.auSettings(c)
    local V2 = imgui.ImVec2
    local L, wp, dl, PAD, W, lh = tog.L, c.wp, c.dl, c.PAD, c.W, c.lh
    local GRAY = tog.aU(0.55, 0.57, 0.63, 1)
    local MW = W - PAD * 2
    local gap = 10 * scale
    local tw = math.floor((MW - gap) / 2)
    local th = math.floor(60 * scale)
    local x0 = wp.x + PAD
    local y = wp.y + c.top
    local m, a = tog.map, tog.af

    drawText(dl, V2(x0, y), GRAY, icl('gear', L('set_general')))
    local gy = y + lh + 8 * scale
    local function pos(i, baseY, off)
        tog.auSt(i + (off or 0))
        return x0 + ((i - 1) % 2) * (tw + gap), baseY + math.floor((i - 1) / 2) * (th + gap)
    end

    local tx, ty = pos(1, gy)
    if tog.auTile(dl, 'dist', tx, ty, tw, th, 'target', L('set_dist'), L('set_dist_sub'), showDist) then
        showDist = not showDist
        saveTheme()
    end
    tx, ty = pos(2, gy)
    if tog.auTile(dl, 'pause', tx, ty, tw, th, 'hourglass', L('set_pause'), L('set_pause_sub'), tog.pause) then
        tog.pause = not tog.pause
        tog.act = os.clock()
        saveTheme()
    end
    tx, ty = pos(3, gy)
    if tog.auTile(dl, 'mini', tx, ty, tw, th, 'chart', L('set_mini'), L('set_mini_sub'), tog.miShow) then
        tog.miShow = not tog.miShow
        tog.saveMini()
    end

    -- быстрая карта: плитка + кнопка выбора клавиши
    tx, ty = pos(4, gy)
    do
        local chipW, chipH = math.floor(100 * scale), math.floor(30 * scale)
        local swXr = tx + tw - 14 * scale - 40 * scale
        local chipX, chipY = swXr - 14 * scale - chipW, ty + (th - chipH) / 2
        imgui.SetCursorScreenPos(V2(chipX, chipY))
        local keyClick = imgui.InvisibleButton('##aumapkey', V2(chipW, chipH))
        local hovK = imgui.IsItemHovered()
        if keyClick then m.binding = not m.binding end
        local subTxt = (m.key == 0) and L('map_sub_none') or L('map_sub')
        if tog.auTile(dl, 'map', tx, ty, tw, th, 'map', L('set_map'), subTxt, m.on, chipW + 18 * scale) then
            m.on = not m.on
            m.binding = false
            tog.saveMap()
        end
        local chA = animTo('auMapK', hovK and 1 or 0, 14)
        local bA = animTo('auMapB', m.binding and 1 or 0, 14)
        local c0, c1 = V2(chipX, chipY), V2(chipX + chipW, chipY + chipH)
        tog.aF(dl, c0, c1, tog.aU(1, 1, 1, 0.05 + 0.04 * chA), 8 * scale)
        if bA > 0.01 then tog.aF(dl, c0, c1, tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.22 * bA), 8 * scale) end
        tog.aR(dl, c0, c1, tog.aU(lerp(1, ACCENT[1], bA), lerp(1, ACCENT[2], bA), lerp(1, ACCENT[3], bA), lerp(0.12 + 0.10 * chA, 0.9, bA)), 8 * scale, 15, 1)
        local kLabel, kc
        if m.binding then kLabel, kc = L('key_press'), ACCENT
        elseif m.key == 0 then kLabel, kc = L('key_none'), { 0.55, 0.57, 0.63 }
        else kLabel, kc = tog.keyName(m.key) or '?', { 0.92, 0.93, 0.96 } end
        kLabel = fitText(kLabel, chipW - 12 * scale)
        dl:AddText(V2(chipX + (chipW - imgui.CalcTextSize(kLabel).x) / 2, chipY + (chipH - lh) / 2), tog.aU(kc[1], kc[2], kc[3], 1), kLabel)
        if hovK then imgui.SetTooltip(L('key_tip')) end
    end

    tx, ty = pos(5, gy)
    if tog.auTile(dl, 'af', tx, ty, tw, th, 'sync', L('set_af'), a.id and L('set_af_sub', a.id) or L('set_af_noid'), a.on) then
        a.on = not a.on
        a.last = 0
        tog.saveAf()
    end

    -- язык
    tx, ty = pos(6, gy)
    local litems = {}
    for _, code in ipairs(tog.LANGS) do
        litems[#litems + 1] = { name = tog.LANG_NAME[code], sel = (tog.lang == code), accent = ACCENT }
    end
    tog.auField(dl, c, 'lang', 'langOpen', tx, ty, tw, th, math.floor(140 * scale), 'globe', L('set_lang'), L('set_lang_sub'),
        tog.LANG_NAME[tog.lang] or '?', nil, litems, function(i) tog.setLang(tog.LANGS[i]) end)

    -- оформление
    local cy = gy + 3 * (th + gap) + 6 * scale
    drawText(dl, V2(x0, cy), GRAY, icl('palette', L('set_custom')))
    local gy2 = cy + lh + 8 * scale

    tx, ty = pos(1, gy2, 6)
    local titems = {}
    for i, t in ipairs(THEMES) do
        titems[#titems + 1] = { name = L('theme' .. i), sel = (themeIdx == i), accent = t.accent, dots = { t.accent, t.green, t.red } }
    end
    local cur = THEMES[themeIdx]
    tog.auField(dl, c, 'theme', 'themeOpen', tx, ty, tw, th, math.floor(180 * scale), 'palette', L('set_theme'), L('set_theme_sub'),
        L('theme' .. themeIdx), { cur.accent, cur.green, cur.red }, titems, function(i) setTheme(i) end)

    tx, ty = pos(2, gy2, 6)
    local sitems = {
        { name = L('style_classic'), sel = (tog.style == 'classic'), accent = ACCENT },
        { name = L('style_aurora'), sel = (tog.style == 'aurora'), accent = ACCENT },
    }
    tog.auField(dl, c, 'style', 'styleOpen', tx, ty, tw, th, math.floor(150 * scale), 'gear', L('set_style'), L('set_style_sub'),
        L('style_' .. (tog.style == 'aurora' and 'aurora' or 'classic')), nil, sitems,
        function(i) tog.style = (i == 2) and 'aurora' or 'classic'; tog.saveStyle() end)
end

------------------------------------------------------------------
-- Нижняя панель: сегмент «Сеанс / История» слева, кнопки действий справа
------------------------------------------------------------------
function tog.auActions(c)
    local V2 = imgui.ImVec2
    local L, wp, dl, PAD, W, lh = tog.L, c.wp, c.dl, c.PAD, c.W, c.lh
    local y, h = c.ay, c.bh
    local names = { icl('session', L('tab_session')), icl('history', L('tab_history')) }
    local segW = math.floor(math.max(textWidth(names[1]), textWidth(names[2])) + 44 * scale)
    local x0 = wp.x + PAD
    tog.aF(dl, V2(x0, wp.y + y), V2(x0 + segW * 2, wp.y + y + h), tog.aU(1, 1, 1, 0.05), h / 2)
    tog.aR(dl, V2(x0, wp.y + y), V2(x0 + segW * 2, wp.y + y + h), tog.aU(1, 1, 1, 0.08), h / 2)
    local sA = animTo('auseg', (tab == 2) and 1 or 0, nil, 0.22)
    local hx = x0 + segW * sA
    tog.aF(dl, V2(hx + 3 * scale, wp.y + y + 3 * scale), V2(hx + segW - 3 * scale, wp.y + y + h - 3 * scale),
        tog.aU(ACCENT[1], ACCENT[2], ACCENT[3], 0.95), (h - 6 * scale) / 2)
    for i = 1, 2 do
        imgui.SetCursorScreenPos(V2(x0 + (i - 1) * segW, wp.y + y))
        if imgui.InvisibleButton('##auseg' .. i, V2(segW, h)) then tab = i end
        local act = animTo('auSegT' .. i, (tab == i) and 1 or 0, 14)
        local tw = textWidth(names[i])
        drawText(dl, V2(x0 + (i - 1) * segW + (segW - tw) / 2, wp.y + y + (h - lh) / 2),
            tog.aU(lerp(0.62, 0.07, act), lerp(0.64, 0.08, act), lerp(0.70, 0.10, act), 1), names[i])
    end

    local gap = c.gap
    if tab == 1 then
        local job = c.job
        local isRun = (running == job.id)
        local bw = math.floor(176 * scale)
        if isRun then -- дышащее зелёное кольцо вокруг «Остановить», пока идёт сеанс
            local pl = 0.5 + 0.5 * math.sin(os.clock() * 3)
            local ex = (2 + 3 * pl) * scale
            local bx0 = wp.x + W - PAD - bw * 2 - gap
            tog.aR(dl, V2(bx0 - ex, wp.y + y - ex), V2(bx0 + bw + ex, wp.y + y + h + ex),
                tog.aU(GREEN[1], GREEN[2], GREEN[3], 0.12 + 0.30 * (1 - pl)), 9 * scale + ex, 15, 2)
        end
        imgui.SetCursorPos(V2(W - PAD - bw * 2 - gap, y))
        if styledButton('##austart', isRun and icl('stop', L('btn_stop')) or icl('play', L('btn_start')), bw, h, true) then
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
        imgui.SetCursorPos(V2(W - PAD - bw, y))
        if styledButton('##aufinish', icl('report', L('btn_finish')), bw, h, false) then finishSession(job.id) end
    else
        local armed = (os.clock() - confirmClear) < 3
        local lbl = icl('trash', armed and L('clear_confirm') or L('clear_btn'))
        local bw = math.floor(textWidth(lbl) + 48 * scale)
        imgui.SetCursorPos(V2(W - PAD - bw, y))
        if styledButton('##auclear', lbl, bw, h, armed) then
            if armed then
                clearHistory(c.job.id)
                confirmClear = 0
            else
                confirmClear = os.clock()
            end
        end
    end
end

------------------------------------------------------------------
-- Главная функция нового макета (вызывается из draw() при tog.style == 'aurora')
------------------------------------------------------------------
function tog.drawAurora()
    local V2 = imgui.ImVec2
    local L = tog.L
    if tab ~= 1 and tab ~= 2 and tab ~= 4 then tab = 1 end
    local sx, sy = getScreenResolution()
    local W, H = math.floor(480 * scale) * 2, math.floor(280 * scale) * 2
    local PAD = math.floor(22 * scale)

    -- анимация появления: плавный fade + всплытие снизу
    local now = os.clock()
    if now - tog.auLast > 0.25 then tog.auT0, tog.auKT = now, now + 0.12 end
    tog.auLast = now
    local oa = math.max(0, math.min(1, (now - tog.auT0) / 0.32))
    local eo = 1 - (1 - oa) ^ 3
    tog.auA, tog.auC = eo, 1

    imgui.GetBackgroundDrawList():AddRectFilled(V2(0, 0), V2(sx, sy), tog.aU(0.02, 0.02, 0.04, 0.30))

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 22 * scale)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, V4(0.050, 0.054, 0.078, 0.985 * tog.auA))
    imgui.PushStyleColor(imgui.Col.Border, V4(ACCENT[1], ACCENT[2], ACCENT[3], 0.30 * tog.auA))
    imgui.SetNextWindowPos(V2(math.floor((sx - W) / 2), math.floor((sy - H) / 2 + (1 - eo) * 22 * scale)), imgui.Cond.Always, V2(0, 0))
    imgui.SetNextWindowSize(V2(W, H), imgui.Cond.Always)
    imgui.Begin('###WorkStats', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoScrollbar)

    local wp = imgui.GetWindowPos()
    local dl = imgui.GetWindowDrawList()
    local lh = imgui.GetTextLineHeight()

    -- мягкое свечение фона: круги целиком внутри окна, без обрезки, поэтому нет жёстких краёв
    do
        local gl = {
            { wp.x + W - 170 * scale, wp.y + 150 * scale, 150 * scale, ACCENT },
            { wp.x + 150 * scale, wp.y + H - 130 * scale, 130 * scale, { 0.62, 0.46, 0.95 } },
        }
        for _, g in ipairs(gl) do
            for i = 1, 30 do
                dl:AddCircleFilled(V2(g[1], g[2]), g[3] * i / 30, tog.aU(g[4][1], g[4][2], g[4][3], 0.0042), 64)
            end
        end
    end

    local c = { wp = wp, dl = dl, W = W, H = H, PAD = PAD, lh = lh }
    tog.auHeader(c)

    local job = JOBS[selected] or JOBS[1]
    c.job, c.s = job, stats[job.id]
    local key = tab .. '|' .. selected
    if key ~= tog.auKey then tog.auKey, tog.auKT = key, now end
    tog.auCT = now - tog.auKT
    c.gap = math.floor(10 * scale)
    c.bh = math.floor(44 * scale)
    c.top = math.floor(86 * scale)
    c.ay = H - math.floor(14 * scale) - lh - math.floor(12 * scale) - c.bh
    local recNow = (tab == 1) and tog.pendingRecover[job.id] or nil
    if recNow then tog.auRec = recNow end
    local aB = animTo('auBan', recNow and 1 or 0, nil, 0.3) -- баннер плавно выезжает и убирается
    local bannerH = math.floor(64 * scale * aB)
    local rec = (aB > 0.02) and tog.auRec or nil
    c.aB = aB
    c.bodyB = c.ay - c.gap - (rec and (bannerH + c.gap) or 0)

    if tab == 1 then tog.auSession(c, rec, bannerH)
    elseif tab == 2 then tog.auHistory(c)
    else tog.auSettings(c) end
    tog.auC = 1
    if tab ~= 4 then tog.auActions(c) end

    dl:AddText(V2(wp.x + PAD, wp.y + H - 14 * scale - lh), tog.aU(0.45, 0.47, 0.54, 1),
        balance and L('footer_bal', fmtMoney(balance)) or L('footer_nobal'))

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
    tog.ddRender()
end


local function draw()
    if not iconChecked then checkIcons() end
    local L = tog.L
    local nowH = os.clock()
    hvDt, hvLast = math.min(0.05, nowH - hvLast), nowH
    if tog.style == 'aurora' then return tog.drawAurora() end
    tog.auA, tog.auC = 1, 1
    local sx, sy = getScreenResolution()
    local aur = (tog.style == 'aurora')
    -- в настройках окно плавно становится выше (есть место для строки «Стиль меню»)
    local W, H = math.floor(780 * scale), math.floor((620 + 60 * animTo('seth', (tab == 4) and 1 or 0, nil, 0.26)) * scale)
    local SB = math.floor(210 * scale)
    local PAD = math.floor(20 * scale)

    local bgdl = imgui.GetBackgroundDrawList()
    bgdl:AddRectFilled(imgui.ImVec2(0, 0), imgui.ImVec2(sx, sy), U32(0.02, 0.02, 0.04, 0.30))

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, (aur and 20 or 14) * scale)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, aur and V4(0.050, 0.054, 0.078, 0.985) or V4(BG[1], BG[2], BG[3], 0.97))
    imgui.PushStyleColor(imgui.Col.Border, aur and V4(ACCENT[1], ACCENT[2], ACCENT[3], 0.30) or V4(1, 1, 1, 0.07))

    imgui.SetNextWindowPos(imgui.ImVec2(sx / 2, sy / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
    imgui.Begin('###WorkStats', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoScrollbar)

    local wp = imgui.GetWindowPos()
    local dl = imgui.GetWindowDrawList()

    -- WorkHelper: мягкое свечение фона (слоями кругов, обрезано чуть внутри скруглённых углов)
    if aur then
        local ins = 8 * scale
        dl:PushClipRect(imgui.ImVec2(wp.x + ins, wp.y + ins), imgui.ImVec2(wp.x + W - ins, wp.y + H - ins), true)
        local gl = {
            { wp.x + W * 0.82, wp.y + H * 0.04, 300 * scale, ACCENT },
            { wp.x + W * 0.95, wp.y + H * 0.98, 260 * scale, { 0.62, 0.46, 0.95 } },
        }
        for _, g in ipairs(gl) do
            for i = 1, 10 do
                dl:AddCircleFilled(imgui.ImVec2(g[1], g[2]), g[3] * i / 10, U32(g[4][1], g[4][2], g[4][3], 0.011), 56)
            end
        end
        dl:PopClipRect()
    end

    ----------------------------------------------------------------
    -- Сайдбар
    ----------------------------------------------------------------
    local sbA = animTo('sbhide', (tab == 4) and 1 or 0, nil, 0.26) -- 0 = сайдбар виден, 1 = скрыт
    if sbA < 0.995 then
        local wps = imgui.ImVec2(wp.x - SB * sbA, wp.y) -- сайдбар уезжает влево
        dl:AddRectFilled(wps, imgui.ImVec2(wps.x + SB, wps.y + H), U32(PANEL[1], PANEL[2], PANEL[3], aur and 0.60 or 1), (aur and 20 or 14) * scale, 5)
        dl:AddLine(imgui.ImVec2(wps.x + SB, wps.y + 14 * scale), imgui.ImVec2(wps.x + SB, wps.y + H - 14 * scale), U32(1, 1, 1, 0.07), 1)

        -- логотип и название
        local lg = math.floor(36 * scale)
        local l0 = imgui.ImVec2(wps.x + PAD, wps.y + PAD)
        if aur then
            -- WorkHelper: градиентный значок с линией пульса
            for gi = 1, 5 do
                dl:AddRectFilled(imgui.ImVec2(l0.x - gi * 1.5 * scale, l0.y - gi * 1.5 * scale),
                    imgui.ImVec2(l0.x + lg + gi * 1.5 * scale, l0.y + lg + gi * 1.5 * scale),
                    U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.035), (11 + gi * 1.5) * scale)
            end
            dl:AddRectFilled(l0, imgui.ImVec2(l0.x + lg, l0.y + lg), U32(ACCENT[1], ACCENT[2], ACCENT[3], 1), 11 * scale)
            dl:AddRectFilled(l0, imgui.ImVec2(l0.x + lg, l0.y + lg * 0.5), U32(1, 1, 1, 0.16), 11 * scale, 3)
            local pts = { { 0.12, 0.58 }, { 0.32, 0.58 }, { 0.43, 0.26 }, { 0.56, 0.82 }, { 0.67, 0.44 }, { 0.75, 0.58 }, { 0.88, 0.58 } }
            for k = 1, #pts - 1 do
                dl:AddLine(imgui.ImVec2(l0.x + lg * pts[k][1], l0.y + lg * pts[k][2]),
                    imgui.ImVec2(l0.x + lg * pts[k + 1][1], l0.y + lg * pts[k + 1][2]), U32(0.06, 0.07, 0.10, 1), 2.4 * scale)
            end
            dl:AddCircleFilled(imgui.ImVec2(l0.x + lg * 0.88, l0.y + lg * 0.58), 2.6 * scale, U32(1, 1, 1, 1), 12)
            if fontTitle then imgui.PushFont(fontTitle) end
            local nx0 = l0.x + lg + 12 * scale
            dl:AddText(imgui.ImVec2(nx0, l0.y - 3 * scale), U32(0.95, 0.96, 0.99, 1), 'Work')
            local wW = imgui.CalcTextSize('Work').x
            dl:AddText(imgui.ImVec2(nx0 + wW, l0.y - 3 * scale), U32(ACCENT[1], ACCENT[2], ACCENT[3], 1), 'Helper')
            if fontTitle then imgui.PopFont() end
            dl:AddText(imgui.ImVec2(nx0, l0.y + lg - imgui.GetTextLineHeight() + 2 * scale),
                U32(0.50, 0.52, 0.58, 1), L('sub_aur'))
        else
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
                U32(0.50, 0.52, 0.58, 1), L('sub_title'))
        end

        -- заголовок секции
        local secY = PAD + lg + 20 * scale
        drawText(dl, imgui.ImVec2(wps.x + PAD, wps.y + secY), U32(0.45, 0.47, 0.54, 1), icl('briefcase', L('jobs_hdr')))

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
            if imgui.InvisibleButton('##job' .. i, imgui.ImVec2(SB - 20 * scale, rowH)) then
                selected = i
            end
            local hov = imgui.IsItemHovered()

            local col = JOB_COLORS[j.id] or ACCENT
            local sel = (selected == i)
            local hA = animTo('jh' .. j.id, (hov or xh) and 1 or 0, 14)
            local sA = animTo('js' .. j.id, sel and 1 or 0, 12)
            if hA > 0.01 then
                dl:AddRectFilled(sp, p2, U32(1, 1, 1, 0.045 * hA * (1 - sA)), 9 * scale)
            end
            if sA > 0.01 then
                dl:AddRectFilled(sp, p2, U32(col[1], col[2], col[3], (aur and 0.20 or 0.13) * sA), 9 * scale)
                if aur then dl:AddRect(sp, p2, U32(col[1], col[2], col[3], 0.50 * sA), 9 * scale) end
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
                fitText(tog.jobName(j), nameMaxW))
            -- индикатор активного сеанса
            if running == j.id then
                local cx, cy = p2.x - dotOff * scale, sp.y + rowH / 2
                local pulse = 0.5 + 0.5 * math.sin(os.clock() * 4)
                dl:AddCircleFilled(imgui.ImVec2(cx, cy), (4 + 3 * pulse) * scale, U32(GREEN[1], GREEN[2], GREEN[3], 0.18), 16)
                dl:AddCircleFilled(imgui.ImVec2(cx, cy), 4 * scale, U32(GREEN[1], GREEN[2], GREEN[3], 1), 12)
            elseif tog.pendingRecover[j.id] then
                -- есть незавершённый сеанс (после выхода / кика): кольцо в цвете работы
                local cx, cy = p2.x - dotOff * scale, sp.y + rowH / 2
                local pulse = 0.5 + 0.5 * math.sin(os.clock() * 3)
                dl:AddCircle(imgui.ImVec2(cx, cy), (4.5 + 1.5 * pulse) * scale, U32(col[1], col[2], col[3], 0.9), 16, 1.5)
                dl:AddCircleFilled(imgui.ImVec2(cx, cy), 2 * scale, U32(col[1], col[2], col[3], 1), 10)
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
                if xh then imgui.SetTooltip(armed and L('del_tip2') or L('del_tip')) end
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
        dl:AddRect(pc0, pc1, aur and U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.28) or U32(1, 1, 1, 0.06), 11 * scale)
        local av = 17 * scale
        local avc = imgui.ImVec2(pc0.x + 14 * scale + av, pc0.y + pcH / 2)
        dl:AddCircleFilled(avc, av, U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.2), 24)
        dl:AddCircle(avc, av, U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.6), 24, 1)
        local nick = (me.nick ~= '') and me.nick or L('player')
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
    local tw = imgui.CalcTextSize(tog.jobName(job)).x
    if tab == 4 then
    -- шапка настроек: кнопка «назад» и заголовок
    dl:AddText(P(mx + cb + 12 * scale, y + (cb - tlh) / 2), U32(0.94, 0.95, 0.98, 1), L('settings'))
    if fontTitle then imgui.PopFont() end
    imgui.SetCursorPos(imgui.ImVec2(mx, y))
    if styledButton('##back', ic('back'), cb, cb, false) then tab = tog.prevTab or 1; tog.themeOpen = false; tog.langOpen = false; tog.styleOpen = false end
    else
    local hb = math.floor(tlh)
    local nx = mx + hb + 10 * scale
    dl:AddText(P(nx, y), U32(0.94, 0.95, 0.98, 1), tog.jobName(job))
    if fontTitle then imgui.PopFont() end
    dl:AddRectFilled(P(mx, y), P(mx + hb, y + hb), U32(jc[1], jc[2], jc[3], 0.9), 9 * scale)
    local hg = jobGlyph(job)
    local hc = P(mx + hb / 2, y + hb / 2)
    drawBadgeGlyph(dl, hc.x, hc.y, U32(0.07, 0.08, 0.10, 1), hg)
    local chipTxt = isRun and L('chip_run') or L('chip_pause')
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
        if up.st == 'checking' then lbl = L('upd_checking')
        elseif up.st == 'avail' then lbl = icl('download', L('upd_avail', tostring(up.remote)))
        elseif up.st == 'loading' or up.st == 'reload' then lbl = L('upd_loading')
        elseif up.st == 'latest' then lbl = L('upd_latest', thisScript().version)
        elseif up.st == 'err' then lbl = L('upd_err')
        else lbl = icl('sync', L('upd_check')) end
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
    local tabs = { icl('session', L('tab_session')), icl('history', L('tab_history')) }
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
        drawText(dl, P(mx + 18 * scale, top + 12 * scale), GRAY, icl('coins', L('earned_session')))
        if fontBig then imgui.PushFont(fontBig) end
        dl:AddText(P(mx + 18 * scale, top + 12 * scale + lh + 2 * scale), U32(ACCENT[1], ACCENT[2], ACCENT[3], 1), fmtMoney(s.sEarned))
        if fontBig then imgui.PopFont() end
        -- справа: чистая прибыль
        local pStr = ((profit >= 0) and '+' or '-') .. fmtMoney(math.abs(profit))
        local pLbl = icl('chart', L('net_profit'))
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
        statCard(icl('clock', L('time')), fmtTime(s.sSecs), cw, ch)
        imgui.SetCursorPos(imgui.ImVec2(mx + cw + gap, cy))
        statCard(icl('check', L('orders')), tostring(s.sCount), cw, ch)
        imgui.SetCursorPos(imgui.ImVec2(mx + (cw + gap) * 2, cy))
        statCard(icl('wallet', L('spent')), fmtMoney(s.sSpent), cw, ch)

        -- незавершённый сеанс (после выхода / вылета / кика): продолжить или сохранить в историю
        local rec = tog.pendingRecover[job.id]
        if rec then
            local bnPad = math.floor(14 * scale)
            local bnBH = math.floor(32 * scale)
            local bnY = cy + ch + gap
            local bnH = bnPad + lh + 4 * scale + lh + 10 * scale + bnBH + bnPad
            dl:AddRectFilled(P(mx, bnY), P(mx + MW, bnY + bnH), U32(jc[1], jc[2], jc[3], 0.12), 14 * scale)
            dl:AddRect(P(mx, bnY), P(mx + MW, bnY + bnH), U32(jc[1], jc[2], jc[3], 0.35), 14 * scale)
            local l1 = icl('hourglass', L('rec_title', (rec.ts:gsub('_', ' '))))
            local l2 = L('rec_line', fmtMoney(rec.earned), fmtTime(rec.secs), rec.count)
            drawText(dl, P(mx + bnPad, bnY + bnPad), U32(0.92, 0.93, 0.96, 1), fitText(l1, MW - bnPad * 2))
            dl:AddText(P(mx + bnPad, bnY + bnPad + lh + 4 * scale), GRAY, fitText(l2, MW - bnPad * 2))
            local bnBW = math.floor((MW - bnPad * 2 - gap) / 2)
            local bnBY = bnY + bnH - bnPad - bnBH
            imgui.SetCursorPos(imgui.ImVec2(mx + bnPad, bnBY))
            if styledButton('##recCont', icl('play', L('btn_continue')), bnBW, bnBH, true) then
                tog.resolveRecover(job.id, true)
            end
            imgui.SetCursorPos(imgui.ImVec2(mx + bnPad + bnBW + gap, bnBY))
            if styledButton('##recDrop', icl('history', L('btn_to_history')), bnBW, bnBH, false) then
                tog.resolveRecover(job.id, false)
            end
        end


        imgui.SetCursorPos(imgui.ImVec2(mx, by))
        if styledButton('##start', isRun and icl('stop', L('btn_stop')) or icl('play', L('btn_start')), bw, bh, true) then
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
        if styledButton('##finish', icl('report', L('btn_finish')), bw, bh, false) then finishSession(job.id) end

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
        local weights = { 1.85, 1.0, 1.0, 1.4, 1.4, 1.4 }
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
        local heads = { L('h_date'), L('h_time'), L('h_orders'), L('h_income'), L('h_expense'), L('h_total') }

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
            imgui.TextDisabled(L('hist_empty'))
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
        if styledButton('##clear', icl('trash', armed and L('clear_confirm') or L('clear_btn')), MW, bh, armed) then
            if armed then
                clearHistory(job.id)
                confirmClear = 0
            else
                confirmClear = os.clock()
            end
        end

        -- итоги за всё время
        local allNet = s.total - s.spent
        local sumStr = L('alltime'):format(
            fmtMoney(s.total), fmtMoney(s.spent), (allNet >= 0) and '+' or '-', fmtMoney(math.abs(allNet)),
            fmtTime(s.secs), s.count)
        local sw = imgui.CalcTextSize(sumStr).x
        dl:AddText(P(mx + math.max(0, (MW - sw) / 2), by2 + bh + 6 * scale), U32(0.62, 0.64, 0.70, 1), sumStr)

    elseif tab == 4 then
        -- настройки
        drawText(dl, P(mx, top), GRAY, icl('gear', L('set_general')))
        -- переключатель: плашка расстояния до метки
        local tgH = math.floor(52 * scale)
        local tgY = top + lh + 8 * scale
        imgui.SetCursorPos(imgui.ImVec2(mx, tgY))
        if imgui.InvisibleButton('##togdist', imgui.ImVec2(MW, tgH)) then
            showDist = not showDist
            saveTheme()
        end
        local tgHov = imgui.IsItemHovered()
        dl:AddRectFilled(P(mx, tgY), P(mx + MW, tgY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
        local tgA = animTo('tgrow', tgHov and 1 or 0, 14)
        if tgA > 0.01 then dl:AddRect(P(mx, tgY), P(mx + MW, tgY + tgH), U32(1, 1, 1, 0.10 * tgA), 11 * scale) end
        drawText(dl, P(mx + 14 * scale, tgY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('target', L('set_dist')))
        dl:AddText(P(mx + 14 * scale, tgY + tgH - lh - 9 * scale), GRAY, L('set_dist_sub'))
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
        drawText(dl, P(mx + 14 * scale, apY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('hourglass', L('set_pause')))
        dl:AddText(P(mx + 14 * scale, apY + tgH - lh - 9 * scale), GRAY, L('set_pause_sub'))
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
            drawText(dl, P(mx + 14 * scale, miRowY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('chart', L('set_mini')))
            dl:AddText(P(mx + 14 * scale, miRowY + tgH - lh - 9 * scale), GRAY, L('set_mini_sub'))
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
            drawText(dl, P(mx + 14 * scale, mpY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('map', L('set_map')))
            local subTxt = (m.key == 0) and L('map_sub_none') or L('map_sub')
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
                kLabel, kc = L('key_press'), ACCENT
            elseif m.key == 0 then
                kLabel, kc = L('key_none'), { 0.55, 0.57, 0.63 }
            else
                kLabel, kc = tog.keyName(m.key) or '?', { 0.92, 0.93, 0.96 }
            end
            kLabel = fitText(kLabel, chipW - 12 * scale)
            dl:AddText(P(chipX + (chipW - imgui.CalcTextSize(kLabel).x) / 2, chipY + (chipH - lh) / 2),
                U32(kc[1], kc[2], kc[3], 1), kLabel)
            if hovK then imgui.SetTooltip(L('key_tip')) end

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

        -- переключатель: autofind
        do
            local afY = apY + (tgH + gap) * 3
            local a = tog.af
            imgui.SetCursorPos(imgui.ImVec2(mx, afY))
            if imgui.InvisibleButton('##togaf', imgui.ImVec2(MW, tgH)) then
                a.on = not a.on
                a.last = 0
                tog.saveAf()
            end
            local afHov = imgui.IsItemHovered()
            dl:AddRectFilled(P(mx, afY), P(mx + MW, afY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
            local afA = animTo('afrow', afHov and 1 or 0, 14)
            if afA > 0.01 then dl:AddRect(P(mx, afY), P(mx + MW, afY + tgH), U32(1, 1, 1, 0.10 * afA), 11 * scale) end
            drawText(dl, P(mx + 14 * scale, afY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl('sync', L('set_af')))
            local afSub = a.id and L('set_af_sub', a.id) or L('set_af_noid')
            dl:AddText(P(mx + 14 * scale, afY + tgH - lh - 9 * scale), GRAY, fitText(afSub, MW - 28 * scale - swW - 16 * scale))
            local fswX, fswY = mx + MW - 14 * scale - swW, afY + (tgH - swH) / 2
            local nowF = os.clock()
            local adtF = math.min(0.05, nowF - a.lastT)
            a.lastT = nowF
            local goalF = a.on and 1 or 0
            a.t = a.t + (goalF - a.t) * (1 - math.exp(-adtF * 16))
            if math.abs(goalF - a.t) < 0.01 then a.t = goalF end
            local tf = a.t
            if tf > 0 then
                dl:AddRectFilled(P(fswX - 3 * scale, fswY - 3 * scale), P(fswX + swW + 3 * scale, fswY + swH + 3 * scale),
                    U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 * tf), swH / 2 + 3 * scale)
            end
            dl:AddRectFilled(P(fswX, fswY), P(fswX + swW, fswY + swH),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.16 + 0.84 * tf), swH / 2)
            dl:AddRect(P(fswX, fswY), P(fswX + swW, fswY + swH),
                U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.40 * (1 - tf)), swH / 2)
            local fkx = fswX + swH / 2 + (swW - swH) * tf
            local fkr, fkg, fkb = ACCENT[1] + (0.07 - ACCENT[1]) * tf, ACCENT[2] + (0.08 - ACCENT[2]) * tf, ACCENT[3] + (0.10 - ACCENT[3]) * tf
            dl:AddCircleFilled(P(fkx, fswY + swH / 2), swH / 2 - 3 * scale, U32(fkr, fkg, fkb, 0.75 + 0.25 * tf), 16)
        end

        -- язык и тема: поле выбора + выпадающий список (окно списка рисует tog.ddRender после основного окна)
        do
            -- категория «Кастомизация» под общими настройками
            local chY = tgY + (tgH + gap) * 5 + 6 * scale
            drawText(dl, P(mx, chY), GRAY, icl('palette', L('set_custom')))
            local cY = chY + lh + 8 * scale
            local selH = math.floor(30 * scale)
            local bound = wp.y + H - 10 * scale -- список не выходит за основное окно
            local function field(id, okey, rowY, selW, iconName, title, sub, curText, dots, items, pick)
                local selX = mx + MW - 14 * scale - selW
                local selY = rowY + (tgH - selH) / 2
                dl:AddRectFilled(P(mx, rowY), P(mx + MW, rowY + tgH), U32(PANEL[1], PANEL[2], PANEL[3], 1), 11 * scale)
                drawText(dl, P(mx + 14 * scale, rowY + 9 * scale), U32(0.90, 0.91, 0.94, 1), icl(iconName, title))
                dl:AddText(P(mx + 14 * scale, rowY + tgH - lh - 9 * scale), GRAY, fitText(sub, selX - mx - 28 * scale))

                imgui.SetCursorPos(imgui.ImVec2(selX, selY))
                local clicked = imgui.InvisibleButton('##sel' .. id, imgui.ImVec2(selW, selH))
                local hov = imgui.IsItemHovered()
                if clicked then
                    local v = not tog[okey]
                    tog.langOpen, tog.themeOpen, tog.styleOpen = false, false, false
                    tog[okey] = v
                end
                local isOpen = tog[okey]
                local a = animTo('dd' .. id, isOpen and 1 or 0, nil, 0.16)
                local sh = animTo('ddsel' .. id, hov and 1 or 0, 14)
                local s0, s1 = P(selX, selY), P(selX + selW, selY + selH)
                dl:AddRectFilled(s0, s1, U32(1, 1, 1, 0.05 + 0.04 * sh), 8 * scale)
                if a > 0.01 then dl:AddRectFilled(s0, s1, U32(ACCENT[1], ACCENT[2], ACCENT[3], 0.14 * a), 8 * scale) end
                dl:AddRect(s0, s1, U32(lerp(1, ACCENT[1], a), lerp(1, ACCENT[2], a), lerp(1, ACCENT[3], a),
                    lerp(0.12 + 0.10 * sh, 0.9, a)), 8 * scale, 15, 1)
                local tx = selX + 12 * scale
                if dots then
                    for k, c in ipairs(dots) do
                        dl:AddCircleFilled(P(selX + 16 * scale + (k - 1) * 12 * scale, selY + selH / 2), 4.5 * scale,
                            U32(c[1], c[2], c[3], 1), 14)
                    end
                    tx = selX + 16 * scale + 3 * 12 * scale
                end
                dl:AddText(P(tx, selY + (selH - lh) / 2), U32(0.92, 0.93, 0.96, 1), fitText(curText, selX + selW - 34 * scale - tx))
                -- стрелка плавно переворачивается при открытии
                local chx, chy, chs = selX + selW - 17 * scale, selY + selH / 2, 3.5 * scale
                local cdir = 1 - 2 * a
                local chc = U32(lerp(0.65, ACCENT[1], a), lerp(0.67, ACCENT[2], a), lerp(0.73, ACCENT[3], a), 1)
                dl:AddLine(P(chx - chs, chy - cdir * chs / 2), P(chx, chy + cdir * chs / 2), chc, 2)
                dl:AddLine(P(chx, chy + cdir * chs / 2), P(chx + chs, chy - cdir * chs / 2), chc, 2)

                -- клик мимо поля и списка закрывает список
                if isOpen and imgui.IsMouseClicked(0) and not hov and not tog.ddIn[id] then tog[okey] = false end
                local o = P(selX, selY + selH + 4 * scale)
                tog.ddReq[#tog.ddReq + 1] = { id = id, okey = okey, alpha = a, open = isOpen, x = o.x, y = o.y, w = selW,
                    bound = bound, yUp = wp.y + selY - 4 * scale, top = wp.y + 10 * scale, maxRows = 5, items = items, pick = pick }
            end

            -- язык
            local litems = {}
            for _, code in ipairs(tog.LANGS) do
                litems[#litems + 1] = { name = tog.LANG_NAME[code], sel = (tog.lang == code), accent = ACCENT }
            end
            field('lang', 'langOpen', cY, math.floor(150 * scale), 'globe', L('set_lang'), L('set_lang_sub'),
                tog.LANG_NAME[tog.lang] or '?', nil, litems, function(i) tog.setLang(tog.LANGS[i]) end)

            -- тема
            local titems = {}
            for i, t in ipairs(THEMES) do
                titems[#titems + 1] = { name = L('theme' .. i), sel = (themeIdx == i), accent = t.accent,
                    dots = { t.accent, t.green, t.red } }
            end
            local cur = THEMES[themeIdx]
            field('theme', 'themeOpen', cY + tgH + gap, math.floor(190 * scale), 'palette', L('set_theme'), L('set_theme_sub'),
                L('theme' .. themeIdx), { cur.accent, cur.green, cur.red }, titems, function(i) setTheme(i) end)

            -- стиль меню
            local sitems = {
                { name = L('style_classic'), sel = (tog.style == 'classic'), accent = ACCENT },
                { name = L('style_aurora'), sel = (tog.style == 'aurora'), accent = ACCENT },
            }
            field('style', 'styleOpen', cY + (tgH + gap) * 2, math.floor(150 * scale), 'gear', L('set_style'), L('set_style_sub'),
                L('style_' .. (tog.style == 'aurora' and 'aurora' or 'classic')), nil, sitems,
                function(i) tog.style = (i == 2) and 'aurora' or 'classic'; tog.saveStyle() end)
        end

    end

    -- подсказка / баланс для проверки
    imgui.SetCursorPos(imgui.ImVec2(mx, H - PAD - imgui.GetTextLineHeight()))
    imgui.PushStyleColor(imgui.Col.Text, V4(0.45, 0.47, 0.54, 1))
    imgui.TextUnformatted(balance and L('footer_bal', fmtMoney(balance)) or L('footer_nobal'))
    imgui.PopStyleColor()

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
    tog.ddRender() -- окна выпадающих списков поверх основного
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
    local str = fmtInt(dist) .. ' ' .. tog.L('unit_m')

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
        local l1 = (dls == 'err') and tog.L('map_err1')
            or ((dls == 'loading' or dls == 'done') and tog.L('map_load1') or tog.L('map_none'))
        local l2 = (dls == 'err') and tog.L('map_err2') or tog.L('map_load2')
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
            distTxt = tog.L('map_dist', fmtInt(math.sqrt((mp.x - px) ^ 2 + (mp.y - py) ^ 2)))
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
    local label = distTxt and (tog.L('map_title') .. '  ·  ' .. distTxt) or tog.L('map_title')
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
    function sampev.onSendCommand(cmd)
        local id = tonumber(cmd:match('^/find%s+(%d+)'))
        if id and id ~= tog.af.id then
            tog.af.id = id
            tog.saveAf()
        end
    end

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
    sampRegisterChatCommand('af', function(arg)
        local a = tog.af
        local n = tonumber(arg or '')
        if n then a.id, a.on = n, true else a.on = not a.on end
        tog.saveAf()
        say('autofind: ' .. (a.on and 'ON' or 'OFF') .. (a.id and (' (/find ' .. a.id .. ')') or ''))
    end)
    say(tog.L('msg_loaded'))
    if not sampev then say(tog.L('msg_nosamp')) end
    if tog.recovered then
        say(tog.L('msg_recovered'))
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

-- выход из игры (/q), вылет, перезагрузка или выгрузка скрипта:
-- сеанс НЕ уходит в историю, а сохраняется в файл и остаётся «незавершённым»
function onScriptTerminate(scr, quit)
    if scr == thisScript() then
        pcall(tog.saveActive)
        saveStats()
        if locked then lockPlayerControl(false) end
    end
end