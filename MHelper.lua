script_name('MHelper')
script_version('2.0.0')

local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local imgui  = require 'mimgui'
local ffi    = require 'ffi'
local sampev = require 'lib.samp.events'
local inicfg = require 'inicfg'
local vkeys  = require 'vkeys'

local SCRIPT_VER  = '2.0.0'
local CONFIG_FILE = 'mhelper.ini'
local FONTS_DIR   = 'C:\\Windows\\Fonts\\'

local function asBool(v)
    if v == true or v == 1 then return true end
    if type(v) == 'string' then
        local s = v:lower():gsub('%s+', '')
        return (s == 'true' or s == '1')
    end
    return false
end

local function safeCStr(buf)
    if buf == nil then return '' end
    local okSize, sz = pcall(ffi.sizeof, buf)
    local n = (okSize and sz and sz > 0) and sz or 0
    if n <= 0 then return '' end
    local ok, s = pcall(ffi.string, buf, n)
    if not ok or type(s) ~= 'string' then return '' end
    local z = s:find('%z')
    if z then s = s:sub(1, z - 1) end
    return s
end

local isMenuOpen = false
local isMedCardOpen = false
local medCardTargetId = -1
local activeTab = 9
local pendingMedCardPrice = 0
local lastMedCardOfferTime = 0
local noMedsBannerUntil = 0
local healCooldowns = {}
local bloodCooldowns = {}

-- ЛЕНТА АКТИВНОСТИ И ОБЩЕЕ СОСТОЯНИЕ ГЛАВНОЙ ВКЛАДКИ (всё в одной таблице, чтобы не раздувать число локальных переменных)
local HOME = {
    log = {},
    nav = { 9, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11 },
    hudDirty = false,
    savedUntil = 0,
    head = 104,
    kinds = {
        heal  = { 0.20, 0.85, 0.45 },
        card  = { 0.66, 0.40, 0.97 },
        money = { 0.20, 0.85, 0.45 },
        blood = { 0.94, 0.27, 0.27 },
        req   = { 0.30, 0.65, 1.00 },
        warn  = { 0.96, 0.62, 0.04 }
    }
}

function HOME.groupDigits(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1 '):reverse()
    return (out:gsub('^ ', ''))
end

function HOME.push(kind, text)
    table.insert(HOME.log, 1, { kind = kind, text = text, t = os.time() })
    if #HOME.log > 40 then table.remove(HOME.log) end
end

local stats = {
    healedCount   = 0,
    healEarned    = 0,
    medCardCount  = 0,
    medCardEarned = 0
}

local defaultConfig = {
    main = {
        autoHealEnabled  = true,
        autoBloodEnabled = true,
        autoMedCardMenu  = true,
        soundNotify      = true,
        soundStopKey     = 35,
        onlineEnabled    = false,
        rememberMe       = true,
        savedAuthEmail   = '',
        savedRefreshToken = '',
        funpayUrl        = 'https://funpay.com/',
        githubRepo       = '',
        githubBranch     = 'main',
        soundVolume      = 1.0,
        strictRequests   = true,
        interiorOnly     = false,
        useRpAction      = true,
        viceCityMode     = false,
        shortMoney       = true,

        rpAction        = '/me передал таблетку пациенту',
        rpBloodAction   = '/me достал жгут, обработал место укола и взял кровь на анализ',
        triggers        = 'хил, лек, лечи, полечи, вылечи, лечен, хиль, таблетку, голова болит',
        medCardTriggers = 'медк, медкарт, мед карт, мед.карт, медкар, мед карту, обновить мед, оформить мед, на неделю, 7 дней, 14 дней, 30 дней, 60 дней',
        bloodTriggers   = 'кровь, возьми кровь, сдать кровь, на кровь, забор крови, кровушк',

        healDistance    = 5.0,
        healDelay       = 1200,
        playerCooldown  = 5,

        priceHealSA         = 200000,
        priceGuardSA        = 800000,
        priceExamPilotSA    = 800000,
        priceExamMilitarySA = 400000,
        priceDrugCureSA     = 400000,
        priceRecipeSA       = 100000,
        priceAntibioticSA   = 50000,
        priceMedCard7SA     = 1000000,
        priceMedCard30SA    = 4500000,

        priceHealVC         = 1000,
        priceGuardVC        = 1000,
        priceMedCard14      = 3500000,
        priceMedCard60      = 5000000,

        fontIndex    = 0,
        fontScale    = 1.0,
        accentColorR = 0.22,
        accentColorG = 0.55,
        accentColorB = 0.94,
        menuBgAlpha  = 0.95,
        hudBgAlpha   = 0.65,

        hudVisible        = false,
        hudShowCount      = true,
        hudShowEarned     = true,
        hudShowMcCount    = true,
        hudShowMcEarned   = true,
        hudPosX           = 30.0,
        hudPosY           = 500.0
    }
}

local config = inicfg.load(defaultConfig, CONFIG_FILE)
if not config or not config.main then
    config = defaultConfig
end
local cfg = config.main

cfg.autoHealEnabled  = asBool(cfg.autoHealEnabled)
cfg.autoBloodEnabled = asBool(cfg.autoBloodEnabled)
cfg.autoMedCardMenu  = asBool(cfg.autoMedCardMenu)
cfg.soundNotify      = asBool(cfg.soundNotify)
cfg.strictRequests   = asBool(cfg.strictRequests)
cfg.interiorOnly     = asBool(cfg.interiorOnly)
cfg.useRpAction      = asBool(cfg.useRpAction)
cfg.viceCityMode     = asBool(cfg.viceCityMode)
cfg.shortMoney       = asBool(cfg.shortMoney)
cfg.hudShowCount     = asBool(cfg.hudShowCount)
cfg.hudShowEarned    = asBool(cfg.hudShowEarned)
cfg.hudShowMcCount   = asBool(cfg.hudShowMcCount)
cfg.hudShowMcEarned  = asBool(cfg.hudShowMcEarned)
cfg.hudVisible       = false

cfg.healDistance   = tonumber(cfg.healDistance) or 5.0
cfg.healDelay      = tonumber(cfg.healDelay) or 1200
cfg.playerCooldown = tonumber(cfg.playerCooldown) or 5
cfg.fontIndex      = tonumber(cfg.fontIndex) or 0
cfg.fontScale      = tonumber(cfg.fontScale) or 1.0
cfg.accentColorR   = tonumber(cfg.accentColorR) or 0.22
cfg.accentColorG   = tonumber(cfg.accentColorG) or 0.55
cfg.accentColorB   = tonumber(cfg.accentColorB) or 0.94
cfg.menuBgAlpha    = tonumber(cfg.menuBgAlpha) or 0.95
cfg.hudBgAlpha     = tonumber(cfg.hudBgAlpha) or 0.65
cfg.soundStopKey   = tonumber(cfg.soundStopKey) or 35
cfg.onlineEnabled  = asBool(cfg.onlineEnabled)
cfg.rememberMe = asBool(cfg.rememberMe)
cfg.savedAuthEmail = tostring(cfg.savedAuthEmail or '')
cfg.savedRefreshToken = tostring(cfg.savedRefreshToken or '')
cfg.funpayUrl      = tostring(cfg.funpayUrl or 'https://funpay.com/')
cfg.githubRepo     = tostring(cfg.githubRepo or '')
cfg.githubBranch   = tostring(cfg.githubBranch or 'main')
cfg.soundVolume    = tonumber(cfg.soundVolume) or 1.0
cfg.hudPosX        = tonumber(cfg.hudPosX) or 30.0
cfg.hudPosY        = tonumber(cfg.hudPosY) or 500.0

local function saveConfig()
    inicfg.save(config, CONFIG_FILE)
end

-- ============================================================
--  ПРОФИЛИ (всё хранится локально в mhelper_profiles.ini)
-- ============================================================
local PROFILES_FILE = 'mhelper_profiles.ini'
local MAX_PROFILES  = 8
local PROFILE_COLORS = {
    {0.23, 0.51, 0.96}, {0.13, 0.77, 0.37}, {0.94, 0.27, 0.27}, {0.96, 0.62, 0.04},
    {0.66, 0.33, 0.97}, {0.02, 0.71, 0.83}, {0.93, 0.28, 0.60}, {0.60, 0.65, 0.72}
}

local profData = inicfg.load({ meta = { active = 1, order = '1', nextId = 2 } }, PROFILES_FILE)
local profFirstRun = (profData.p1 == nil)
local profOrder, activeId = {}, 1
local sessionStart, sessionEarned = os.clock(), 0

local function profSec(id) return 'p' .. id end
local function getProf(id) return profData[profSec(id)] end

local function indexOf(id)
    for i, v in ipairs(profOrder) do if v == id then return i end end
end

local function ensureProfile(id, name)
    local k = profSec(id)
    if type(profData[k]) ~= 'table' then
        profData[k] = { name = name or ('Профиль ' .. id), nick = '', server = '', color = 1,
            healed = 0, healEarned = 0, mcCount = 0, mcEarned = 0, goal = 5000000, created = os.time() }
    end
    if type(profData[k .. '_h']) ~= 'table' then profData[k .. '_h'] = {} end
    if profData[k].avatarKind ~= 'png' and profData[k].avatarKind ~= 'animal' then profData[k].avatarKind = 'letter' end
    if not tonumber(profData[k].avatarAnimal) then profData[k].avatarAnimal = 1 end
    if type(profData[k .. '_d']) ~= 'table' then profData[k .. '_d'] = {} end
end

for id in tostring(profData.meta.order or '1'):gmatch('%d+') do profOrder[#profOrder + 1] = tonumber(id) end
if #profOrder == 0 then profOrder = { 1 } end
activeId = tonumber(profData.meta.active) or profOrder[1]
if not indexOf(activeId) then activeId = profOrder[1] end
for _, id in ipairs(profOrder) do ensureProfile(id, id == 1 and 'Основной' or nil) end

-- перенос статистики из прошлой версии (если она лежала в mhelper.ini)
if profFirstRun and type(config.stats) == 'table' then
    local p = getProf(1)
    p.healed     = tonumber(config.stats.healedCount)   or 0
    p.healEarned = tonumber(config.stats.healEarned)    or 0
    p.mcCount    = tonumber(config.stats.medCardCount)  or 0
    p.mcEarned   = tonumber(config.stats.medCardEarned) or 0
end

local function loadActiveToStats()
    local p = getProf(activeId)
    stats.healedCount   = tonumber(p.healed)     or 0
    stats.healEarned    = tonumber(p.healEarned) or 0
    stats.medCardCount  = tonumber(p.mcCount)    or 0
    stats.medCardEarned = tonumber(p.mcEarned)   or 0
end
loadActiveToStats()

local function saveProfiles()
    local p = getProf(activeId)
    p.healed, p.healEarned = stats.healedCount, stats.healEarned
    p.mcCount, p.mcEarned  = stats.medCardCount, stats.medCardEarned
    profData.meta.active = activeId
    profData.meta.order  = table.concat(profOrder, ',')
    inicfg.save(profData, PROFILES_FILE)
end

-- учёт дохода по часам суток и по дням (для вкладки "Аналитика смен")
local function recordIncome(amount)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    sessionEarned = sessionEarned + amount
    local k = profSec(activeId)
    local H, D = profData[k .. '_h'], profData[k .. '_d']
    local hk = 'h' .. tonumber(os.date('%H'))
    local dk = 'd' .. os.date('%Y%m%d')
    H[hk] = (tonumber(H[hk]) or 0) + amount
    D[dk] = (tonumber(D[dk]) or 0) + amount
end

local function switchProfile(id)
    if id == activeId or not indexOf(id) then return end
    saveProfiles()
    activeId = id
    loadActiveToStats()
    sessionStart, sessionEarned = os.clock(), 0
    saveProfiles()
end

local function createProfile()
    if #profOrder >= MAX_PROFILES then return end
    local id = tonumber(profData.meta.nextId) or (#profOrder + 1)
    while indexOf(id) do id = id + 1 end
    profData.meta.nextId = id + 1
    ensureProfile(id)
    getProf(id).color = (#profOrder % #PROFILE_COLORS) + 1
    profOrder[#profOrder + 1] = id
    switchProfile(id)
end

local function deleteProfile(id)
    local i = indexOf(id)
    if #profOrder <= 1 or not i then return end
    table.remove(profOrder, i)
    local k = profSec(id)
    profData[k], profData[k .. '_h'], profData[k .. '_d'] = nil, nil, nil
    if activeId == id then
        activeId = profOrder[1]
        loadActiveToStats()
        sessionStart, sessionEarned = os.clock(), 0
    end
    saveProfiles()
end

-- Мелодия уведомления (mp3). Положи файл сюда: moonloader\resource\MHelper\alert.mp3
local ALERT_MP3 = getWorkingDirectory() .. '\\resource\\MHelper\\alert.mp3'
local alertStream = nil

local function stopAlertSound()
    if not alertStream then return false end
    pcall(setAudioStreamState, alertStream, 0)
    pcall(releaseAudioStream, alertStream)
    alertStream = nil
    return true
end

local function stopKeyName()
    return (vkeys.id_to_name(cfg.soundStopKey) or ('VK ' .. tostring(cfg.soundStopKey)))
end

local function playAlertSound(alertType)
    if not asBool(cfg.soundNotify) then return end
    stopAlertSound()

    if doesFileExist(ALERT_MP3) then
        local ok, stream = pcall(loadAudioStream, ALERT_MP3)
        if ok and stream then
            alertStream = stream
            pcall(setAudioStreamVolume, alertStream, cfg.soundVolume)
            setAudioStreamState(alertStream, 1)
            sampAddChatMessage('[MHelper] {FFFFFF}Играет мелодия. Остановить: {3B82F6}' .. stopKeyName(), 0x3B82F6)
            return
        end
    end

    -- запасной вариант, если mp3 не найден: игровой звук
    lua_thread.create(function()
        local snd = (alertType == 'nomeds') and 1085 or 1054
        addOneOffSound(0.0, 0.0, 0.0, snd)
        wait(180)
        addOneOffSound(0.0, 0.0, 0.0, snd)
    end)
end

local function readIntPtr(ptr)
    if ptr == nil then return 0 end
    local ok, raw = pcall(ffi.string, ptr, 4)
    if not ok or type(raw) ~= 'string' or #raw ~= 4 then return 0 end
    local b1, b2, b3, b4 = raw:byte(1, 4)
    local n = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    if n >= 2147483648 then n = n - 4294967296 end
    return n
end

local function readFloatPtr(ptr)
    if ptr == nil then return 0.0 end
    local ok, raw = pcall(ffi.string, ptr, 4)
    if not ok or type(raw) ~= 'string' or #raw ~= 4 then return 0.0 end
    local b1, b2, b3, b4 = raw:byte(1, 4)
    local sign = (b4 >= 128) and -1 or 1
    local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
    local mant = (b3 % 128) * 65536 + b2 * 256 + b1
    if exp == 0 then
        if mant == 0 then return 0.0 end
        return sign * math.ldexp(mant / 8388608, -126)
    elseif exp == 255 then
        return 0.0
    end
    return sign * math.ldexp(1 + mant / 8388608, exp - 127)
end

local function formatMoney(amount)
    local n = tonumber(amount) or 0
    if not asBool(cfg.shortMoney) then
        return tostring(math.floor(n))
    end
    if n >= 1000000 then
        local val = n / 1000000
        local str = string.format('%.2f', val):gsub('%.?0+$', '')
        return str .. 'кк'
    elseif n >= 1000 then
        local val = n / 1000
        local str = string.format('%.1f', val):gsub('%.0$', '')
        return str .. 'к'
    end
    return tostring(math.floor(n))
end

local bufRpAction = ffi.new('char[?]', 256)
ffi.copy(bufRpAction, u8(tostring(cfg.rpAction or defaultConfig.main.rpAction)))

local bufRpBlood = ffi.new('char[?]', 256)
ffi.copy(bufRpBlood, u8(tostring(cfg.rpBloodAction or defaultConfig.main.rpBloodAction)))

local bufTriggers = ffi.new('char[?]', 512)
ffi.copy(bufTriggers, u8(tostring(cfg.triggers or defaultConfig.main.triggers)))

local bufMcTriggers = ffi.new('char[?]', 512)
ffi.copy(bufMcTriggers, u8(tostring(cfg.medCardTriggers or defaultConfig.main.medCardTriggers)))

local bufBloodTriggers = ffi.new('char[?]', 512)
ffi.copy(bufBloodTriggers, u8(tostring(cfg.bloodTriggers or defaultConfig.main.bloodTriggers)))

local COLOR_THEMES = {
    { name = 'Синий (Неон)',    r = 0.22, g = 0.55, b = 0.94 },
    { name = 'Голубой (Лед)',   r = 0.14, g = 0.72, b = 0.88 },
    { name = 'Чёрный (Графит)', r = 0.22, g = 0.24, b = 0.28 },
    { name = 'Изумрудный',      r = 0.16, g = 0.68, b = 0.44 },
    { name = 'Фиолетовый',      r = 0.54, g = 0.34, b = 0.90 },
    { name = 'Красный',         r = 0.85, g = 0.24, b = 0.30 }
}

local FONTS_LIST = {
    { name = 'Segoe UI', file = 'segoeui.ttf' },
    { name = 'Arial',    file = 'arial.ttf'   },
    { name = 'Tahoma',   file = 'tahoma.ttf'  },
    { name = 'Verdana',  file = 'verdana.ttf' },
    { name = 'Consolas', file = 'consola.ttf' },
    { name = 'Trebuchet',file = 'trebuc.ttf'  }
}
local loadedFonts = {}
local availableFontNames = {}

local upperToLower = {
    ['А']='а',['Б']='б',['В']='в',['Г']='г',['Д']='д',['Е']='е',['Ё']='ё',['Ж']='ж',['З']='з',['И']='и',['Й']='й',
    ['А']='а',['Б']='б',['В']='в',['Г']='г',['Д']='д',['Е']='е',['Ё']='ё',['Ж']='ж',['З']='з',['И']='и',['Й']='й',
    ['Х']='х',['Ц']='ц',['Ч']='ч',['Ш']='ш',['Щ']='щ',['Ъ']='ъ',['Ы']='ы',['Ь']='ь',['Э']='э',['Ю']='ю',['Я']='я'
}

local function rusLower(str)
    if not str then return '' end
    str = str:lower()
    return (str:gsub('[А-ЯЁ]', upperToLower))
end

local function trim(s)
    return (s:gsub('^%s*(.-)%s*$', '%1'))
end

local ignoreTalkWords = {
    'вчера', 'сегодня', 'завтра', 'уже', 'получил', 'сделал', 'выдал',
    'купил', 'продал', 'почему', 'зачем', 'сколько стоит', 'не надо', 'не нужно', 'отказ'
}

local requestIntentWords = {
    'можно', 'пожалуйста', 'пж', 'пройти', 'сделай', 'выдай', 'оформи', 'обнов',
    'дай', 'нужн', 'надо', 'хочу', 'возьми', 'сдать', 'прими', 'помог', 'доктор', 'врач'
}

local function isDirectRequest(text)
    if not asBool(cfg.strictRequests) then return true end
    local clean = trim(text or '')
    if #clean == 0 or #clean > 65 then return false end

    local lower = rusLower(clean)
    for _, bad in ipairs(ignoreTalkWords) do
        if lower:find(bad, 1, true) then
            return false
        end
    end

    local wordCount = 0
    for _ in lower:gmatch('%S+') do
        wordCount = wordCount + 1
    end

    if wordCount <= 3 then
        return true
    end

    for _, intent in ipairs(requestIntentWords) do
        if lower:find(intent, 1, true) then
            return true
        end
    end

    return false
end

local function matchListTrigger(text, listStr)
    if not text or text == '' or not isDirectRequest(text) then return false end
    local lower = rusLower(text)
    for word in tostring(listStr or ''):gmatch('[^,]+') do
        local w = rusLower(trim(word))
        if #w > 0 and lower:find(w, 1, true) then
            return true
        end
    end
    return false
end

local function getCurrentHealPrice()
    if asBool(cfg.viceCityMode) then
        local p = tonumber(cfg.priceHealVC) or 1000
        return p > 0 and p or 1000
    else
        local p = tonumber(cfg.priceHealSA) or 200000
        return p >= 100000 and p or 200000
    end
end

local function extractCleanMoney(cleanText)
    local raw = cleanText:match('%$([%d%.%,]+)') or cleanText:match('([%d%.%,]+)%$')
    if not raw then return nil end
    local digits = raw:gsub('[^%d]', '')
    return tonumber(digits)
end

local function getMedCardPriceByDays(days)
    local d = tonumber(days)
    if d == 7 then return tonumber(cfg.priceMedCard7SA) or 1000000
    elseif d == 14 then return tonumber(cfg.priceMedCard14) or 3500000
    elseif d == 30 then return tonumber(cfg.priceMedCard30SA) or 4500000
    elseif d == 60 then return tonumber(cfg.priceMedCard60) or 5000000
    end
    return nil
end

-- Подстановка {player} в РП-фразах (Имя Фамилия)
local function rpText(str, id)
    str = tostring(str or '')
    if str:find('{player}', 1, true) then
        local nick = 'пациент'
        if id and sampIsPlayerConnected(id) then
            nick = (sampGetPlayerNickname(id):gsub('_', ' '))
        end
        str = (str:gsub('{player}', function() return nick end))
    end
    return str
end

local function issueMedCard(daysIndex, price)
    if medCardTargetId < 0 then return end
    local targetId = medCardTargetId
    local finalPrice = tonumber(price) or 1000000
    isMedCardOpen = false
    lua_thread.create(function()
        if not sampIsPlayerConnected(targetId) then
            sampAddChatMessage('[MHelper] {FFFFFF}Игрок вышел с сервера.', 0xFF5555)
            return
        end
        if asBool(cfg.useRpAction) then
            sampSendChat('/me оформил медицинскую карту и передал пациенту')
            wait(800)
        end
        pendingMedCardPrice = finalPrice
        lastMedCardOfferTime = os.clock()
        sampSendChat(string.format('/medcard %d 3 %d %d', targetId, daysIndex, finalPrice))
    end)
end

-- ============================================================
--  UI: ХЕЛПЕРЫ И ВИДЖЕТЫ (дизайн как в HTML-макете)
-- ============================================================
local function V2(x, y) return imgui.ImVec2(x, y) end
local function V4(r, g, b, a) return imgui.ImVec4(r, g, b, a or 1.0) end
local function U32(r, g, b, a) return imgui.GetColorU32Vec4(imgui.ImVec4(r, g, b, a or 1.0)) end
local function noScroll() return imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse end

local function uiAccent()
    local r, g, b = cfg.accentColorR, cfg.accentColorG, cfg.accentColorB
    if r < 0.30 and g < 0.30 and b < 0.35 then
        return 0.23, 0.51, 0.96
    end
    return r, g, b
end

local WIN_W, WIN_H = 1100, 720
local SIDE_W  = 230
local MAIN_W  = WIN_W - SIDE_W
local HEAD_H  = 92
local PAD     = 30
local GAP     = 20
local COL_W   = math.floor((MAIN_W - PAD * 2 - GAP) / 2)
local FULL_W  = MAIN_W - PAD * 2
local CARD_PX, CARD_PY = 18, 14

local TABS = {
    { title = 'Авто-функции и РП',  sub = 'Управление автоматическими действиями и ролевыми отыгровками' },
    { title = 'Триггеры и радиус',  sub = 'Ключевые слова запросов и параметры срабатывания' },
    { title = 'Цены на услуги',     sub = 'Стоимость лечения, справок и медицинских карт' },
    { title = 'Внешний вид и HUD',  sub = 'Тема, шрифт и статистика на экране' },
    { title = 'Профили',            sub = 'Отдельная статистика для каждого персонажа или смены' },
    { title = 'Аналитика смен',     sub = 'Доход по часам, прогноз и цель на день' },
    { title = 'Сообщество',         sub = 'Онлайн, профили других игроков и переписка' },
    { title = 'Топ лечений',        sub = 'Рейтинг лекарей среди пользователей MHelper' },
    { title = 'Главная',            sub = 'Сводка по работе, быстрые настройки, профили и HUD' },
    { title = 'Рулетка',           sub = 'Крутите колесо раз в неделю и выигрывайте PRO от 1 часа до 7 дней' },
    { title = 'Сезоны',            sub = 'Активный сезон, сроки, приз и топ-10 лекарей' }
}

local function applyCustomStyle()
    local style = imgui.GetStyle()
    style.WindowRounding   = 14.0
    style.ChildRounding    = 14.0
    style.FrameRounding    = 10.0
    style.GrabRounding     = 8.0
    style.PopupRounding    = 10.0
    style.ScrollbarRounding = 10.0
    style.ScrollbarSize    = 6.0
    style.GrabMinSize      = 14.0
    style.WindowPadding    = imgui.ImVec2(CARD_PX, CARD_PY)
    style.FramePadding     = imgui.ImVec2(14, 9)
    style.ItemSpacing      = imgui.ImVec2(10, 8)
    style.WindowBorderSize = 1.0
    style.ChildBorderSize  = 1.0
    style.FrameBorderSize  = 1.0

    local rawA = imgui.ImVec4(cfg.accentColorR, cfg.accentColorG, cfg.accentColorB, 1.0)
    local rawAH = imgui.ImVec4(math.min(cfg.accentColorR + 0.08, 1.0), math.min(cfg.accentColorG + 0.08, 1.0), math.min(cfg.accentColorB + 0.08, 1.0), 1.0)
    local ar, ag, ab = uiAccent()
    local ui = imgui.ImVec4(ar, ag, ab, 1.0)
    local uiH = imgui.ImVec4(math.min(ar + 0.08, 1.0), math.min(ag + 0.08, 1.0), math.min(ab + 0.08, 1.0), 1.0)

    local c = style.Colors
    c[imgui.Col.WindowBg]             = imgui.ImVec4(0.035, 0.055, 0.115, cfg.menuBgAlpha)
    c[imgui.Col.ChildBg]              = imgui.ImVec4(0, 0, 0, 0)
    c[imgui.Col.PopupBg]              = imgui.ImVec4(0.09, 0.10, 0.125, 0.98)
    c[imgui.Col.Border]               = imgui.ImVec4(ar, ag, ab, 0.30)
    c[imgui.Col.FrameBg]              = imgui.ImVec4(0, 0, 0, 0.30)
    c[imgui.Col.FrameBgHovered]       = imgui.ImVec4(0, 0, 0, 0.40)
    c[imgui.Col.FrameBgActive]        = imgui.ImVec4(0, 0, 0, 0.48)
    c[imgui.Col.Button]               = rawA
    c[imgui.Col.ButtonHovered]        = rawAH
    c[imgui.Col.ButtonActive]         = rawA
    c[imgui.Col.CheckMark]            = ui
    c[imgui.Col.SliderGrab]           = ui
    c[imgui.Col.SliderGrabActive]     = uiH
    c[imgui.Col.Header]               = imgui.ImVec4(ar, ag, ab, 0.18)
    c[imgui.Col.HeaderHovered]        = imgui.ImVec4(ar, ag, ab, 0.28)
    c[imgui.Col.HeaderActive]         = imgui.ImVec4(ar, ag, ab, 0.36)
    c[imgui.Col.ScrollbarBg]          = imgui.ImVec4(0, 0, 0, 0)
    c[imgui.Col.ScrollbarGrab]        = imgui.ImVec4(0.20, 0.255, 0.333, 1.0)
    c[imgui.Col.ScrollbarGrabHovered] = imgui.ImVec4(0.28, 0.33, 0.41, 1.0)
    c[imgui.Col.ScrollbarGrabActive]  = imgui.ImVec4(0.34, 0.40, 0.49, 1.0)
    c[imgui.Col.Separator]            = imgui.ImVec4(1, 1, 1, 0.06)
    c[imgui.Col.Text]                 = imgui.ImVec4(0.89, 0.91, 0.94, 1.0)
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local glyphRanges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
    for _, f in ipairs(FONTS_LIST) do
        local path = FONTS_DIR .. f.file
        if doesFileExist(path) then
            local font = imgui.GetIO().Fonts:AddFontFromFileTTF(path, 16.0, nil, glyphRanges)
            if font then
                table.insert(loadedFonts, font)
                table.insert(availableFontNames, u8(f.name))
            end
        end
    end
    if #loadedFonts == 0 then
        table.insert(loadedFonts, imgui.GetIO().Fonts:AddFontDefault())
        table.insert(availableFontNames, 'Default')
    end
    if cfg.fontIndex >= #loadedFonts then
        cfg.fontIndex = 0
    end
end)

-- ---------- кэш ника для профиля в сайдбаре ----------
local cachedNick, nickUpdate = 'Player', -10
local function getMyNick()
    local now = os.clock()
    if now - nickUpdate > 2.0 then
        nickUpdate = now
        local ok, res = pcall(function()
            local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
            return sampGetPlayerNickname(id)
        end)
        if ok and type(res) == 'string' and #res > 0 then cachedNick = res end
    end
    return cachedNick
end

-- ---------- иконки навигации (рисуются примитивами) ----------
local function drawIcon(kind, dl, cx, cy, col)
    if kind == 1 then
        local pts = { {2,-8}, {-5,1}, {0,1}, {-2,8}, {6,-2}, {1,-2}, {2,-8} }
        for i = 1, #pts - 1 do
            dl:AddLine(V2(cx + pts[i][1], cy + pts[i][2]), V2(cx + pts[i+1][1], cy + pts[i+1][2]), col, 1.6)
        end
    elseif kind == 2 then
        dl:AddCircle(V2(cx, cy), 7.5, col, 24, 1.6)
        dl:AddCircleFilled(V2(cx, cy), 2.4, col)
    elseif kind == 3 then
        dl:AddCircle(V2(cx, cy), 7.5, col, 24, 1.6)
        dl:AddCircle(V2(cx, cy), 3.2, col, 16, 1.4)
    elseif kind == 5 then
        dl:AddCircle(V2(cx, cy - 3.5), 3.6, col, 16, 1.6)
        dl:AddLine(V2(cx - 7, cy + 8), V2(cx - 4, cy + 3), col, 1.6)
        dl:AddLine(V2(cx - 4, cy + 3), V2(cx + 4, cy + 3), col, 1.6)
        dl:AddLine(V2(cx + 4, cy + 3), V2(cx + 7, cy + 8), col, 1.6)
    elseif kind == 6 then
        dl:AddLine(V2(cx - 6, cy + 8), V2(cx - 6, cy + 1), col, 3.0)
        dl:AddLine(V2(cx, cy + 8), V2(cx, cy - 7), col, 3.0)
        dl:AddLine(V2(cx + 6, cy + 8), V2(cx + 6, cy - 2), col, 3.0)
    elseif kind == 8 then
        dl:AddLine(V2(cx - 6, cy - 7), V2(cx + 6, cy - 7), col, 1.6)
        dl:AddLine(V2(cx - 6, cy - 7), V2(cx - 3, cy + 1), col, 1.6)
        dl:AddLine(V2(cx + 6, cy - 7), V2(cx + 3, cy + 1), col, 1.6)
        dl:AddLine(V2(cx - 3, cy + 1), V2(cx + 3, cy + 1), col, 1.6)
        dl:AddLine(V2(cx, cy + 1), V2(cx, cy + 6), col, 1.6)
        dl:AddLine(V2(cx - 4, cy + 7), V2(cx + 4, cy + 7), col, 1.6)
    elseif kind == 9 then
        dl:AddLine(V2(cx - 9, cy), V2(cx, cy - 8), col, 1.8)
        dl:AddLine(V2(cx, cy - 8), V2(cx + 9, cy), col, 1.8)
        dl:AddLine(V2(cx - 6, cy - 1), V2(cx - 6, cy + 7), col, 1.8)
        dl:AddLine(V2(cx - 6, cy + 7), V2(cx + 6, cy + 7), col, 1.8)
        dl:AddLine(V2(cx + 6, cy + 7), V2(cx + 6, cy - 1), col, 1.8)
        dl:AddLine(V2(cx - 2, cy + 7), V2(cx - 2, cy + 2), col, 1.8)
        dl:AddLine(V2(cx - 2, cy + 2), V2(cx + 2, cy + 2), col, 1.8)
        dl:AddLine(V2(cx + 2, cy + 2), V2(cx + 2, cy + 7), col, 1.8)
    elseif kind == 10 then
        dl:AddCircle(V2(cx, cy), 7.5, col, 24, 1.6)
        dl:AddLine(V2(cx - 5, cy - 5), V2(cx + 5, cy + 5), col, 1.4)
        dl:AddLine(V2(cx - 5, cy + 5), V2(cx + 5, cy - 5), col, 1.4)
        dl:AddCircleFilled(V2(cx, cy), 1.8, col)
    elseif kind == 11 then
        dl:AddLine(V2(cx - 6, cy - 7), V2(cx + 6, cy - 7), col, 1.6)
        dl:AddLine(V2(cx - 6, cy - 7), V2(cx - 3, cy + 1), col, 1.6)
        dl:AddLine(V2(cx + 6, cy - 7), V2(cx + 3, cy + 1), col, 1.6)
        dl:AddLine(V2(cx - 3, cy + 1), V2(cx + 3, cy + 1), col, 1.6)
        dl:AddLine(V2(cx, cy + 1), V2(cx, cy + 6), col, 1.6)
        dl:AddLine(V2(cx - 4, cy + 7), V2(cx + 4, cy + 7), col, 1.6)
    elseif kind == 7 then
        dl:AddCircle(V2(cx - 3, cy - 3), 5.0, col, 20, 1.6)
        dl:AddCircle(V2(cx + 3.5, cy + 3), 5.0, col, 20, 1.6)
    else
        dl:AddCircle(V2(cx, cy), 7.5, col, 24, 1.6)
        dl:AddCircleFilled(V2(cx - 3, cy - 2), 1.8, col)
        dl:AddCircleFilled(V2(cx + 2.5, cy - 3), 1.8, col)
        dl:AddCircleFilled(V2(cx + 3, cy + 2.5), 1.8, col)
    end
end

-- ---------- переключатель с анимацией ----------
local toggleAnim = {}
local function toggleSwitch(id, state, tw, th)
    state = asBool(state)
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton('##tg_' .. id, V2(tw, th))
    local target = state and 1.0 or 0.0
    local a = toggleAnim[id]
    if a == nil then a = target end
    a = a + (target - a) * math.min(imgui.GetIO().DeltaTime * 16, 1.0)
    toggleAnim[id] = a

    local ar, ag, ab = uiAccent()
    local r = th / 2
    local col = U32(0.20 + (ar - 0.20) * a, 0.255 + (ag - 0.255) * a, 0.333 + (ab - 0.333) * a, 1.0)
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, V2(p.x + tw, p.y + th), col, r)
    dl:AddCircleFilled(V2(p.x + r + a * (tw - th), p.y + r), r - 3, U32(1, 1, 1, 1))
    return clicked
end

-- ---------- карточки и строки настроек ----------
local curCardW = COL_W

local function cardTopY(lh) return CARD_PY + lh * 0.85 + 14 end
local function rowHeight(lh) return math.floor(lh * 1.85 + 20) end

local function beginCard(id, x, y, w, h, title)
    imgui.SetCursorPos(V2(x, y))
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(0.040, 0.085, 0.165, 0.70))
    imgui.PushStyleColor(imgui.Col.Border,  V4(0.25, 0.55, 1.0, 0.30))
    imgui.BeginChild(id, V2(w, h), true, noScroll())
    curCardW = w
    local lh = imgui.GetTextLineHeight()
    local ar, ag, ab = uiAccent()
    local wp = imgui.GetWindowPos()
    imgui.GetWindowDrawList():AddCircleFilled(V2(wp.x + CARD_PX + 4, wp.y + CARD_PY + lh * 0.85 / 2), 3.5, U32(ar, ag, ab, 1.0))
    imgui.SetWindowFontScale(0.85)
    imgui.SetCursorPos(V2(CARD_PX + 16, CARD_PY))
    imgui.TextColored(V4(ar, ag, ab, 1.0), u8(title))
    imgui.SetWindowFontScale(1.0)
    imgui.SetCursorPos(V2(CARD_PX, cardTopY(lh)))
end

local function endCard()
    imgui.EndChild()
    imgui.PopStyleColor(2)
end

local function rowBegin(label, desc)
    local lh = imgui.GetTextLineHeight()
    local rowH = rowHeight(lh)
    local x0, y0 = imgui.GetCursorPosX(), imgui.GetCursorPosY()
    imgui.SetCursorPos(V2(x0, y0 + 9))
    imgui.Text(u8(label))
    if desc and desc ~= '' then
        imgui.SetCursorPos(V2(x0, y0 + 10 + lh))
        imgui.SetWindowFontScale(0.82)
        imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8(desc))
        imgui.SetWindowFontScale(1.0)
    end
    return x0, y0, rowH, lh
end

local function rowEnd(x0, y0, rowH, isLast)
    if not isLast then
        local wp = imgui.GetWindowPos()
        local ly = wp.y + y0 + rowH - 1
        imgui.GetWindowDrawList():AddLine(V2(wp.x + x0, ly), V2(wp.x + curCardW - x0, ly), U32(1, 1, 1, 0.05), 1.0)
    end
    local sp = imgui.GetStyle().ItemSpacing.y
    imgui.SetCursorPos(V2(x0, y0 + rowH - sp))
    imgui.Dummy(V2(1, 0))
end

local function placeRight(y0, rowH, w, h)
    imgui.SetCursorPos(V2(curCardW - CARD_PX - w, y0 + (rowH - h) / 2))
end

local function toggleRow(key, label, desc, isLast)
    local x0, y0, rowH, lh = rowBegin(label, desc)
    local tw, th = math.floor(lh * 2.6), math.floor(lh * 1.45)
    placeRight(y0, rowH, tw, th)
    if toggleSwitch(key, cfg[key], tw, th) then
        cfg[key] = not asBool(cfg[key])
        saveConfig()
    end
    rowEnd(x0, y0, rowH, isLast)
end

local function sliderRowF(key, label, desc, vmin, vmax, fmt, mult, w, isLast)
    local x0, y0, rowH = rowBegin(label, desc)
    placeRight(y0, rowH, w, imgui.GetFrameHeight())
    local f = imgui.new.float(tonumber(cfg[key]) or vmin)
    imgui.PushItemWidth(w)
    if imgui.SliderFloat('##sl_' .. key, f, vmin, vmax, fmt) then
        cfg[key] = math.floor(readFloatPtr(f) * mult + 0.5) / mult
        saveConfig()
    end
    imgui.PopItemWidth()
    rowEnd(x0, y0, rowH, isLast)
end

local function sliderRowI(key, label, desc, vmin, vmax, fmt, w, isLast)
    local x0, y0, rowH = rowBegin(label, desc)
    placeRight(y0, rowH, w, imgui.GetFrameHeight())
    local iv = imgui.new.int(tonumber(cfg[key]) or vmin)
    imgui.PushItemWidth(w)
    if imgui.SliderInt('##sl_' .. key, iv, vmin, vmax, fmt) then
        cfg[key] = readIntPtr(iv)
        saveConfig()
    end
    imgui.PopItemWidth()
    rowEnd(x0, y0, rowH, isLast)
end

local priceBufs = {}
local function priceRow(key, label, isLast)
    local desc = 'Сейчас: ' .. formatMoney(cfg[key]) .. ' $'
    local x0, y0, rowH, lh = rowBegin(label, desc)
    local w = math.floor(lh * 6.4)
    placeRight(y0, rowH, w, imgui.GetFrameHeight())
    local buf = priceBufs[key]
    if not buf then
        buf = ffi.new('char[?]', 16)
        ffi.copy(buf, tostring(math.floor(tonumber(cfg[key]) or 0)))
        priceBufs[key] = buf
    end
    imgui.PushItemWidth(w)
    if imgui.InputText('##pr_' .. key, buf, 16, imgui.InputTextFlags.CharsDecimal) then
        cfg[key] = tonumber(safeCStr(buf)) or 0
        saveConfig()
    end
    imgui.PopItemWidth()
    rowEnd(x0, y0, rowH, isLast)
end

local function inputGroup(label, id, buf, size, onChange)
    imgui.SetWindowFontScale(0.84)
    imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8(label))
    imgui.SetWindowFontScale(1.0)
    imgui.PushItemWidth(curCardW - CARD_PX * 2)
    if imgui.InputText(id, buf, size) then
        onChange(u8:decode(safeCStr(buf)))
        saveConfig()
    end
    imgui.PopItemWidth()
    imgui.Dummy(V2(1, 6))
end

local function tipBox(text)
    local lh = imgui.GetTextLineHeight()
    local ar, ag, ab = uiAccent()
    local h = math.floor(lh * (1 + 0.84 * 3.3) + 26)
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(ar, ag, ab, 0.06))
    imgui.PushStyleColor(imgui.Col.Border,  V4(ar, ag, ab, 0.30))
    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 12.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V2(14, 10))
    imgui.BeginChild('mh_tip', V2(curCardW - CARD_PX * 2, h), true, noScroll())
    imgui.PopStyleVar(2)
    imgui.TextColored(V4(ar, ag, ab, 1.0), u8('Совет:'))
    imgui.SetWindowFontScale(0.84)
    imgui.PushTextWrapPos(0.0)
    imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8(text))
    imgui.PopTextWrapPos()
    imgui.SetWindowFontScale(1.0)
    imgui.EndChild()
    imgui.PopStyleColor(2)
end

local function contentEnd(y)
    imgui.SetCursorPos(V2(0, y + 16))
    imgui.Dummy(V2(1, 1))
end

local function closeButton(id, x, y, size)
    imgui.SetCursorPos(V2(x, y))
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, V2(size, size))
    local hov = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, V2(p.x + size, p.y + size), hov and U32(0.94, 0.27, 0.27, 1.0) or U32(0.94, 0.27, 0.27, 0.12), 10)
    dl:AddRect(p, V2(p.x + size, p.y + size), U32(0.94, 0.27, 0.27, hov and 1.0 or 0.25), 10)
    local c = V2(p.x + size / 2, p.y + size / 2)
    local d = size * 0.17
    local lc = hov and U32(1, 1, 1, 1) or U32(0.94, 0.27, 0.27, 1.0)
    dl:AddLine(V2(c.x - d, c.y - d), V2(c.x + d, c.y + d), lc, 1.8)
    dl:AddLine(V2(c.x - d, c.y + d), V2(c.x + d, c.y - d), lc, 1.8)
    return clicked
end

-- ============================================================
--  ВКЛАДКИ
-- ============================================================
local function drawTab1()
    local lh = imgui.GetTextLineHeight()
    local rh, top = rowHeight(lh), cardTopY(lh)
    local h1 = math.floor(top + 8 * rh + 12)

    beginCard('mh_c1', PAD, 4, COL_W, h1, 'ОСНОВНЫЕ МОДУЛИ')
    toggleRow('autoHealEnabled',  'Авто-лечение (/heal)', 'Лечить по просьбе в чате')
    toggleRow('autoBloodEnabled', 'Авто-забор крови',     'Команда /takeblood по просьбе')
    toggleRow('autoMedCardMenu',  'Авто-окно медкарт',    'Открывать меню при просьбе')
    toggleRow('soundNotify',      'Звуковые уведомления', 'Запрос медкарты, нет медикаментов')
    toggleRow('strictRequests',   'Умный фильтр',         'Только прямые просьбы')
    toggleRow('interiorOnly',     'Только в интерьере',   'Работать внутри больницы')
    toggleRow('useRpAction',      'РП-отыгровки',         'Отыгрывать перед действиями')
    toggleRow('viceCityMode',     'Режим Vice City',      'Использовать цены в VC $', true)
    endCard()

    beginCard('mh_c2', PAD + COL_W + GAP, 4, COL_W, h1, 'НАСТРОЙКА РП-ОТЫГРОВОК')
    inputGroup('Отыгровка перед лечением (/heal):', '##rp_heal', bufRpAction, 256, function(s) cfg.rpAction = s end)
    inputGroup('Отыгровка перед забором крови (/takeblood):', '##rp_blood', bufRpBlood, 256, function(s) cfg.rpBloodAction = s end)
    imgui.Dummy(V2(1, 6))
    tipBox('Используйте {player} для автоматической подстановки имени игрока (Имя Фамилия) в ваших РП-фразах.')
    endCard()

    contentEnd(4 + h1)
end

local function drawTab2()
    local lh = imgui.GetTextLineHeight()
    local rh, top = rowHeight(lh), cardTopY(lh)
    local sp = imgui.GetStyle().ItemSpacing.y
    local gh = lh * 0.84 + imgui.GetFrameHeight() + sp * 3 + 6 + 4
    local hA = math.floor(top + gh * 3 + 8)
    local hB = math.floor(top + 3 * rh + 12)

    beginCard('mh_c3', PAD, 4, FULL_W, hA, 'КЛЮЧЕВЫЕ СЛОВА (ЧЕРЕЗ ЗАПЯТУЮ)')
    inputGroup('Для лечения (/heal):', '##trig_heal', bufTriggers, 512, function(s) cfg.triggers = s end)
    inputGroup('Для забора крови (/takeblood):', '##trig_blood', bufBloodTriggers, 512, function(s) cfg.bloodTriggers = s end)
    inputGroup('Для открытия меню медкарты:', '##trig_mc', bufMcTriggers, 512, function(s) cfg.medCardTriggers = s end)
    endCard()

    local yB = 4 + hA + GAP
    beginCard('mh_c4', PAD, yB, FULL_W, hB, 'ПАРАМЕТРЫ СРАБАТЫВАНИЯ')
    sliderRowF('healDistance', 'Дистанция срабатывания', 'Радиус до игрока в метрах', 1.0, 15.0, u8('%.1f м'), 10, 260)
    sliderRowI('healDelay', 'Задержка перед командой', 'Пауза перед отправкой, мс', 500, 3000, u8('%d мс'), 260)
    sliderRowI('playerCooldown', 'Кулдаун на игрока', 'Повторный запрос, секунд', 1, 30, u8('%d с'), 260, true)
    endCard()

    contentEnd(yB + hB)
end

local function drawTab3()
    local lh = imgui.GetTextLineHeight()
    local rh, top = rowHeight(lh), cardTopY(lh)
    local hA = math.floor(top + 7 * rh + 12)
    local hB = math.floor(top + 4 * rh + 12)
    local hC = math.floor(top + 2 * rh + 12)
    local xR = PAD + COL_W + GAP

    beginCard('mh_c5', PAD, 4, COL_W, hA, 'ЛЕЧЕНИЕ И СПРАВКИ (SA)')
    priceRow('priceHealSA',         'Лечение (/heal)')
    priceRow('priceGuardSA',        'Справка: охранник')
    priceRow('priceExamPilotSA',    'Справка: пилот')
    priceRow('priceExamMilitarySA', 'Справка: военный')
    priceRow('priceDrugCureSA',     'Лечение зависимости')
    priceRow('priceRecipeSA',       'Рецепт')
    priceRow('priceAntibioticSA',   'Антибиотик', true)
    endCard()

    beginCard('mh_c6', xR, 4, COL_W, hB, 'МЕДИЦИНСКИЕ КАРТЫ')
    priceRow('priceMedCard7SA',  'Медкарта на 7 дней')
    priceRow('priceMedCard14',   'Медкарта на 14 дней')
    priceRow('priceMedCard30SA', 'Медкарта на 30 дней')
    priceRow('priceMedCard60',   'Медкарта на 60 дней', true)
    endCard()

    local yC = 4 + hB + GAP
    beginCard('mh_c7', xR, yC, COL_W, hC, 'VICE CITY (VC $)')
    priceRow('priceHealVC',  'Лечение (/heal)')
    priceRow('priceGuardVC', 'Справка: охранник', true)
    endCard()

    contentEnd(math.max(4 + hA, yC + hC))
end

local function themeRow(isLast)
    local cur
    for _, t in ipairs(COLOR_THEMES) do
        if math.abs(t.r - cfg.accentColorR) < 0.01 and math.abs(t.g - cfg.accentColorG) < 0.01 and math.abs(t.b - cfg.accentColorB) < 0.01 then
            cur = t.name
        end
    end
    local x0, y0, rowH, lh = rowBegin('Цветовая тема', cur or 'Своя')
    local d, gap = math.floor(lh * 1.2), 7
    local total = #COLOR_THEMES * d + (#COLOR_THEMES - 1) * gap
    local sx = curCardW - CARD_PX - total
    local sy = y0 + (rowH - d) / 2
    local dl = imgui.GetWindowDrawList()
    for i, t in ipairs(COLOR_THEMES) do
        imgui.SetCursorPos(V2(sx + (i - 1) * (d + gap), sy))
        local p = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##theme' .. i, V2(d, d)) then
            cfg.accentColorR, cfg.accentColorG, cfg.accentColorB = t.r, t.g, t.b
            saveConfig()
        end
        local hov = imgui.IsItemHovered()
        local c = V2(p.x + d / 2, p.y + d / 2)
        dl:AddCircleFilled(c, d / 2 - 1, U32(t.r, t.g, t.b, 1.0))
        dl:AddCircle(c, d / 2 - 1, U32(1, 1, 1, 0.15), 24, 1.0)
        if cur == t.name then
            dl:AddCircle(c, d / 2 + 2, U32(1, 1, 1, 0.9), 24, 1.6)
        end
        if hov then imgui.SetTooltip(u8(t.name)) end
    end
    rowEnd(x0, y0, rowH, isLast)
end

local function fontRow(isLast)
    local x0, y0, rowH = rowBegin('Шрифт', 'Семейство интерфейса')
    local w = 130
    placeRight(y0, rowH, w, imgui.GetFrameHeight())
    imgui.PushItemWidth(w)
    local preview = availableFontNames[cfg.fontIndex + 1] or 'Default'
    if imgui.BeginCombo('##mh_font', preview) then
        for i, name in ipairs(availableFontNames) do
            if imgui.Selectable(name, cfg.fontIndex == i - 1) then
                cfg.fontIndex = i - 1
                saveConfig()
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()
    rowEnd(x0, y0, rowH, isLast)
end

local function drawTab4()
    local lh = imgui.GetTextLineHeight()
    local rh, top = rowHeight(lh), cardTopY(lh)
    local hA = math.floor(top + 5 * rh + 12)
    local hB = math.floor(top + 6 * rh + (lh + 20) + 22)

    beginCard('mh_c8', PAD, 4, COL_W, hA, 'ТЕМА И ШРИФТ')
    themeRow()
    fontRow()
    sliderRowF('fontScale',   'Масштаб шрифта',    'Размер текста', 0.8, 1.4, '%.2f', 100, 120)
    sliderRowF('menuBgAlpha', 'Прозрачность меню', 'Фон главного окна', 0.5, 1.0, '%.2f', 100, 120)
    sliderRowF('hudBgAlpha',  'Прозрачность HUD',  'Фон статистики', 0.2, 1.0, '%.2f', 100, 120, true)
    endCard()

    beginCard('mh_c9', PAD + COL_W + GAP, 4, COL_W, hB, 'HUD СТАТИСТИКИ')
    toggleRow('hudVisible',      'Показывать HUD',     'Двигайте мышью при меню')
    toggleRow('hudShowCount',    'Вылечено пациентов', 'Счётчик лечений')
    toggleRow('hudShowEarned',   'Доход от лечения',   'Сумма за лечение')
    toggleRow('hudShowMcCount',  'Выдано медкарт',     'Счётчик медкарт')
    toggleRow('hudShowMcEarned', 'Доход от медкарт',   'Сумма за медкарты')
    toggleRow('shortMoney',      'Короткие суммы',     '4.5кк вместо 4500000', true)
    imgui.SetCursorPosX(CARD_PX)
    if imgui.Button(u8('Сбросить статистику'), V2(curCardW - CARD_PX * 2, lh + 20)) then
        stats.healedCount, stats.healEarned, stats.medCardCount, stats.medCardEarned = 0, 0, 0, 0
        saveProfiles()
    end
    endCard()

    contentEnd(4 + math.max(hA, hB))
end


-- ============================================================
--  ОНЛАЙН: сообщество через Supabase
--  HTTP-запросы идут через curl.exe (есть в Windows 10/11), доп. библиотеки не нужны
-- ============================================================
local online, sendMessage, uploadAvatar, getRemoteAvatar, totalUnread, fetchTop, openFunPay, loginAccount, logoutAccount, restoreAuthSession, spinRoulette, roulettePrizeLabel, fetchRouletteStatus, fetchSeason, mhApiRequest, parseIso
local setStatus
do
local SB_URL    = 'https://jqvfimfrengsyrjfsdhx.supabase.co'
local SB_KEY    = 'sb_publishable_7E52gv3dmEXdx2gGVH8Ugw_S7DdRQaG'   -- publishable/anon key; безопасность обеспечивается RLS, это не секрет
local AV_BUCKET = 'mh-avatars'

local RES_DIR   = getWorkingDirectory() .. '\\resource'
local MH_DIR    = RES_DIR .. '\\MHelper'
local TMP_DIR   = MH_DIR .. '\\tmp'
local CACHE_DIR = MH_DIR .. '\\cache'
local AV_DIR    = MH_DIR .. '\\avatars'
for _, d in ipairs({ RES_DIR, MH_DIR, TMP_DIR, CACHE_DIR, AV_DIR }) do pcall(createDirectory, d) end

for _, decl in ipairs({
    'typedef struct { uint32_t cb; char* lpReserved; char* lpDesktop; char* lpTitle; uint32_t dwX; uint32_t dwY; uint32_t dwXSize; uint32_t dwYSize; uint32_t dwXCountChars; uint32_t dwYCountChars; uint32_t dwFillAttribute; uint32_t dwFlags; uint16_t wShowWindow; uint16_t cbReserved2; uint8_t* lpReserved2; void* hStdInput; void* hStdOutput; void* hStdError; } MH_STARTUPINFO;',
    'typedef struct { void* hProcess; void* hThread; uint32_t dwProcessId; uint32_t dwThreadId; } MH_PROCINFO;',
    'int __stdcall CreateProcessA(const char* app, char* cmd, void* pa, void* ta, int inherit, uint32_t flags, void* env, const char* cwd, MH_STARTUPINFO* si, MH_PROCINFO* pi);',
    'uint32_t __stdcall WaitForSingleObject(void* h, uint32_t ms);',
    'int __stdcall CloseHandle(void* h);',
    'void* __stdcall ShellExecuteA(void* hwnd, const char* op, const char* file, const char* params, const char* dir, int show);',
}) do pcall(ffi.cdef, decl) end

openFunPay = function()
    local url = tostring(cfg.funpayUrl or '')
    if not url:match('^https://[A-Za-z0-9%.%-%_/%?=&%%]+$') then
        sampAddChatMessage('[MHelper] Некорректная FunPay-ссылка в mhelper.ini.', 0xFF5555)
        return
    end
    local ok = pcall(function() ffi.C.ShellExecuteA(nil, 'open', url, nil, nil, 1) end)
    if not ok then sampAddChatMessage('[MHelper] Не удалось открыть ссылку. ' .. url, 0x3B82F6) end
end

-- ---------- JSON ----------
local function utf8char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40, 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local JSON_ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function jsonStr(s)
    return '"' .. (tostring(s):gsub('[%c"\\]', function(c) return JSON_ESC[c] or string.format('\\u%04x', c:byte()) end)) .. '"'
end

local function jsonEncode(v)
    local t = type(v)
    if t == 'string' then return jsonStr(v)
    elseif t == 'number' then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format('%d', v) end
        return string.format('%.14g', v)
    elseif t == 'boolean' then return tostring(v)
    elseif t == 'table' then
        if v[1] ~= nil then
            local p = {}
            for i, x in ipairs(v) do p[i] = jsonEncode(x) end
            return '[' .. table.concat(p, ',') .. ']'
        end
        local p = {}
        for k, x in pairs(v) do p[#p + 1] = jsonStr(k) .. ':' .. jsonEncode(x) end
        return '{' .. table.concat(p, ',') .. '}'
    end
    return 'null'
end

local function jsonDecode(str)
    if type(str) ~= 'string' or #str > 2 * 1024 * 1024 then return nil end
    local pos = 1
    local parseValue

    local function skipWs() pos = str:find('%S', pos) or (#str + 1) end

    local function parseString()
        local i = pos + 1
        local buf = {}
        while true do
            local c = str:sub(i, i)
            if c == '' then error('json: unexpected end') end
            if c == '"' then pos = i + 1; return table.concat(buf) end
            if c == '\\' then
                local n = str:sub(i + 1, i + 1)
                if n == 'u' then
                    local cp = tonumber(str:sub(i + 2, i + 5), 16) or 63
                    i = i + 6
                    if cp >= 0xD800 and cp <= 0xDBFF and str:sub(i, i + 1) == '\\u' then
                        local lo = tonumber(str:sub(i + 2, i + 5), 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            i = i + 6
                        end
                    end
                    buf[#buf + 1] = utf8char(cp)
                else
                    local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                    buf[#buf + 1] = map[n] or n
                    i = i + 2
                end
            else
                local j = str:find('["\\]', i) or (#str + 1)
                buf[#buf + 1] = str:sub(i, j - 1)
                i = j
            end
        end
    end

    parseValue = function()
        skipWs()
        local c = str:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            skipWs()
            if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
            while true do
                skipWs()
                local k = parseString()
                skipWs()
                pos = pos + 1 -- ':'
                obj[k] = parseValue()
                skipWs()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == '}' then return obj end
                if d ~= ',' then error('json: bad object') end
            end
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skipWs()
            if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parseValue()
                skipWs()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == ']' then return arr end
                if d ~= ',' then error('json: bad array') end
            end
        elseif c == '"' then
            return parseString()
        elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
        else
            local num = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
            if not num or num == '' then error('json: bad value') end
            pos = pos + #num
            return tonumber(num)
        end
    end

    local ok, res = pcall(parseValue)
    if ok then return res end
    return nil
end

local function urlenc(s)
    return (tostring(s):gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end))
end

local function readAll(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local d = f:read('*a')
    f:close()
    return d
end

local function writeAll(p, d)
    local f = io.open(p, 'wb')
    if not f then return false end
    f:write(d)
    f:close()
    return true
end

local function fileSize(p)
    local f = io.open(p, 'rb')
    if not f then return 0 end
    local n = f:seek('end')
    f:close()
    return n or 0
end

-- ---------- HTTP через curl.exe (не блокирует игру) ----------
local http = { queue = {}, active = {}, n = 0, max = 3 }

local function quoteArg(s)
    return '"' .. (tostring(s):gsub('"', '\\"')) .. '"'
end

local function startProc(cmd)
    local ok, h = pcall(function()
        local si = ffi.new('MH_STARTUPINFO')
        si.cb = ffi.sizeof(si)
        local pi = ffi.new('MH_PROCINFO')
        local buf = ffi.new('char[?]', #cmd + 1)
        ffi.copy(buf, cmd)
        local r = ffi.C.CreateProcessA(nil, buf, nil, nil, 0, 0x08000000, nil, nil, si, pi)
        if r == 0 then return nil end
        ffi.C.CloseHandle(pi.hThread)
        return pi.hProcess
    end)
    if ok then return h end
    return nil
end

function http.request(opt)
    http.queue[#http.queue + 1] = opt
end

local function httpStart(opt)
    http.n = http.n + 1
    local id = http.n
    local hdrF  = TMP_DIR .. '\\h' .. id .. '.txt'
    local outF  = opt.saveTo or (TMP_DIR .. '\\o' .. id .. '.bin')
    local bodyF, tmpBody = opt.bodyFile, nil
    if opt.body then
        bodyF = TMP_DIR .. '\\b' .. id .. '.json'
        tmpBody = bodyF
        writeAll(bodyF, opt.body)
    end
    local a = { 'curl.exe', '-sS', '--connect-timeout', '8', '-m', '15',
                '-X', opt.method or 'GET', '-D', hdrF, '-o', outF }
    for _, h in ipairs(opt.headers or {}) do a[#a + 1] = '-H'; a[#a + 1] = h end
    if bodyF then a[#a + 1] = '--data-binary'; a[#a + 1] = '@' .. bodyF end
    a[#a + 1] = opt.url
    local parts = {}
    for i, x in ipairs(a) do parts[i] = (i == 1) and x or quoteArg(x) end
    local h = startProc(table.concat(parts, ' '))
    if not h then
        local win = os.getenv('SystemRoot')
        if win then
            parts[1] = quoteArg(win .. '\\Sysnative\\curl.exe')
            h = startProc(table.concat(parts, ' '))
        end
    end
    if not h then
        if tmpBody then os.remove(tmpBody) end
        pcall(opt.cb, nil, nil, 'curl.exe not found (need Windows 10+)')
        return
    end
    http.active[#http.active + 1] = { h = h, opt = opt, hdrF = hdrF, outF = outF, tmpBody = tmpBody, t0 = os.clock() }
end

function http.pump()
    while #http.queue > 0 and #http.active < http.max do
        httpStart(table.remove(http.queue, 1))
    end
    local i = 1
    while i <= #http.active do
        local r = http.active[i]
        local done = (ffi.C.WaitForSingleObject(r.h, 0) == 0)
        if not done and os.clock() - r.t0 > 15 then done = true end
        if done then
            ffi.C.CloseHandle(r.h)
            table.remove(http.active, i)
            local hdr = readAll(r.hdrF) or ''
            local status
            for code in hdr:gmatch('HTTP/%S+%s+(%d+)') do status = tonumber(code) end
            local body
            if not r.opt.saveTo then body = readAll(r.outF) end
            os.remove(r.hdrF)
            if not r.opt.saveTo then os.remove(r.outF) end
            if r.tmpBody then os.remove(r.tmpBody) end
            pcall(r.opt.cb, status, body, (not status) and 'no response from server' or nil)
        else
            i = i + 1
        end
    end
end

local function sbReq(method, path, opt, cb)
    opt = opt or {}
    local h = { 'apikey: ' .. SB_KEY }
    if opt.pro and online and online.proToken then
        h[#h + 1] = 'Authorization: Bearer ' .. online.proToken
    elseif online and online.auth and online.auth.access_token then
        h[#h + 1] = 'Authorization: Bearer ' .. online.auth.access_token
    end
    for _, x in ipairs(opt.headers or {}) do h[#h + 1] = x end
    http.request({
        method = method,
        url = path:find('^https') and path or (SB_URL .. path),
        headers = h, body = opt.body, bodyFile = opt.bodyFile, saveTo = opt.saveTo, cb = cb
    })
end

local function authRequest(path, payload, cb)
    http.request({
        method = 'POST', url = SB_URL .. '/auth/v1/' .. path,
        headers = { 'apikey: ' .. SB_KEY, 'Content-Type: application/json' },
        body = jsonEncode(payload or {}), cb = cb
    })
end

local function setAuthSession(data)
    if type(data) ~= 'table' or type(data.access_token) ~= 'string' or type(data.user) ~= 'table' or type(data.user.id) ~= 'string' then
        setStatus(false, 'Не удалось проверить ответ авторизации.'); return false
    end
    online.auth = data
    online.authUserId = data.user.id
    online.authEmail = data.user.email or ''
    online.lastRefresh = os.clock()
    if cfg.rememberMe and type(data.refresh_token) == 'string' and data.refresh_token ~= '' then cfg.savedRefreshToken = data.refresh_token cfg.savedAuthEmail = online.authEmail saveConfig() end
    setStatus(true, 'Вход выполнен: ' .. tostring(online.authEmail))
    online.lastId, online.lastPoll, online.lastUsers = 0, -999, -999
    return true
end

local function verifyPro()
    if not online.auth or not online.auth.access_token then return end
    http.request({
        method = 'POST', url = SB_URL .. '/functions/v1/verify-pro',
        headers = { 'apikey: ' .. SB_KEY, 'Authorization: Bearer ' .. online.auth.access_token, 'Content-Type: application/json' },
        body = jsonEncode({}),
        cb = function(st, body)
            local data = (st == 200) and jsonDecode(body or '') or nil
            if type(data) == 'table' and data.pro == true and type(data.token) == 'string' then
                online.pro, online.proToken = true, data.token
                online.proExpiresAt = os.clock() + (tonumber(data.expires_in) or 3600)
            else
                online.pro, online.proToken, online.proExpiresAt = false, nil, 0
            end
        end
    })
end

loginAccount = function(email, password, signup)
    email, password = trim(email or ''), tostring(password or '')
    if #email < 5 or #email > 254 or not email:match('^[^%s@]+@[^%s@]+%.[^%s@]+$') then
        setStatus(false, 'Проверьте адрес электронной почты.'); return
    end
    if #password < 8 or #password > 128 then
        setStatus(false, 'Пароль должен содержать от 8 до 128 символов.'); return
    end
    if online.authBusy then return end
    online.authBusy = true
    local endpoint = signup and 'signup' or 'token?grant_type=password'
    authRequest(endpoint, { email = email, password = password }, function(st, body)
        online.authBusy = false
        local data = (st and st >= 200 and st < 300) and jsonDecode(body or '') or nil
        if type(data) == 'table' and data.access_token then
            if setAuthSession(data) then verifyPro() end
        elseif signup and type(data) == 'table' and (data.id or (type(data.user) == 'table' and data.user.id)) then
            setStatus(true, 'Аккаунт создан. Подтвердите email, затем войдите.')
        else
            -- Не показываем сырой ответ сервера/внутренние детали.
            setStatus(false, 'Не удалось войти. Проверьте email, пароль и подтверждение почты.')
        end
    end)
end

logoutAccount = function()
    if online.auth and online.auth.access_token then
        http.request({ method = 'POST', url = SB_URL .. '/auth/v1/logout',
            headers = { 'apikey: ' .. SB_KEY, 'Authorization: Bearer ' .. online.auth.access_token }, cb = function() end })
    end
    online.auth, online.authUserId, online.authEmail = nil, nil, nil
    online.pro, online.proToken, online.proExpiresAt = false, nil, 0
    online.uid, online.lastId = nil, 0
    cfg.savedRefreshToken, cfg.savedAuthEmail = '', ''
    saveConfig()
    setStatus(true, 'Вы вышли из аккаунта.')
end

local function refreshAuth()
    if not online.auth or not online.auth.refresh_token or online.authBusy then return end
    if os.clock() - (online.lastRefresh or 0) < 2400 then return end
    online.authBusy = true
    authRequest('token?grant_type=refresh_token', { refresh_token = online.auth.refresh_token }, function(st, body)
        online.authBusy = false
        local data = (st and st >= 200 and st < 300) and jsonDecode(body or '') or nil
        if type(data) == 'table' and data.access_token then
            setAuthSession(data); verifyPro()
        else
            online.auth = nil; online.authUserId = nil; online.pro = false; online.proToken = nil
            cfg.savedRefreshToken, cfg.savedAuthEmail = '', ''
            saveConfig()
            setStatus(false, 'Сессия истекла. Войдите снова.')
        end
    end)
end

-- ---------- состояние ----------
online = {
    uid = nil, nick = nil, serverName = '',
    auth = nil, authUserId = nil, authEmail = nil, authBusy = false,
    pro = false, proToken = nil, proExpiresAt = 0, lastRefresh = -999,
    users = {}, msgs = { all = {} }, dm = {}, unread = {},
    channel = 'all', lastId = 0,
    lastHB = -999, lastPoll = -999, lastUsers = -999,
    busyPoll = false, busyUsers = false, sendAt = -999,
    status = '', statusOk = nil, scrollDown = false,
    top = {}, topMine = false, topBusy = false, lastTop = -999,
    roulette = { busy = false, canSpin = true, nextSpinAt = 0, lastPrizeHours = nil, lastProUntil = '', statusMsg = '', spinning = false, spinStart = 0, angle = 0, lastFetch = -999 },
    season = { busy = false, lastFetch = -999, current = nil, top = {} },
}

setStatus = function(ok, text)
    online.status, online.statusOk = text, ok
end

local function errText(st, body, err)
    if err then return err end
    local msg = tostring(body or ''):match('"message"%s*:%s*"(.-)"')
    return string.format('Error %s: %s', tostring(st), (msg or tostring(body or '')):sub(1, 110))
end

parseIso = function(s)
    local y, mo, d, h, mi, se = tostring(s):match('(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)')
    if not y then return os.time() end
    local utc = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                          hour = tonumber(h), min = tonumber(mi), sec = tonumber(se), isdst = false })
    local now = os.time()
    local off = os.difftime(now, os.time(os.date('!*t', now)))
    return utc + off
end

local function safeName(uid) return (tostring(uid):gsub('[^%w%-]', '_')) end

local function ensureIdentity()
    if not online.auth or not online.authUserId then return false end
    if online.uid then return true end
    if not sampIsLocalPlayerSpawned() then return false end
    local nick = getMyNick()
    if not nick or nick == 'Player' then return false end
    local ok, ip, port = pcall(sampGetCurrentServerAddress)
    if not ok or not ip then return false end
    local okn, sname = pcall(sampGetCurrentServerName)
    online.nick = nick
    online.uid = nick .. '@' .. ip .. ':' .. tostring(port)
    online.serverName = okn and u8(tostring(sname)) or ''
    return true
end

mhApiRequest = function(action, extra, cb)
    if not online.auth or not online.auth.access_token then if cb then cb(nil, nil) end return end
    local body = { action = action, uid = online.uid, nick = online.nick }
    if type(extra) == 'table' then for k, v in pairs(extra) do body[k] = v end end
    http.request({ method = 'POST', url = SB_URL .. '/functions/v1/mh-api', headers = { 'apikey: ' .. SB_KEY, 'Authorization: Bearer ' .. online.auth.access_token, 'Content-Type: application/json' }, body = jsonEncode(body), cb = function(st, b) local data = (st == 200) and jsonDecode(b or '') or nil if cb then cb(st, data) end end })
end
roulettePrizeLabel = function(h)
    h = tonumber(h) or 0
    if h == 1 then return 'PRO на 1 час' elseif h == 6 then return 'PRO на 6 часов' elseif h == 24 then return 'PRO на 1 день' elseif h == 72 then return 'PRO на 3 дня' elseif h == 168 then return 'PRO на 7 дней' else return 'PRO' end
end
fetchRouletteStatus = function()
    if online.roulette.busy or not online.uid then return end
    online.roulette.busy = true
    mhApiRequest('roulette_status', {}, function(st, data)
        online.roulette.busy = false
        if type(data) == 'table' and data.ok then
            online.roulette.canSpin = data.can_spin == true
            online.roulette.nextSpinAt = (type(data.next_spin_at) == 'string') and parseIso(data.next_spin_at) or 0
            if type(data.last_spin) == 'table' then online.roulette.lastPrizeHours = tonumber(data.last_spin.prize_hours) online.roulette.lastProUntil = tostring(data.last_spin.pro_until or '') end
        end
    end)
end
spinRoulette = function()
    if online.roulette.busy or online.roulette.spinning or not online.roulette.canSpin or not online.uid then return end
    online.roulette.busy = true
    online.roulette.statusMsg = 'Крутим...'
    mhApiRequest('roulette_spin', {}, function(st, data)
        online.roulette.busy = false
        if st == 429 then
            online.roulette.canSpin = false
            online.roulette.nextSpinAt = (type(data) == 'table' and type(data.next_spin_at) == 'string') and parseIso(data.next_spin_at) or (os.time() + 7 * 86400)
            online.roulette.statusMsg = 'Следующая попытка — через неделю.'
            return
        end
        if type(data) == 'table' and data.ok then
            online.roulette.canSpin = false
            online.roulette.lastPrizeHours = tonumber(data.prize_hours)
            online.roulette.lastProUntil = tostring(data.pro_until or '')
            online.roulette.nextSpinAt = (type(data.next_spin_at) == 'string') and parseIso(data.next_spin_at) or (os.time() + 7 * 86400)
            online.roulette.spinning = true
            online.roulette.spinStart = os.clock()
            online.roulette.statusMsg = 'Вы выиграли: ' .. roulettePrizeLabel(data.prize_hours) .. '!'
            verifyPro()
        else
            online.roulette.statusMsg = 'Не удалось крутить. Попробуйте позже.'
        end
    end)
end
fetchSeason = function()
    if online.season.busy then return end
    online.season.busy = true
    sbReq('GET', '/rest/v1/mh_seasons?select=id,name,starts_at,ends_at,prize,status&status=eq.active&order=starts_at.desc&limit=1', {}, function(st, b)
        if st ~= 200 then online.season.busy = false return end
        local list = jsonDecode(b or '')
        if type(list) ~= 'table' or #list == 0 then online.season.busy = false online.season.current = nil return end
        online.season.current = list[1]
        local sid = tonumber(list[1].id) or 0
        sbReq('GET', '/rest/v1/mh_season_stats?select=uid,nick,healed,medcards&season_id=eq.' .. sid .. '&order=healed.desc,medcards.desc&limit=10', {}, function(st2, b2)
            online.season.busy = false
            if st2 == 200 then local top = jsonDecode(b2 or '') if type(top) == 'table' then online.season.top = top end end
        end)
    end)
end
local authRestored = false
restoreAuthSession = function()
    if authRestored or online.auth or online.authBusy then return end
    if not cfg.rememberMe or tostring(cfg.savedRefreshToken or '') == '' then return end
    authRestored = true
    online.authBusy = true
    authRequest('token?grant_type=refresh_token', { refresh_token = cfg.savedRefreshToken }, function(st, body)
        online.authBusy = false
        local data = (st and st >= 200 and st < 300) and jsonDecode(body or '') or nil
        if type(data) == 'table' and data.access_token then
            if setAuthSession(data) then verifyPro() end
        else
            cfg.savedRefreshToken, cfg.savedAuthEmail = '', ''
            saveConfig()
        end
    end)
end
local function sendHeartbeat()
    local prof = getProf(activeId)
    local body = {
        owner_id = online.authUserId,
        uid = online.uid, nick = online.nick, server = online.serverName,
        name = u8(tostring(prof.name or '')),
        healed = stats.healedCount, medcards = stats.medCardCount,
        avatar_v = tonumber(prof.avatarV) or 0, avatar_p = activeId, avatar_kind = tostring(prof.avatarKind or 'letter'), avatar_animal = tonumber(prof.avatarAnimal) or 1,
        ver = SCRIPT_VER
    }
    sbReq('POST', '/rest/v1/mh_users?on_conflict=uid', {
        headers = { 'Content-Type: application/json', 'Prefer: resolution=merge-duplicates,return=minimal' },
        body = jsonEncode(body)
    }, function(st, b, err)
        if st and st >= 200 and st < 300 then
            if not online.statusOk then setStatus(true, 'Подключено') end
        else
            setStatus(false, errText(st, b, err))
        end
    end)
end

local function pollUsers()
    if online.busyUsers then return end
    online.busyUsers = true
    sbReq('GET', '/rest/v1/mh_online?select=uid,owner_id,is_pro,nick,server,name,healed,medcards,avatar_v,avatar_p,avatar_kind,avatar_animal,ver&order=nick.asc&limit=60', {},
    function(st, b, err)
        online.busyUsers = false
        if st == 200 then
            local list = jsonDecode(b)
            if type(list) == 'table' then online.users = list end
        else
            setStatus(false, errText(st, b, err))
        end
    end)
end

local function handleMessages(list, first)
    local me = online.uid
    local viewing = isMenuOpen and activeTab == 7
    local shouldScroll = online.chatAtBottom ~= false
    for _, m in ipairs(list) do
        local id = tonumber(m.id) or 0
        if id > online.lastId then online.lastId = id end
        local to = tostring(m.to_uid or 'all')
        local key = (to == 'all') and 'all' or ((m.from_uid == me) and to or tostring(m.from_uid))
        local arr = online.msgs[key]
        if not arr then arr = {}; online.msgs[key] = arr end
        arr[#arr + 1] = { id = id, from_uid = m.from_uid, nick = tostring(m.from_nick or '?'),
                          text = tostring(m.body or ''), t = parseIso(m.created_at) }
        if #arr > 200 then table.remove(arr, 1) end
        if key ~= 'all' then
            local meta = online.dm[key]
            if not meta then meta = {}; online.dm[key] = meta end
            if m.from_uid == me then meta.nick = m.to_nick or meta.nick else meta.nick = m.from_nick end
        end
        if m.from_uid ~= me and not first then
            if not (viewing and online.channel == key) then
                online.unread[key] = (online.unread[key] or 0) + 1
                if key ~= 'all' then
                    sampAddChatMessage('[MHelper] {FFFFFF}Личное сообщение от {3B82F6}' .. u8:decode(tostring(m.from_nick or '?')) ..
                        '{FFFFFF}: ' .. u8:decode(tostring(m.body or '')), 0x3B82F6)
                end
            end
        end
    end
    if not first and viewing and online.channel and shouldScroll then online.scrollDown = true end
end

local function pollMessages()
    if online.busyPoll then return end
    online.busyPoll = true
    local meq = urlenc('"' .. online.uid .. '"')
    local flt = 'or=(to_uid.eq.all,to_uid.eq.' .. meq .. ',from_uid.eq.' .. meq .. ')'
    local first = (online.lastId == 0)
    local path
    if first then
        path = '/rest/v1/mh_messages?select=*&' .. flt .. '&order=id.desc&limit=60'
    else
        path = '/rest/v1/mh_messages?select=*&id=gt.' .. online.lastId .. '&' .. flt .. '&order=id.asc&limit=100'
    end
    sbReq('GET', path, {}, function(st, b, err)
        online.busyPoll = false
        if st == 200 then
            local list = jsonDecode(b)
            if type(list) == 'table' then
                if first then
                    local rev = {}
                    for i = #list, 1, -1 do rev[#rev + 1] = list[i] end
                    list = rev
                end
                    handleMessages(list, first)
            end
        else
            setStatus(false, errText(st, b, err))
        end
    end)
end

sendMessage = function(textUtf8, channel)
    if not online.uid then setStatus(false, 'Нет подключения к серверу игры'); return false end
    if #textUtf8 == 0 then return false end
    if os.clock() - online.sendAt < 1.5 then setStatus(false, 'Слишком часто, подождите секунду'); return false end
    online.sendAt = os.clock()
    channel = channel or online.channel
    textUtf8 = tostring(textUtf8 or '')
    if #textUtf8 > 301 then
        textUtf8 = textUtf8:sub(1, 301)
        while #textUtf8 > 0 and textUtf8:byte(#textUtf8) >= 0x80 and textUtf8:byte(#textUtf8) < 0xC0 do
            textUtf8 = textUtf8:sub(1, -2)
        end
        local last = textUtf8:byte(#textUtf8)
        if last and last >= 0xC0 then textUtf8 = textUtf8:sub(1, -2) end
    end
    do
        local okDec, dec = pcall(function() return u8:decode(textUtf8) end)
        local low = rusLower((okDec and type(dec) == 'string') and dec or textUtf8)
        local hasVirt = low:find('вирт', 1, true) ~= nil
        local hasSale = low:find('прода', 1, true) ~= nil or low:find('купл', 1, true) ~= nil
        local hasMoney = low:find('$', 1, true) ~= nil or low:find('руб', 1, true) ~= nil or low:find('доллар', 1, true) ~= nil
        if hasVirt and (hasSale or hasMoney) then
            setStatus(false, u8('Запрещено правилами'))
            sampAddChatMessage('[MHelper] {FFFFFF}' .. u8('Запрещено правилами'), 0xFF5555)
            sbReq('POST', '/rest/v1/mh_modlog', { headers = { 'Content-Type: application/json', 'Prefer: return=minimal' }, body = jsonEncode({ uid = online.uid, nick = online.nick, text = textUtf8, reason = 'virt_sale', reporter = online.authUserId }) }, function() end)
            return false
        end
    end
    if textUtf8:find('[%z\1-\8\11\12\14-\31]') then return false end
    local body = { owner_id = online.authUserId, from_uid = online.uid, from_nick = online.nick, to_uid = channel, body = textUtf8 }
    if channel ~= 'all' then
        local meta = online.dm[channel]
        for _, u in ipairs(online.users) do
            if u.uid == channel then meta = { nick = u.nick, owner_id = u.owner_id } end
        end
        body.to_nick = meta and meta.nick or nil
        body.to_owner_id = meta and meta.owner_id or nil
    end
    sbReq('POST', '/rest/v1/mh_messages', {
        headers = { 'Content-Type: application/json', 'Prefer: return=minimal' },
        body = jsonEncode(body)
    }, function(st, b, err)
        if st and st >= 200 and st < 300 then
            online.lastPoll = -999
        else
            setStatus(false, errText(st, b, err))
        end
    end)
    return true
end

uploadAvatar = function()
    if not online.uid then setStatus(false, 'Сначала зайдите на сервер'); return end
    local path = AV_DIR .. '\\' .. activeId .. '.png'
    if not doesFileExist(path) then
        setStatus(false, 'Нет файла: resource\\MHelper\\avatars\\' .. activeId .. '.png')
        return
    end
    if fileSize(path) > 200 * 1024 then
        setStatus(false, 'Аватар больше 200 КБ, уменьшите картинку')
        return
    end
    setStatus(true, 'Загружаю аватар...')
    local name = safeName(online.uid) .. '_p' .. activeId .. '.png'
    sbReq('POST', '/storage/v1/object/' .. AV_BUCKET .. '/' .. urlenc(name), {
        headers = { 'Content-Type: image/png', 'x-upsert: true' }, bodyFile = path
    }, function(st, b, err)
        if st and st >= 200 and st < 300 then
            getProf(activeId).avatarV = os.time()
            saveProfiles()
            sendHeartbeat()
            setStatus(true, 'Аватар загружен')
        else
            setStatus(false, errText(st, b, err))
        end
    end)
end

local remoteAv = {}
getRemoteAvatar = function(u)
    local v = tonumber(u.avatar_v) or 0
    if v <= 0 then return nil end
    local name = safeName(u.uid) .. '_p' .. (tonumber(u.avatar_p) or 0)
    local key = name .. '_' .. v
    local path = CACHE_DIR .. '\\' .. key .. '.png'
    local r = remoteAv[key]
    if not r then
        r = { state = 'loading' }
        remoteAv[key] = r
        if doesFileExist(path) and fileSize(path) > 64 then
            r.state = 'file'
        else
            sbReq('GET', '/storage/v1/object/public/' .. AV_BUCKET .. '/' .. urlenc(name) .. '.png?v=' .. v,
                { saveTo = path }, function(st)
                    if st == 200 and fileSize(path) > 64 then r.state = 'file'
                    else r.state = 'fail'; os.remove(path) end
                end)
        end
    end
    if r.state == 'file' then
        local ok, t = pcall(imgui.CreateTextureFromFile, path)
        r.tex = (ok and t) or false
        r.state = 'done'
    end
    return r.tex or nil
end

totalUnread = function()
    local n = 0
    for _, v in pairs(online.unread) do n = n + v end
    return n
end

fetchTop = function()
    if online.topBusy then return end
    online.topBusy = true
    local f = ''
    if online.topMine and online.serverName ~= '' then f = '&server=eq.' .. urlenc(online.serverName) end
    sbReq('GET', '/rest/v1/mh_users?select=uid,owner_id,is_pro,nick,server,name,healed,medcards,avatar_v,avatar_p,avatar_kind,avatar_animal&healed=gt.0&order=healed.desc&limit=30' .. f, {},
    function(st, b, err)
        online.topBusy = false
        if st == 200 then
            local list = jsonDecode(b)
            if type(list) == 'table' then online.top = list end
        else
            setStatus(false, errText(st, b, err))
        end
    end)
end

function online.tick()
    http.pump()
    if online.auth then
        refreshAuth()
        if online.pro and os.clock() >= (online.proExpiresAt or 0) then verifyPro() end
    end
    if not cfg.onlineEnabled then return end
    if not online.auth then return end
    if not ensureIdentity() then return end
    local now = os.clock()
    local viewing = isMenuOpen and activeTab == 7
    if now - online.lastHB >= 30 then online.lastHB = now; sendHeartbeat() end
    if now - online.lastPoll >= (viewing and 3 or 12) then online.lastPoll = now; pollMessages() end
    if now - online.lastUsers >= (viewing and 6 or 60) then online.lastUsers = now; pollUsers() end
    if isMenuOpen and activeTab == 8 and now - online.lastTop >= 20 then online.lastTop = now; fetchTop() end
    if isMenuOpen and activeTab == 10 and now - (online.roulette.lastFetch or -999) >= 30 then online.roulette.lastFetch = now; fetchRouletteStatus() end
    if isMenuOpen and activeTab == 11 and now - (online.season.lastFetch or -999) >= 20 then online.season.lastFetch = now; fetchSeason() end
end
end

-- ============================================================
--  ПРОФИЛИ И АНАЛИТИКА (интерфейс)
-- ============================================================
local function cutUtf8(str, maxBytes)
    str = tostring(str or '')
    if #str <= maxBytes then return str end
    local cut = str:sub(1, maxBytes)
    while #cut > 0 do
        local b = cut:byte(#cut)
        if b >= 0xC0 then cut = cut:sub(1, #cut - 1); break
        elseif b >= 0x80 then cut = cut:sub(1, #cut - 1)
        else break end
    end
    return cut .. '..'
end

local function shortServer(name, n)
    name = tostring(name or '')
    if #name > (n or 26) then name = name:sub(1, n or 26) .. '..' end
    return name
end

local avatarTex = {}
local function getAvatar(id)
    if avatarTex[id] ~= nil then return avatarTex[id] or nil end
    local path = getWorkingDirectory() .. '\\resource\\MHelper\\avatars\\' .. id .. '.png'
    local tex = false
    if doesFileExist(path) then
        local ok, t = pcall(imgui.CreateTextureFromFile, path)
        if ok and t then tex = t end
    end
    avatarTex[id] = tex
    return tex or nil
end

local ANIMAL_COLS = { {0.95,0.65,0.25}, {0.65,0.45,0.30}, {0.95,0.50,0.20}, {0.55,0.45,0.35}, {0.92,0.92,0.92}, {0.45,0.40,0.38}, {0.85,0.75,0.70}, {0.60,0.42,0.28}, {0.55,0.58,0.65}, {0.35,0.75,0.40}, {0.25,0.28,0.35}, {0.90,0.70,0.45} }
local function drawAnimalAvatar(dl, idx, cx, cy, r)
    idx = tonumber(idx) or 1
    if idx < 1 or idx > 12 then idx = 1 end
    local c = ANIMAL_COLS[idx]
    local col, dark, white = U32(c[1], c[2], c[3], 1.0), U32(0.08, 0.10, 0.14, 1.0), U32(1, 1, 1, 1.0)
    if idx == 1 or idx == 3 or idx == 9 then
        dl:AddTriangleFilled(V2(cx - r * 0.75, cy - r * 0.45), V2(cx - r * 0.55, cy - r * 1.05), V2(cx - r * 0.15, cy - r * 0.70), col)
        dl:AddTriangleFilled(V2(cx + r * 0.75, cy - r * 0.45), V2(cx + r * 0.55, cy - r * 1.05), V2(cx + r * 0.15, cy - r * 0.70), col)
    elseif idx == 7 then
        dl:AddRectFilled(V2(cx - r * 0.55, cy - r * 1.25), V2(cx - r * 0.25, cy - r * 0.45), col, 6)
        dl:AddRectFilled(V2(cx + r * 0.25, cy - r * 1.25), V2(cx + r * 0.55, cy - r * 0.45), col, 6)
    elseif idx == 6 then
        for a = 0, 6 do local ang = 0.4 + a * 0.35; dl:AddLine(V2(cx, cy - r * 0.3), V2(cx - math.cos(ang) * r, cy - math.sin(ang) * r * 1.1), col, 2.0) end
    elseif idx ~= 4 and idx ~= 11 then
        dl:AddCircleFilled(V2(cx - r * 0.62, cy - r * 0.62), r * 0.34, (idx == 5) and dark or col)
        dl:AddCircleFilled(V2(cx + r * 0.62, cy - r * 0.62), r * 0.34, (idx == 5) and dark or col)
    end
    dl:AddCircleFilled(V2(cx, cy), r, col)
    if idx == 11 then dl:AddCircleFilled(V2(cx, cy + r * 0.28), r * 0.58, white) end
    if idx == 5 then dl:AddCircleFilled(V2(cx - r * 0.38, cy - r * 0.20), r * 0.30, white); dl:AddCircleFilled(V2(cx + r * 0.38, cy - r * 0.20), r * 0.30, white) end
    if idx == 4 then dl:AddCircle(V2(cx - r * 0.38, cy - r * 0.18), r * 0.34, white, 20, 2.0); dl:AddCircle(V2(cx + r * 0.38, cy - r * 0.18), r * 0.34, white, 20, 2.0) end
    dl:AddCircleFilled(V2(cx - r * 0.34, cy - r * 0.12), r * 0.10, dark)
    dl:AddCircleFilled(V2(cx + r * 0.34, cy - r * 0.12), r * 0.10, dark)
    if idx == 4 or idx == 11 then dl:AddTriangleFilled(V2(cx - r * 0.14, cy + r * 0.08), V2(cx + r * 0.14, cy + r * 0.08), V2(cx, cy + r * 0.30), U32(0.96, 0.62, 0.04, 1.0)) else dl:AddCircleFilled(V2(cx, cy + r * 0.22), r * 0.13, dark) end
end

local function drawAvatar(dl, id, cx, cy, r, letter)
    local prof = getProf(id)
    local col = PROFILE_COLORS[tonumber(prof and prof.color) or 1] or PROFILE_COLORS[1]
    local tex = getAvatar(id)
    if tex then
        local ok = pcall(dl.AddImageRounded, dl, tex, V2(cx - r, cy - r), V2(cx + r, cy + r), V2(0, 0), V2(1, 1), 0xFFFFFFFF, r)
        if ok then
            if online and online.pro then
                dl:AddLine(V2(cx-r*0.55, cy-r-4), V2(cx-r*0.3, cy-r-10), 0xFFFFD45A, 2)
                dl:AddLine(V2(cx-r*0.3, cy-r-10), V2(cx, cy-r-5), 0xFFFFD45A, 2)
                dl:AddLine(V2(cx, cy-r-5), V2(cx+r*0.3, cy-r-10), 0xFFFFD45A, 2)
                dl:AddLine(V2(cx+r*0.3, cy-r-10), V2(cx+r*0.55, cy-r-4), 0xFFFFD45A, 2)
            end
            return
        end
    end
    if prof and prof.avatarKind ~= 'letter' then drawAnimalAvatar(dl, tonumber(prof.avatarAnimal) or 1, cx, cy, r)
        if online and online.pro then
            dl:AddLine(V2(cx-r*0.55, cy-r-4), V2(cx-r*0.3, cy-r-10), 0xFFFFD45A, 2)
            dl:AddLine(V2(cx-r*0.3, cy-r-10), V2(cx, cy-r-5), 0xFFFFD45A, 2)
            dl:AddLine(V2(cx, cy-r-5), V2(cx+r*0.3, cy-r-10), 0xFFFFD45A, 2)
            dl:AddLine(V2(cx+r*0.3, cy-r-10), V2(cx+r*0.55, cy-r-4), 0xFFFFD45A, 2)
        end
        return end
    dl:AddCircleFilled(V2(cx, cy), r, U32(col[1], col[2], col[3], 1.0))
    local lh = imgui.GetTextLineHeight()
    local lw = imgui.CalcTextSize(letter).x
    imgui.SetCursorScreenPos(V2(cx - lw / 2, cy - lh / 2))
    imgui.Text(letter)
    if online and online.pro then
        dl:AddLine(V2(cx-r*0.55, cy-r-4), V2(cx-r*0.3, cy-r-10), 0xFFFFD45A, 2)
        dl:AddLine(V2(cx-r*0.3, cy-r-10), V2(cx, cy-r-5), 0xFFFFD45A, 2)
        dl:AddLine(V2(cx, cy-r-5), V2(cx+r*0.3, cy-r-10), 0xFFFFD45A, 2)
        dl:AddLine(V2(cx+r*0.3, cy-r-10), V2(cx+r*0.55, cy-r-4), 0xFFFFD45A, 2)
    end
end

local function profLetter(prof)
    local n = tostring(prof and prof.name or '?')
    return u8(n:sub(1, 1))
end

local function statRow(label, desc, value, isLast)
    local x0, y0, rowH = rowBegin(label, desc)
    local w = imgui.CalcTextSize(u8(value)).x
    imgui.SetCursorPos(V2(curCardW - CARD_PX - w, y0 + 9))
    imgui.Text(u8(value))
    rowEnd(x0, y0, rowH, isLast)
end

local bufProfName = ffi.new('char[?]', 128)
local profBufId = nil
local confirmDeleteId = nil

local function drawTab5()
    local lh = imgui.GetTextLineHeight()
    local rh, top = rowHeight(lh), cardTopY(lh)
    local btnH = lh + 20
    local n = #profOrder
    local hA = math.floor(top + n * rh + btnH + 30)
    local hB = math.floor(top + (lh * 2 + 26) + 7 * rh + btnH + lh * 2.4 + 40)
    local ar, ag, ab = uiAccent()
    local prof = getProf(activeId)

    if profBufId ~= activeId then
        ffi.copy(bufProfName, u8(tostring(prof.name or '')))
        profBufId = activeId
        confirmDeleteId = nil
    end

    -- список профилей
    beginCard('mh_c10', PAD, 4, COL_W, hA, 'МОИ ПРОФИЛИ')
    local dl = imgui.GetWindowDrawList()
    for i, id in ipairs(profOrder) do
        local p = getProf(id)
        local x0, y0 = imgui.GetCursorPosX(), imgui.GetCursorPosY()
        imgui.SetCursorPos(V2(x0, y0))
        local sp = imgui.GetCursorScreenPos()
        local rw = curCardW - CARD_PX * 2
        if imgui.InvisibleButton('##prof' .. id, V2(rw, rh - 4)) then
            switchProfile(id)
        end
        local hov = imgui.IsItemHovered()
        local act = (id == activeId)
        local pe = V2(sp.x + rw, sp.y + rh - 4)
        if act then
            dl:AddRectFilled(sp, pe, U32(ar, ag, ab, 0.12), 10)
            dl:AddRect(sp, pe, U32(ar, ag, ab, 0.35), 10)
        elseif hov then
            dl:AddRectFilled(sp, pe, U32(1, 1, 1, 0.04), 10)
        end
        local r = (rh - 4) * 0.34
        drawAvatar(dl, id, sp.x + 10 + r, sp.y + (rh - 4) / 2, r, profLetter(p))
        imgui.SetCursorScreenPos(V2(sp.x + 22 + r * 2, sp.y + (rh - 4) / 2 - lh * 0.95))
        imgui.Text(u8(tostring(p.name or '')))
        local tot = (tonumber(p.healEarned) or 0) + (tonumber(p.mcEarned) or 0)
        if act then tot = stats.healEarned + stats.medCardEarned end
        local moneyTxt = u8(formatMoney(tot) .. ' $')
        imgui.SetWindowFontScale(0.80)
        local mw = imgui.CalcTextSize(moneyTxt).x
        imgui.SetCursorScreenPos(V2(sp.x + rw - mw - 12, sp.y + (rh - 4) / 2 - lh * 0.85))
        imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), moneyTxt)
        imgui.SetWindowFontScale(0.78)
        imgui.SetCursorScreenPos(V2(sp.x + 22 + r * 2, sp.y + (rh - 4) / 2 + 1))
        local who = (tostring(p.nick or '') ~= '') and (tostring(p.nick) .. ' | ' .. shortServer(p.server, 22)) or 'ник не привязан'
        imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8(who .. (act and '  *' or '')))
        imgui.SetWindowFontScale(1.0)
        imgui.SetCursorPos(V2(x0, y0 + rh))
    end
    imgui.SetCursorPos(V2(CARD_PX, top + n * rh + 6))
    if #profOrder < MAX_PROFILES then
        if imgui.Button(u8('+ Создать профиль'), V2(curCardW - CARD_PX * 2, btnH)) then
            createProfile()
        end
    else
        imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8('Максимум профилей: ' .. MAX_PROFILES))
    end
    endCard()

    -- текущий профиль
    beginCard('mh_c11', PAD + COL_W + GAP, 4, COL_W, hB, 'ТЕКУЩИЙ ПРОФИЛЬ')
    inputGroup('Название профиля:', '##prof_name', bufProfName, 128, function(sv)
        if #sv > 30 then sv = sv:sub(1, 30)
            while #sv > 0 and sv:byte(#sv) >= 0x80 and sv:byte(#sv) < 0xC0 do sv = sv:sub(1, -2) end
            local lb = sv:byte(#sv)
            if lb and lb >= 0xC0 then sv = sv:sub(1, -2) end end
        prof.name = sv
        saveProfiles()
    end)

    -- цвет
    do
        local x0, y0, rowH, lh2 = rowBegin('Цвет аватара', 'Если нет своей картинки')
        local d, gap = math.floor(lh2 * 1.0), 5
        local total = #PROFILE_COLORS * d + (#PROFILE_COLORS - 1) * gap
        local sx = curCardW - CARD_PX - total
        local sy = y0 + (rowH - d) / 2
        local dl2 = imgui.GetWindowDrawList()
        for i, c in ipairs(PROFILE_COLORS) do
            imgui.SetCursorPos(V2(sx + (i - 1) * (d + gap), sy))
            local p = imgui.GetCursorScreenPos()
            if imgui.InvisibleButton('##pcol' .. i, V2(d, d)) then
                prof.color = i
                saveProfiles()
            end
            local ctr = V2(p.x + d / 2, p.y + d / 2)
            dl2:AddCircleFilled(ctr, d / 2 - 1, U32(c[1], c[2], c[3], 1.0))
            if (tonumber(prof.color) or 1) == i then
                dl2:AddCircle(ctr, d / 2 + 2, U32(1, 1, 1, 0.9), 24, 1.6)
            end
        end
        rowEnd(x0, y0, rowH, false)
    end

    -- привязка к нику и серверу
    do
        local bound = tostring(prof.nick or '')
        local desc = (bound ~= '') and (bound .. ' | ' .. shortServer(prof.server, 30)) or 'Не привязан'
        local x0, y0, rowH = rowBegin('Ник и сервер', desc)
        local bw = 130
        local isMine = (bound ~= '' and bound == getMyNick())
        placeRight(y0, rowH, bw, btnH - 6)
        if imgui.Button(u8(isMine and 'Отвязать' or 'Привязать') .. '##bind', V2(bw, btnH - 6)) then
            if isMine then
                prof.nick, prof.server = '', ''
            else
                prof.nick = getMyNick()
                local okS, sn = pcall(sampGetCurrentServerName)
                prof.server = okS and tostring(sn) or ''
            end
            saveProfiles()
        end
        rowEnd(x0, y0, rowH, false)
    end

    do
        local x0, y0, rowH = rowBegin('Аватар', 'Картинка / буква / животное')
        local kinds, labels, cur = { 'png', 'letter', 'animal' }, { 'Картинка', 'Буква', 'Животное' }, 2
        for i, k in ipairs(kinds) do if prof.avatarKind == k then cur = i end end
        placeRight(y0, rowH, 150, imgui.GetFrameHeight())
        imgui.PushItemWidth(150)
        if imgui.BeginCombo('##avkind', u8(labels[cur])) then for i, k in ipairs(kinds) do if imgui.Selectable(u8(labels[i]), cur == i) then prof.avatarKind = k; avatarTex[activeId] = nil; saveProfiles() end end; imgui.EndCombo() end
        imgui.PopItemWidth()
        rowEnd(x0, y0, rowH, false)
        if prof.avatarKind == 'animal' then
            local x1, y1, rowH1 = rowBegin('Животное', '1 - 12: кот, собака, лиса, сова, панда, ёж, кролик, мишка, волк, лягушка, пингвин, хомяк')
            placeRight(y1, rowH1, 120, imgui.GetFrameHeight())
            local av = imgui.new.int(tonumber(prof.avatarAnimal) or 1)
            imgui.PushItemWidth(120)
            if imgui.SliderInt('##avanimal', av, 1, 12, '%d') then prof.avatarAnimal = readIntPtr(av); saveProfiles() end
            imgui.PopItemWidth()
            rowEnd(x1, y1, rowH1, false)
        end
    end
    local total = stats.healEarned + stats.medCardEarned
    statRow('Вылечено пациентов', 'За всё время профиля', tostring(stats.healedCount), false)
    statRow('Доход от лечения',   '',                     formatMoney(stats.healEarned) .. ' $', false)
    statRow('Выдано медкарт',     '',                     tostring(stats.medCardCount), false)
    statRow('Доход от медкарт',   '',                     formatMoney(stats.medCardEarned) .. ' $', false)
    statRow('Итого заработано',   '',                     formatMoney(total) .. ' $', true)

    imgui.SetCursorPosX(CARD_PX)
    if #profOrder > 1 then
        local label = (confirmDeleteId == activeId) and 'Точно удалить? Нажмите ещё раз' or 'Удалить профиль'
        imgui.PushStyleColor(imgui.Col.Button, V4(0.94, 0.27, 0.27, 0.18))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, V4(0.94, 0.27, 0.27, 0.45))
        imgui.PushStyleColor(imgui.Col.ButtonActive, V4(0.94, 0.27, 0.27, 0.70))
        if imgui.Button(u8(label) .. '##delprof', V2(curCardW - CARD_PX * 2, btnH)) then
            if confirmDeleteId == activeId then
                local did = activeId
                confirmDeleteId = nil
                deleteProfile(did)
            else
                confirmDeleteId = activeId
            end
        end
        imgui.PopStyleColor(3)
    end
    imgui.SetWindowFontScale(0.80)
    imgui.PushTextWrapPos(0.0)
    imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8('Своя картинка: положите PNG в moonloader\\resource\\MHelper\\avatars\\' .. activeId .. '.png и перезайдите в игру.'))
    imgui.PopTextWrapPos()
    imgui.SetWindowFontScale(1.0)
    endCard()

    contentEnd(4 + math.max(hA, hB))
end

-- столбчатая диаграмма
local function drawBars(w, h, values, labels, bestIdx, curIdx, tipFn)
    local lh = imgui.GetTextLineHeight()
    local ar, ag, ab = uiAccent()
    local labH = lh * 0.8 + 6
    local chartH = h - labH
    local p = imgui.GetCursorScreenPos()
    imgui.Dummy(V2(w, h))
    local dl = imgui.GetWindowDrawList()
    local cnt = #values
    local maxv = 1
    for i = 1, cnt do if values[i] > maxv then maxv = values[i] end end
    local gap = 4
    local bw = (w - (cnt - 1) * gap) / cnt
    local mp = imgui.GetMousePos()
    local hov = nil
    dl:AddLine(V2(p.x, p.y + chartH), V2(p.x + w, p.y + chartH), U32(1, 1, 1, 0.10), 1.0)
    for i = 1, cnt do
        local x = p.x + (i - 1) * (bw + gap)
        local v = values[i]
        local bh = (v > 0) and math.max(3, (chartH - 6) * v / maxv) or 2
        local col
        if v <= 0 then col = U32(1, 1, 1, 0.08)
        elseif i == bestIdx then col = U32(ar, ag, ab, 1.0)
        else col = U32(ar, ag, ab, 0.38) end
        dl:AddRectFilled(V2(x, p.y + chartH - bh), V2(x + bw, p.y + chartH), col, 4)
        if mp.x >= x and mp.x <= x + bw and mp.y >= p.y and mp.y <= p.y + chartH then
            hov = i
            dl:AddRect(V2(x, p.y + chartH - bh), V2(x + bw, p.y + chartH), U32(1, 1, 1, 0.8), 4)
        end
        if i == curIdx then
            dl:AddRectFilled(V2(x + bw / 2 - 3, p.y + chartH + 2), V2(x + bw / 2 + 3, p.y + chartH + 4), U32(1, 1, 1, 0.9), 2)
        end
    end
    imgui.SetWindowFontScale(0.75)
    for i = 1, cnt do
        if labels[i] then
            local x = p.x + (i - 1) * (bw + gap)
            local tw = imgui.CalcTextSize(labels[i]).x
            imgui.SetCursorScreenPos(V2(x + bw / 2 - tw / 2, p.y + chartH + 5))
            imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), labels[i])
        end
    end
    imgui.SetWindowFontScale(1.0)
    if hov then imgui.SetTooltip(u8(tipFn(hov))) end
end

local function fmtDuration(minutes)
    minutes = math.floor(minutes + 0.5)
    if minutes >= 60 then return string.format('%d ч %d мин', math.floor(minutes / 60), minutes % 60) end
    return string.format('%d мин', math.max(minutes, 1))
end

local function drawTab6()
    local lh = imgui.GetTextLineHeight()
    local rh, top = rowHeight(lh), cardTopY(lh)
    local ar, ag, ab = uiAccent()
    local prof = getProf(activeId)
    local H = profData[profSec(activeId) .. '_h']
    local D = profData[profSec(activeId) .. '_d']
    local labH = lh * 0.8 + 8

    -- данные по часам
    local hv, hl, bestH, bestV = {}, {}, nil, 0
    for h = 0, 23 do
        local v = tonumber(H['h' .. h]) or 0
        hv[h + 1] = v
        hl[h + 1] = (h % 3 == 0) and tostring(h) or nil
        if v > bestV then bestV, bestH = v, h end
    end
    local curH = tonumber(os.date('%H')) + 1

    -- данные по дням
    local dv, dlb, dsum, dbest, dcnt = {}, {}, 0, 0, 0
    local days7 = {}
    for i = 6, 0, -1 do
        local t = os.time() - i * 86400
        local v = tonumber(D['d' .. os.date('%Y%m%d', t)]) or 0
        dv[#dv + 1] = v
        dlb[#dlb + 1] = os.date('%d', t)
        days7[#days7 + 1] = os.date('%d.%m', t)
        dsum = dsum + v
        if v > dbest then dbest = v end
        if v > 0 then dcnt = dcnt + 1 end
    end
    local today = tonumber(D['d' .. os.date('%Y%m%d')]) or 0

    -- 1) по часам суток
    local chartH = 150
    local h1 = math.floor(top + chartH + labH + lh * 1.5 + 26)
    beginCard('mh_c12', PAD, 4, FULL_W, h1, 'ДОХОД ПО ЧАСАМ СУТОК (ЗА ВСЁ ВРЕМЯ ПРОФИЛЯ)')
    imgui.SetCursorPos(V2(CARD_PX, top))
    drawBars(curCardW - CARD_PX * 2, chartH + labH, hv, hl, bestH and (bestH + 1) or nil, curH, function(i)
        return string.format('%02d:00 - %02d:00\n%s $', i - 1, i % 24, formatMoney(hv[i]))
    end)
    imgui.SetCursorPos(V2(CARD_PX, top + chartH + labH + 10))
    imgui.SetWindowFontScale(0.88)
    if bestH then
        imgui.TextColored(V4(ar, ag, ab, 1.0), u8(string.format('Золотой час: %02d:00 - %02d:00', bestH, (bestH + 1) % 24)))
        imgui.SameLine()
        imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8('  в это время вы зарабатываете больше всего (' .. formatMoney(bestV) .. ' $)'))
    else
        imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8('Данных пока нет. Лечите пациентов и выдавайте медкарты, график заполнится сам.'))
    end
    imgui.SetWindowFontScale(1.0)
    endCard()

    local y2 = 4 + h1 + GAP

    -- 2) смена
    local h2 = math.floor(top + 5 * rh + 36)
    beginCard('mh_c13', PAD, y2, COL_W, h2, 'СМЕНА')
    local elapsed = os.clock() - sessionStart
    local rate = (elapsed >= 120 and sessionEarned > 0) and (sessionEarned / (elapsed / 3600)) or 0
    local goal = tonumber(prof.goal) or 5000000
    statRow('Заработано сегодня', 'По календарному дню', formatMoney(today) .. ' $', false)
    statRow('Темп (за сессию)', 'Прогноз дохода в час', rate > 0 and (formatMoney(math.floor(rate)) .. ' $/ч') or 'считаю...', false)
    statRow('Золотой час', 'Лучшее время для работы', bestH and string.format('%02d:00', bestH) or '-', false)
    do
        local x0, y0, rowH = rowBegin('Цель на день', 'Двигайте ползунок')
        local sw = 150
        placeRight(y0, rowH, sw, imgui.GetFrameHeight())
        local iv = imgui.new.int(math.floor(goal))
        imgui.PushItemWidth(sw)
        if imgui.SliderInt('##goal', iv, 500000, 50000000, '%d $') then
            prof.goal = math.floor(readIntPtr(iv) / 100000 + 0.5) * 100000
            saveProfiles()
        end
        imgui.PopItemWidth()
        rowEnd(x0, y0, rowH, false)
    end
    local eta
    if today >= goal then eta = 'Цель выполнена!'
    elseif rate > 0 then eta = '~' .. fmtDuration((goal - today) / rate * 60)
    else eta = 'нужен темп' end
    statRow('До цели', 'Осталось: ' .. formatMoney(math.max(goal - today, 0)) .. ' $', eta, true)

    -- прогресс-бар цели
    local frac = math.min(1.0, goal > 0 and today / goal or 0)
    local wp = imgui.GetWindowPos()
    local bx, by = wp.x + CARD_PX, wp.y + top + 5 * rh + 6
    local bw = curCardW - CARD_PX * 2
    local wdl = imgui.GetWindowDrawList()
    wdl:AddRectFilled(V2(bx, by), V2(bx + bw, by + 12), U32(1, 1, 1, 0.08), 6)
    if frac > 0 then
        wdl:AddRectFilled(V2(bx, by), V2(bx + math.max(12, bw * frac), by + 12), U32(ar, ag, ab, 1.0), 6)
    end
    endCard()

    -- 3) 7 дней
    local h3 = math.floor(top + 110 + labH + 2 * rh + 20)
    beginCard('mh_c14', PAD + COL_W + GAP, y2, COL_W, h3, 'ПОСЛЕДНИЕ 7 ДНЕЙ')
    imgui.SetCursorPos(V2(CARD_PX, top))
    local bestDay = nil
    for i, v in ipairs(dv) do if v == dbest and v > 0 then bestDay = i end end
    drawBars(curCardW - CARD_PX * 2, 110 + labH, dv, dlb, bestDay, 7, function(i)
        return days7[i] .. '\n' .. formatMoney(dv[i]) .. ' $'
    end)
    imgui.SetCursorPos(V2(CARD_PX, top + 110 + labH + 6))
    statRow('Среднее за рабочий день', dcnt .. ' из 7 дней с доходом', formatMoney(dcnt > 0 and math.floor(dsum / dcnt) or 0) .. ' $', false)
    statRow('Лучший день', 'За последнюю неделю', formatMoney(dbest) .. ' $', true)
    endCard()

    contentEnd(y2 + math.max(h2, h3))
end

-- ---------- вкладка "Сообщество" ----------
local bufChat = ffi.new('char[?]', 302)

local function drawRemoteAvatar(dl, u, cx, cy, r)
    local tex = getRemoteAvatar(u)
    if tex then
        local ok = pcall(dl.AddImageRounded, dl, tex, V2(cx - r, cy - r), V2(cx + r, cy + r), V2(0, 0), V2(1, 1), 0xFFFFFFFF, r)
        if ok then
            if u.is_pro == true or u.pro == true then
                dl:AddLine(V2(cx-r*0.55, cy-r-4), V2(cx-r*0.3, cy-r-10), 0xFFFFD45A, 2)
                dl:AddLine(V2(cx-r*0.3, cy-r-10), V2(cx, cy-r-5), 0xFFFFD45A, 2)
                dl:AddLine(V2(cx, cy-r-5), V2(cx+r*0.3, cy-r-10), 0xFFFFD45A, 2)
                dl:AddLine(V2(cx+r*0.3, cy-r-10), V2(cx+r*0.55, cy-r-4), 0xFFFFD45A, 2)
            end
            return
        end
    end
    local nick = tostring(u.nick or '?')
    local sum = 0
    for i = 1, #nick do sum = sum + nick:byte(i) end
    local col = PROFILE_COLORS[sum % #PROFILE_COLORS + 1]
    if u.avatar_kind == 'animal' or u.avatar_kind == 'png' then drawAnimalAvatar(dl, tonumber(u.avatar_animal) or 1, cx, cy, r)
        if u.is_pro == true or u.pro == true then
            dl:AddLine(V2(cx-r*0.55, cy-r-4), V2(cx-r*0.3, cy-r-10), 0xFFFFD45A, 2)
            dl:AddLine(V2(cx-r*0.3, cy-r-10), V2(cx, cy-r-5), 0xFFFFD45A, 2)
            dl:AddLine(V2(cx, cy-r-5), V2(cx+r*0.3, cy-r-10), 0xFFFFD45A, 2)
            dl:AddLine(V2(cx+r*0.3, cy-r-10), V2(cx+r*0.55, cy-r-4), 0xFFFFD45A, 2)
        end
        return end
    dl:AddCircleFilled(V2(cx, cy), r, U32(col[1], col[2], col[3], 1.0))
    local letter = nick:sub(1, 1):upper()
    local lh = imgui.GetTextLineHeight()
    local lw = imgui.CalcTextSize(letter).x
    imgui.SetCursorScreenPos(V2(cx - lw / 2, cy - lh / 2))
    imgui.Text(letter)
    if u.is_pro == true or u.pro == true then
        dl:AddLine(V2(cx-r*0.55, cy-r-4), V2(cx-r*0.3, cy-r-10), 0xFFFFD45A, 2)
        dl:AddLine(V2(cx-r*0.3, cy-r-10), V2(cx, cy-r-5), 0xFFFFD45A, 2)
        dl:AddLine(V2(cx, cy-r-5), V2(cx+r*0.3, cy-r-10), 0xFFFFD45A, 2)
        dl:AddLine(V2(cx+r*0.3, cy-r-10), V2(cx+r*0.55, cy-r-4), 0xFFFFD45A, 2)
    end
end

local function channelTitle(key)
    if key == 'all' then return u8('Общий чат') end
    for _, u in ipairs(online.users) do
        if u.uid == key then return (u.name ~= nil and u.name ~= '') and (u.name .. ' (' .. u.nick .. ')') or u.nick end
    end
    local meta = online.dm[key]
    return meta and meta.nick or key
end

local authEmailBuf = ffi.new('char[256]')
local authPassBuf = ffi.new('char[130]')
local function drawAuthPanel(width)
    imgui.TextColored(V4(0.82, 0.88, 0.96, 1.0), u8('Аккаунт MHelper'))
    if online.auth then
        imgui.Text(u8('Выполнен вход: ') .. tostring(online.authEmail or ''))
        imgui.TextColored(online.pro and V4(1.0, 0.82, 0.25, 1.0) or V4(0.62, 0.68, 0.78, 1.0),
            u8(online.pro and 'PRO активен' or 'Обычный аккаунт'))
        if imgui.Button(u8('Выйти из аккаунта'), V2(width, 28)) then logoutAccount() end
    else
        imgui.PushItemWidth(width)
        imgui.InputText('##mh_email', authEmailBuf, 256)
        if safeCStr(authEmailBuf) == '' then imgui.SameLine(); imgui.TextColored(V4(0.55,0.60,0.68,1), u8('Email')) end
        imgui.InputText('##mh_pass', authPassBuf, 130, imgui.InputTextFlags.Password)
        if safeCStr(authPassBuf) == '' then imgui.SameLine(); imgui.TextColored(V4(0.55,0.60,0.68,1), u8('Пароль')) end
        imgui.PopItemWidth()
        if imgui.Button(u8('Войти'), V2(width * 0.48, 28)) then loginAccount(safeCStr(authEmailBuf), safeCStr(authPassBuf), false) end
        imgui.SameLine()
        if imgui.Button(u8('Регистрация'), V2(width * 0.48, 28)) then loginAccount(safeCStr(authEmailBuf), safeCStr(authPassBuf), true) end
    end
end

local function drawTab7()
    local lh = imgui.GetTextLineHeight()
    local top = cardTopY(lh)
    local ar, ag, ab = uiAccent()
    local muted = V4(0.58, 0.64, 0.72, 1.0)
    local btnH = lh + 16

    -- список профилей
    if not cfg.onlineEnabled then
        local h = math.floor(top + lh * 11 + btnH + 40)
        beginCard('mh_c20', PAD, 4, FULL_W, h, 'ОНЛАЙН-РЕЖИМ ВЫКЛЮЧЕН')
        imgui.PushTextWrapPos(0.0)
        imgui.Text(u8('Онлайн-режим показывает других пользователей MHelper, позволяет переписываться и обмениваться аватарками.'))
        imgui.Dummy(V2(1, 6))
        imgui.TextColored(muted, u8('Что отправляется на сервер: ваш ник, название сервера, название профиля, число вылеченных пациентов и выданных медкарт, версия скрипта и аватар (если загрузите). Суммы денег, пароли и данные аккаунта не отправляются.'))
        imgui.Dummy(V2(1, 6))
        imgui.TextColored(muted, u8('Сообщения в общем чате видят все пользователи. Сообщения хранятся 3 дня. Отключить режим можно в любой момент.'))
        imgui.PopTextWrapPos()
        imgui.Dummy(V2(1, 10))
        drawAuthPanel(curCardW - CARD_PX * 2)
        imgui.Dummy(V2(1, 8))
        if imgui.Button(u8('Включить онлайн-режим'), V2(curCardW - CARD_PX * 2, btnH + 6)) then
            if online.auth then cfg.onlineEnabled = true; saveConfig()
            else setStatus(false, 'Сначала войдите в аккаунт MHelper.') end
        end
        endCard()
        contentEnd(4 + h)
        return
    end

    if not online.auth then
        local h = math.floor(top + lh * 10 + btnH + 50)
        beginCard('mh_c20_auth', PAD, 4, FULL_W, h, 'АВТОРИЗАЦИЯ SUPABASE')
        drawAuthPanel(FULL_W - CARD_PX * 2)
        imgui.Dummy(V2(1, 8))
        imgui.TextColored(muted, u8('Пароль не сохраняется в ini и остаётся только в поле ввода.'))
        endCard(); contentEnd(4 + h); return
    end

    local H = 484
    local leftW = 262
    local rightW = FULL_W - leftW - GAP
    online.unread[online.channel] = 0

    -- ---------- слева: список ----------
    beginCard('mh_c21', PAD, 4, leftW, H, 'ОНЛАЙН')
    local entries = {}
    entries[1] = { key = 'all', title = u8('Общий чат'), sub = u8(#online.users .. ' в сети'), isAll = true }
    local seen = {}
    for _, u in ipairs(online.users) do
        seen[u.uid] = true
        if u.uid ~= online.uid then
            local title = (u.name ~= nil and u.name ~= '') and u.name or u.nick
            entries[#entries + 1] = { key = u.uid, title = title, sub = u.nick .. u8('  |  вылечено ') .. tostring(u.healed or 0), user = u }
        end
    end
    local offline = {}
    for key, meta in pairs(online.dm) do
        if not seen[key] and key ~= online.uid then
            offline[#offline + 1] = { key = key, title = tostring(meta.nick or key), sub = u8('не в сети'), off = true,
                                      user = { uid = key, nick = meta.nick or '?', avatar_v = 0 } }
        end
    end
    table.sort(offline, function(a, b) return a.title < b.title end)
    for _, e in ipairs(offline) do entries[#entries + 1] = e end

    local listW = leftW - CARD_PX * 2
    local listH = H - top - btnH * 2 - 112
    imgui.SetCursorPos(V2(CARD_PX, top))
    imgui.BeginChild('mh_ulist', V2(listW, listH), false)
    local ldl = imgui.GetWindowDrawList()
    local rowH, rw = 52, listW - 10
    for i, e in ipairs(entries) do
        local sp = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##ue' .. i, V2(rw, rowH)) then
            online.channel = e.key
            online.scrollDown = true
        end
        local hov = imgui.IsItemHovered()
        local act = (online.channel == e.key)
        local pe = V2(sp.x + rw, sp.y + rowH)
        if act then
            ldl:AddRectFilled(sp, pe, U32(ar, ag, ab, 0.14), 10)
            ldl:AddRect(sp, pe, U32(ar, ag, ab, 0.35), 10)
        elseif hov then
            ldl:AddRectFilled(sp, pe, U32(1, 1, 1, 0.05), 10)
        end
        local r = 17
        local cx, cy = sp.x + 12 + r, sp.y + rowH / 2
        if e.isAll then
            ldl:AddCircleFilled(V2(cx, cy), r, U32(ar, ag, ab, 0.9))
            local gl = imgui.CalcTextSize('#').x
            imgui.SetCursorScreenPos(V2(cx - gl / 2, cy - lh / 2))
            imgui.Text('#')
        else
            drawRemoteAvatar(ldl, e.user, cx, cy, r)
            if not e.off then ldl:AddCircleFilled(V2(cx + r - 3, cy + r - 3), 4.5, U32(0.13, 0.77, 0.37, 1.0)) end
        end
        imgui.SetCursorScreenPos(V2(sp.x + 22 + r * 2, cy - lh * 0.95))
        imgui.Text(e.title)
        imgui.SetWindowFontScale(0.78)
        imgui.SetCursorScreenPos(V2(sp.x + 22 + r * 2, cy + 1))
        imgui.TextColored(muted, e.sub)
        imgui.SetWindowFontScale(1.0)
        local un = online.unread[e.key] or 0
        if un > 0 then
            ldl:AddCircleFilled(V2(sp.x + rw - 16, cy), 9, U32(0.94, 0.27, 0.27, 1.0))
            local s = tostring(math.min(un, 99))
            local sw = imgui.CalcTextSize(s).x * 0.78
            imgui.SetWindowFontScale(0.78)
            imgui.SetCursorScreenPos(V2(sp.x + rw - 16 - sw / 2, cy - lh * 0.78 / 2))
            imgui.Text(s)
            imgui.SetWindowFontScale(1.0)
        end
        imgui.SetCursorScreenPos(V2(sp.x, sp.y + rowH + 3))
    end
    imgui.Dummy(V2(1, 4))
    imgui.EndChild()

    imgui.SetCursorPos(V2(CARD_PX, top + listH + 8))
    if imgui.Button(u8('Загрузить мой аватар'), V2(listW, btnH)) then uploadAvatar() end
    if imgui.IsItemHovered() then
        imgui.SetTooltip(u8('PNG до 200 КБ: moonloader\\resource\\MHelper\\avatars\\' .. activeId .. '.png'))
    end
    imgui.SetCursorPos(V2(CARD_PX, top + listH + 8 + btnH + 6))
    if imgui.Button(u8('Отключить онлайн-режим'), V2(listW, btnH)) then
        cfg.onlineEnabled = false
        saveConfig()
    end
    imgui.SetCursorPos(V2(CARD_PX, top + listH + 8 + (btnH + 6) * 2 + 2))
    imgui.SetWindowFontScale(0.80)
    imgui.PushTextWrapPos(leftW - CARD_PX)
    if online.status ~= '' then
        local c = (online.statusOk == false) and V4(0.94, 0.27, 0.27, 1.0) or V4(0.13, 0.77, 0.37, 1.0)
        imgui.TextColored(c, u8(online.status))
    elseif not online.uid then
        imgui.TextColored(muted, u8('Войдите в аккаунт и подключитесь к серверу...'))
    end
    imgui.PopTextWrapPos()
    imgui.SetWindowFontScale(1.0)
    endCard()

    -- ---------- справа: чат ----------
    local rx = PAD + leftW + GAP
    beginCard('mh_c22', rx, 4, rightW, H, 'ЧАТ: ' .. u8:decode(channelTitle(online.channel)))
    local inW = rightW - CARD_PX * 2
    local msgH = H - top - btnH - 24
    imgui.SetCursorPos(V2(CARD_PX, top))
    imgui.PushStyleColor(imgui.Col.ChildBg, V4(0.04, 0.045, 0.06, 0.55))
    imgui.BeginChild('mh_msgs', V2(inW, msgH), true)
    if imgui.GetScrollY and imgui.GetScrollMaxY then online.chatAtBottom = imgui.GetScrollY() >= imgui.GetScrollMaxY() - 20 end
    local msgs = online.msgs[online.channel] or {}
    if #msgs == 0 then
        imgui.TextColored(muted, u8(online.channel == 'all' and 'Пока нет сообщений. Напишите первым!' or 'Нет сообщений. Напишите первым!'))
    end
    imgui.PushTextWrapPos(0.0)
    for _, m in ipairs(msgs) do
        local mine = (m.from_uid == online.uid)
        imgui.TextColored(mine and V4(ar, ag, ab, 1.0) or V4(0.90, 0.92, 0.96, 1.0), m.nick)
        imgui.SameLine()
        imgui.SetWindowFontScale(0.78)
        imgui.TextColored(muted, os.date('%H:%M', m.t))
        imgui.SetWindowFontScale(1.0)
        imgui.Text(m.text)
        imgui.Dummy(V2(1, 3))
    end
    imgui.PopTextWrapPos()
    if online.scrollDown and imgui.SetScrollHereY then
        imgui.SetScrollHereY(1.0)
        online.scrollDown = false
    end
    imgui.EndChild()
    imgui.PopStyleColor(1)

    imgui.SetCursorPos(V2(CARD_PX, top + msgH + 8))
    imgui.PushItemWidth(inW - 100)
    local enter = imgui.InputText('##chatin', bufChat, 302, imgui.InputTextFlags.EnterReturnsTrue)
    imgui.PopItemWidth()
    imgui.SameLine()
    local clicked = imgui.Button(u8('Отправить'), V2(92, 0))
    if enter or clicked then
        local text = cutUtf8(trim(safeCStr(bufChat)), 301)
        if #text > 0 and sendMessage(text, online.channel) then
            ffi.fill(bufChat, 302, 0)
        end
        if enter then imgui.SetKeyboardFocusHere(-1) end
    end
    endCard()

    contentEnd(4 + H)
end


local function drawTab8()
    local lh = imgui.GetTextLineHeight()
    local top = cardTopY(lh)
    local ar, ag, ab = uiAccent()
    local muted = V4(0.58, 0.64, 0.72, 1.0)
    local btnH = lh + 14

    if not cfg.onlineEnabled then
        local h = math.floor(top + lh * 5 + btnH + 40)
        beginCard('mh_c30', PAD, 4, FULL_W, h, 'ТОП ПО ЛЕЧЕНИЯМ')
        imgui.PushTextWrapPos(0.0)
        imgui.Text(u8('Рейтинг строится по данным пользователей онлайн-режима. Включите его, чтобы увидеть топ и попасть в него.'))
        imgui.PopTextWrapPos()
        imgui.Dummy(V2(1, 10))
        if imgui.Button(u8('Включить онлайн-режим'), V2(curCardW - CARD_PX * 2, btnH + 6)) then
            cfg.onlineEnabled = true
            saveConfig()
        end
        endCard()
        contentEnd(4 + h)
        return
    end

    local H = 484
    beginCard('mh_c31', PAD, 4, FULL_W, H, 'ТОП ЛЕКАРЕЙ ПО КОЛИЧЕСТВУ ЛЕЧЕНИЙ')

    imgui.SetCursorPos(V2(CARD_PX, top - 2))
    for i, lab in ipairs({ 'Все серверы', 'Мой сервер' }) do
        local sel = ((i == 2) == online.topMine)
        if sel then
            imgui.PushStyleColor(imgui.Col.Button, V4(ar, ag, ab, 0.35))
        end
        if imgui.Button(u8(lab) .. '##tf' .. i, V2(150, btnH)) then
            online.topMine = (i == 2)
            online.lastTop = -999
            online.top = {}
        end
        if sel then imgui.PopStyleColor(1) end
        if i == 1 then imgui.SameLine() end
    end
    imgui.SameLine()
    imgui.SetWindowFontScale(0.80)
    imgui.TextColored(muted, u8('  обновляется раз в 20 секунд'))
    imgui.SetWindowFontScale(1.0)

    local listW = curCardW - CARD_PX * 2
    local listH = H - top - btnH - 40
    imgui.SetCursorPos(V2(CARD_PX, top + btnH + 8))
    imgui.BeginChild('mh_toplist', V2(listW, listH), false)
    local dl = imgui.GetWindowDrawList()
    local rowH, rw = 50, listW - 12
    local medal = { { 0.96, 0.76, 0.05 }, { 0.75, 0.78, 0.82 }, { 0.80, 0.50, 0.20 } }
    local myRank
    if #online.top == 0 then
        imgui.TextColored(muted, u8(online.topBusy and 'Загрузка...' or 'Пока никого нет. Вылечите первого пациента, и вы появитесь в топе.'))
    end
    for i, u in ipairs(online.top) do
        local mine = (u.uid == online.uid)
        if mine then myRank = i end
        local sp = imgui.GetCursorScreenPos()
        imgui.Dummy(V2(rw, rowH))
        local pe = V2(sp.x + rw, sp.y + rowH)
        if mine then
            dl:AddRectFilled(sp, pe, U32(ar, ag, ab, 0.14), 10)
            dl:AddRect(sp, pe, U32(ar, ag, ab, 0.40), 10)
        elseif i % 2 == 1 then
            dl:AddRectFilled(sp, pe, U32(1, 1, 1, 0.03), 10)
        end
        local cy = sp.y + rowH / 2
        local mc = medal[i]
        local rs = tostring(i)
        local rwid = imgui.CalcTextSize(rs).x
        if mc then dl:AddCircleFilled(V2(sp.x + 26, cy), 13, U32(mc[1], mc[2], mc[3], 0.22)) end
        imgui.SetCursorScreenPos(V2(sp.x + 26 - rwid / 2, cy - lh / 2))
        if mc then imgui.TextColored(V4(mc[1], mc[2], mc[3], 1.0), rs) else imgui.TextColored(muted, rs) end
        drawRemoteAvatar(dl, u, sp.x + 68, cy, 16)
        local title = (u.name ~= nil and u.name ~= '') and u.name or u.nick
        imgui.SetCursorScreenPos(V2(sp.x + 96, cy - lh * 0.95))
        imgui.Text(cutUtf8(title, 36) .. (mine and u8('  (вы)') or ''))
        imgui.SetWindowFontScale(0.78)
        imgui.SetCursorScreenPos(V2(sp.x + 96, cy + 1))
        imgui.TextColored(muted, cutUtf8(tostring(u.nick) .. ' | ' .. tostring(u.server or ''), 60))
        local hs = tostring(u.healed or 0) .. u8(' лечений')
        local hw = imgui.CalcTextSize(hs).x
        imgui.SetCursorScreenPos(V2(sp.x + rw - hw - 14, cy - lh * 0.95))
        imgui.SetWindowFontScale(1.0)
        imgui.TextColored(mc and V4(mc[1], mc[2], mc[3], 1.0) or V4(0.90, 0.92, 0.96, 1.0), hs)
        imgui.SetWindowFontScale(0.78)
        local ms = u8('медкарт: ') .. tostring(u.medcards or 0)
        local mw = imgui.CalcTextSize(ms).x
        imgui.SetCursorScreenPos(V2(sp.x + rw - mw - 14, cy + 1))
        imgui.TextColored(muted, ms)
        imgui.SetWindowFontScale(1.0)
        imgui.SetCursorScreenPos(V2(sp.x, sp.y + rowH + 3))
    end
    imgui.Dummy(V2(1, 4))
    imgui.EndChild()

    imgui.SetCursorPos(V2(CARD_PX, top + btnH + 8 + listH + 6))
    imgui.SetWindowFontScale(0.84)
    if myRank then
        imgui.TextColored(V4(ar, ag, ab, 1.0), u8('Ваше место: ' .. myRank))
    else
        imgui.TextColored(muted, u8('Вас пока нет в топе (показаны 30 лучших). Счётчик берётся из активного профиля.'))
    end
    imgui.SetWindowFontScale(1.0)
    endCard()

    contentEnd(4 + H)
end
-- ============================================================
--  ГЛАВНАЯ: неоновый дашборд (как в макете)
--  Необязательно: положите картинку resource\MHelper\bg.png - она станет фоном окна
-- ============================================================
do
local DX = 20
local DW = MAIN_W - 4 - DX * 2

function HOME.bg()
    if not HOME.bgTried then
        HOME.bgTried = true
        local path = getWorkingDirectory() .. '\\resource\\MHelper\\bg.png'
        if doesFileExist(path) then
            local ok, t = pcall(imgui.CreateTextureFromFile, path)
            if ok and t then HOME.bgTex = t end
        end
    end
    return HOME.bgTex
end

function HOME.dtext(x, y, scale, col, str)
    imgui.SetWindowFontScale(scale)
    imgui.SetCursorScreenPos(V2(x, y))
    imgui.TextColored(col, str)
    imgui.SetWindowFontScale(1.0)
end

function HOME.dwidth(scale, str)
    imgui.SetWindowFontScale(scale)
    local w = imgui.CalcTextSize(str).x
    imgui.SetWindowFontScale(1.0)
    return w
end

HOME.ecgPts = { {0, 0.5}, {0.30, 0.5}, {0.38, 0.30}, {0.45, 0.78}, {0.53, 0.04}, {0.61, 0.96}, {0.69, 0.5}, {1, 0.5} }

function HOME.ecg(dl, x, y, w, h, col, thick)
    local p = HOME.ecgPts
    for i = 1, #p - 1 do
        dl:AddLine(V2(x + w * p[i][1], y + h * p[i][2]), V2(x + w * p[i + 1][1], y + h * p[i + 1][2]), col, thick or 1.5)
    end
end

-- неоновая рамка с мягким свечением
function HOME.neon(dl, x, y, w, h, rad)
    local ar, ag, ab = uiAccent()
    dl:AddRectFilled(V2(x, y), V2(x + w, y + h), U32(0.03, 0.07, 0.15, 0.74), rad)
    local a = { 0.11, 0.07, 0.04 }
    for i = 1, 3 do
        dl:AddRect(V2(x - i, y - i), V2(x + w + i, y + h + i), U32(ar, ag, ab, a[i]), rad + i)
    end
    dl:AddRect(V2(x, y), V2(x + w, y + h), U32(ar, ag, ab, 0.60), rad)
    dl:AddLine(V2(x + rad, y + 1), V2(x + w - rad, y + 1), U32(1, 1, 1, 0.10), 1.0)
end

function HOME.icon(kind, dl, cx, cy, col)
    if kind == 'bolt' then drawIcon(1, dl, cx, cy, col)
    elseif kind == 'user' then drawIcon(5, dl, cx, cy, col)
    elseif kind == 'bars' then drawIcon(6, dl, cx, cy, col)
    elseif kind == 'house' then drawIcon(9, dl, cx, cy, col)
    elseif kind == 'drop' then
        dl:AddCircleFilled(V2(cx, cy + 2), 5.5, col)
        dl:AddTriangleFilled(V2(cx, cy - 8), V2(cx - 4.8, cy), V2(cx + 4.8, cy), col)
    elseif kind == 'card' then
        dl:AddRect(V2(cx - 9, cy - 6), V2(cx + 9, cy + 6), col, 3)
        dl:AddLine(V2(cx - 9, cy - 2), V2(cx + 9, cy - 2), col, 1.6)
        dl:AddLine(V2(cx - 6, cy + 2), V2(cx, cy + 2), col, 1.6)
    elseif kind == 'sound' then
        dl:AddRectFilled(V2(cx - 8, cy - 3), V2(cx - 3, cy + 3), col)
        dl:AddTriangleFilled(V2(cx - 3, cy - 3), V2(cx + 3, cy - 8), V2(cx + 3, cy + 8), col)
        dl:AddTriangleFilled(V2(cx - 3, cy - 3), V2(cx + 3, cy + 8), V2(cx - 3, cy + 3), col)
        dl:AddLine(V2(cx + 6, cy - 3), V2(cx + 8, cy - 5), col, 1.6)
        dl:AddLine(V2(cx + 6, cy + 3), V2(cx + 8, cy + 5), col, 1.6)
    elseif kind == 'shield' then
        local p = { {-7, -7}, {7, -7}, {7, 1}, {0, 8}, {-7, 1}, {-7, -7} }
        for i = 1, #p - 1 do
            dl:AddLine(V2(cx + p[i][1], cy + p[i][2]), V2(cx + p[i + 1][1], cy + p[i + 1][2]), col, 1.6)
        end
        dl:AddLine(V2(cx - 3, cy - 1), V2(cx - 1, cy + 2), col, 1.6)
        dl:AddLine(V2(cx - 1, cy + 2), V2(cx + 3, cy - 3), col, 1.6)
    elseif kind == 'plus' then
        dl:AddLine(V2(cx - 6, cy), V2(cx + 6, cy), col, 3.0)
        dl:AddLine(V2(cx, cy - 6), V2(cx, cy + 6), col, 3.0)
    elseif kind == 'sliders' then
        dl:AddLine(V2(cx - 8, cy - 5), V2(cx + 8, cy - 5), col, 1.6)
        dl:AddLine(V2(cx - 8, cy + 1), V2(cx + 8, cy + 1), col, 1.6)
        dl:AddLine(V2(cx - 8, cy + 7), V2(cx + 8, cy + 7), col, 1.6)
        dl:AddCircleFilled(V2(cx - 3, cy - 5), 2.6, col)
        dl:AddCircleFilled(V2(cx + 4, cy + 1), 2.6, col)
        dl:AddCircleFilled(V2(cx - 1, cy + 7), 2.6, col)
    elseif kind == 'pulse' then
        HOME.ecg(dl, cx - 10, cy - 7, 20, 14, col, 1.6)
    elseif kind == 'info' then
        dl:AddCircle(V2(cx, cy), 8, col, 20, 1.5)
        dl:AddLine(V2(cx, cy - 1), V2(cx, cy + 4), col, 1.6)
        dl:AddCircleFilled(V2(cx, cy - 4), 1.3, col)
    end
end

-- карточка со статистикой (верхний ряд)
function HOME.statCard(o, x, y, w, h, kind, title, value, sub, col, data)
    local dl = imgui.GetWindowDrawList()
    local lh = imgui.GetTextLineHeight()
    local px, py = o.x + x, o.y + y
    HOME.neon(dl, px, py, w, h, 14)
    local ix, iy = px + 14, py + (h - 46) / 2
    local c = V2(ix + 23, iy + 23)
    local ic = U32(col[1], col[2], col[3], 1.0)
    local dark = U32(0.03, 0.07, 0.15, 1.0)
    dl:AddRectFilled(V2(ix, iy), V2(ix + 46, iy + 46), U32(col[1], col[2], col[3], 0.16), 12)
    dl:AddRect(V2(ix, iy), V2(ix + 46, iy + 46), U32(col[1], col[2], col[3], 0.45), 12)
    if kind == 'heart' then
        dl:AddCircleFilled(V2(c.x - 5, c.y - 3), 6.5, ic)
        dl:AddCircleFilled(V2(c.x + 5, c.y - 3), 6.5, ic)
        dl:AddTriangleFilled(V2(c.x - 11.2, c.y - 0.5), V2(c.x + 11.2, c.y - 0.5), V2(c.x, c.y + 12), ic)
        HOME.ecg(dl, c.x - 9, c.y - 5, 18, 10, dark, 1.6)
    elseif kind == 'dollar' then
        dl:AddCircle(c, 16, ic, 28, 2.0)
        local dw = HOME.dwidth(1.3, '$')
        HOME.dtext(c.x - dw / 2, c.y - lh * 1.3 / 2, 1.3, V4(col[1], col[2], col[3], 1.0), '$')
    elseif kind == 'kit' then
        dl:AddRectFilled(V2(c.x - 13, c.y - 8), V2(c.x + 13, c.y + 11), ic, 4)
        dl:AddRect(V2(c.x - 5, c.y - 13), V2(c.x + 5, c.y - 8), ic, 2)
        dl:AddLine(V2(c.x - 6, c.y + 1.5), V2(c.x + 6, c.y + 1.5), dark, 3.0)
        dl:AddLine(V2(c.x, c.y - 4.5), V2(c.x, c.y + 7.5), dark, 3.0)
    elseif kind == 'clock' then
        dl:AddCircle(c, 16, ic, 28, 2.0)
        dl:AddLine(c, V2(c.x, c.y - 9), ic, 2.0)
        dl:AddLine(c, V2(c.x + 7, c.y + 3), ic, 2.0)
    end

    HOME.dtext(px + 70, py + 9, 0.95, V4(0.80, 0.88, 0.98, 1.0), u8(title))
    HOME.dtext(px + 70, py + 25, 1.7, V4(1, 1, 1, 1), u8(value))
    HOME.dtext(px + 70, py + 60, 0.78, V4(col[1], col[2], col[3], 1.0), u8(sub))

    if kind == 'heart' then
        HOME.ecg(dl, px + w - 62, py + 12, 48, 22, U32(col[1], col[2], col[3], 0.85), 1.4)
    elseif kind == 'clock' and data then
        local mx = 1
        for _, v in ipairs(data) do if v > mx then mx = v end end
        for i, v in ipairs(data) do
            local bh = (v > 0) and math.max(3, 24 * v / mx) or 2
            local bx = px + w - 60 + (i - 1) * 8
            dl:AddRectFilled(V2(bx, py + 38 - bh), V2(bx + 6, py + 38), U32(col[1], col[2], col[3], 0.30 + 0.70 * i / #data), 2)
        end
    end
end

-- панель (дочернее окно) с заголовком; masterKey - необязательный переключатель справа в заголовке
function HOME.panelBegin(id, o, x, y, w, h, title, icon, masterKey, masterLabel)
    local parentDl = imgui.GetWindowDrawList()
    HOME.neon(parentDl, o.x + x, o.y + y, w, h, 14)
    imgui.SetCursorPos(V2(x, y))
    imgui.BeginChild(id, V2(w, h), false, noScroll())
    local ar, ag, ab = uiAccent()
    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()
    local lh = imgui.GetTextLineHeight()
    HOME.icon(icon, dl, wp.x + 28, wp.y + 22, U32(ar, ag, ab, 1.0))
    imgui.SetWindowFontScale(1.05)
    imgui.SetCursorPos(V2(50, 22 - lh * 1.05 / 2))
    imgui.Text(u8(title))
    imgui.SetWindowFontScale(1.0)
    dl:AddLine(V2(wp.x + 16, wp.y + 42), V2(wp.x + w - 16, wp.y + 42), U32(1, 1, 1, 0.08), 1.0)
    if masterKey then
        local tw, th = 34, 18
        imgui.SetCursorPos(V2(w - 16 - tw, 22 - th / 2))
        if toggleSwitch('m_' .. masterKey, cfg[masterKey], tw, th) then
            cfg[masterKey] = not asBool(cfg[masterKey])
            saveConfig()
        end
        if masterLabel then
            local lw = HOME.dwidth(0.8, u8(masterLabel))
            HOME.dtext(wp.x + w - 16 - tw - 8 - lw, wp.y + 22 - lh * 0.8 / 2, 0.8, V4(0.58, 0.68, 0.80, 1.0), u8(masterLabel))
        end
    end
end

function HOME.toggle(key, label, icon, y, w)
    local lh = imgui.GetTextLineHeight()
    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()
    local ar, ag, ab = uiAccent()
    HOME.icon(icon, dl, wp.x + 28, wp.y + y + 15, U32(ar, ag, ab, 1.0))
    imgui.SetCursorPos(V2(50, y + 15 - lh / 2))
    imgui.Text(u8(label))
    local tw, th = 42, 22
    imgui.SetCursorPos(V2(w - 16 - tw, y + 15 - th / 2))
    if toggleSwitch(key, cfg[key], tw, th) then
        cfg[key] = not asBool(cfg[key])
        saveConfig()
    end
end

function HOME.miniToggle(key, label, y, w, x0, tw)
    local lh = imgui.GetTextLineHeight()
    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()
    local ar, ag, ab = uiAccent()
    dl:AddCircleFilled(V2(wp.x + 24, wp.y + y + 12), 4.5, U32(ar, ag, ab, 1.0))
    HOME.dtext(wp.x + 36, wp.y + y + 12 - lh * 0.85 / 2, 0.85, V4(0.89, 0.91, 0.94, 1.0), u8(label))
    local th = 18
    imgui.SetCursorPos(V2(x0, y + 12 - th / 2))
    if toggleSwitch(key, cfg[key], tw, th) then
        cfg[key] = not asBool(cfg[key])
        saveConfig()
    end
end

function HOME.sliderF(key, label, y, w, vmin, vmax, fmt, mult)
    imgui.SetCursorPos(V2(16, y + 4))
    imgui.TextColored(V4(0.78, 0.85, 0.95, 1.0), u8(label))
    local sw = 124
    imgui.SetCursorPos(V2(w - 16 - sw, y))
    local f = imgui.new.float(tonumber(cfg[key]) or vmin)
    imgui.PushItemWidth(sw)
    if imgui.SliderFloat('##ds_' .. key, f, vmin, vmax, u8(fmt)) then
        cfg[key] = math.floor(readFloatPtr(f) * mult + 0.5) / mult
        saveConfig()
    end
    imgui.PopItemWidth()
end

-- scale: во сколько раз значение слайдера больше значения в конфиге (для процентов: 100)
function HOME.sliderI(key, label, y, w, vmin, vmax, fmt, scale)
    scale = scale or 1
    imgui.SetCursorPos(V2(16, y + 4))
    imgui.TextColored(V4(0.78, 0.85, 0.95, 1.0), u8(label))
    local sw = 124
    imgui.SetCursorPos(V2(w - 16 - sw, y))
    local iv = imgui.new.int(math.floor((tonumber(cfg[key]) or (vmin / scale)) * scale + 0.5))
    imgui.PushItemWidth(sw)
    if imgui.SliderInt('##ds_' .. key, iv, vmin, vmax, u8(fmt)) then
        cfg[key] = readIntPtr(iv) / scale
        saveConfig()
    end
    imgui.PopItemWidth()
end

function HOME.chip(dl, x, y, w, h, dotCol, text)
    local ar, ag, ab = uiAccent()
    dl:AddRectFilled(V2(x, y), V2(x + w, y + h), U32(0.03, 0.07, 0.15, 0.78), h / 2)
    dl:AddRect(V2(x, y), V2(x + w, y + h), U32(ar, ag, ab, 0.45), h / 2)
    if dotCol then dl:AddCircleFilled(V2(x + 16, y + h / 2), 4.5, dotCol) end
    local lh = imgui.GetTextLineHeight()
    HOME.dtext(x + (dotCol and 28 or 14), y + (h - lh * 0.9) / 2, 0.9, V4(0.89, 0.93, 0.98, 1.0), text)
end

-- ---------- шапка главной вкладки ----------
function HOME.header()
    local wp = imgui.GetWindowPos()
    local dl = imgui.GetWindowDrawList()
    local lh = imgui.GetTextLineHeight()
    local ar, ag, ab = uiAccent()
    local cx, cy = wp.x + DX + 34, wp.y + 54

    for i = 3, 1, -1 do
        dl:AddCircle(V2(cx, cy), 29 + i * 2, U32(ar, ag, ab, 0.05 * (4 - i)), 32, 2.0)
    end
    dl:AddCircleFilled(V2(cx, cy), 29, U32(ar, ag, ab, 0.12))
    dl:AddCircle(V2(cx, cy), 29, U32(ar, ag, ab, 0.95), 32, 2.0)
    dl:AddLine(V2(cx - 13, cy), V2(cx + 13, cy), U32(1, 1, 1, 0.95), 5.0)
    dl:AddLine(V2(cx, cy - 13), V2(cx, cy + 13), U32(1, 1, 1, 0.95), 5.0)

    local tx = wp.x + DX + 84
    HOME.dtext(tx + 1.5, wp.y + 11.5, 2.4, V4(ar, ag, ab, 0.45), 'MHelper')
    HOME.dtext(tx, wp.y + 10, 2.4, V4(0.94, 0.98, 1.0, 1.0), 'MHelper')
    HOME.dtext(tx + 2, wp.y + 10 + lh * 2.4 + 1, 0.95, V4(0.80, 0.88, 0.98, 1.0), u8('Ваш помощник в SA-MP'))
    HOME.dtext(tx + 2, wp.y + 10 + lh * 2.4 + lh * 0.95 + 4, 0.85, V4(ar, ag, ab, 1.0), u8('Здоровье. Забота. РП.'))

    -- правая часть: онлайн, часы, кнопка закрытия, слоган
    local rx = wp.x + MAIN_W - DX
    if closeButton('##mh_close', MAIN_W - DX - 36, 18, 36) then
        isMenuOpen = false
    end
    local clockW, onlineW = 106, 142
    local cxp = rx - 36 - 10 - clockW
    HOME.chip(dl, cxp, wp.y + 22, clockW, 28, nil, os.date('%H:%M:%S'))
    local onTxt = cfg.onlineEnabled and (u8('Онлайн: ') .. tostring(#online.users)) or u8('Онлайн: выкл')
    HOME.chip(dl, cxp - 10 - onlineW, wp.y + 22, onlineW, 28, cfg.onlineEnabled and U32(0.13, 0.77, 0.37, 1.0) or U32(0.5, 0.55, 0.62, 1.0), onTxt)

    local slogan = u8('Профессиональная медицинская помощь')
    local sw = HOME.dwidth(1.0, slogan)
    local sx = rx - sw
    HOME.dtext(sx, wp.y + 68, 1.0, V4(0.88, 0.95, 1.0, 1.0), slogan)
    HOME.ecg(dl, sx - 96, wp.y + 60, 84, 32, U32(ar, ag, ab, 0.75), 1.6)
    dl:AddLine(V2(sx, wp.y + 68 + lh + 4), V2(rx, wp.y + 68 + lh + 4), U32(ar, ag, ab, 0.45), 1.5)
end

-- ---------- сама главная вкладка ----------
function HOME.draw()
    local lh = imgui.GetTextLineHeight()
    local o = imgui.GetWindowPos()
    local ar, ag, ab = uiAccent()
    local muted = V4(0.58, 0.68, 0.80, 1.0)
    local ky = HOME.kinds

    local H = profData[profSec(activeId) .. '_h'] or {}
    local D = profData[profSec(activeId) .. '_d'] or {}
    local today = tonumber(D['d' .. os.date('%Y%m%d')]) or 0
    local elapsed = os.clock() - sessionStart
    local rate = (elapsed >= 120 and sessionEarned > 0) and (sessionEarned / (elapsed / 3600)) or 0
    local totalEarned = stats.healEarned + stats.medCardEarned

    local hours = {}
    local nowH = tonumber(os.date('%H'))
    for i = 5, 0, -1 do
        local hh = nowH - i
        hours[#hours + 1] = (hh >= 0) and (tonumber(H['h' .. hh]) or 0) or 0
    end

    -- 1) карточки статистики
    local cw = math.floor((DW - 12 * 3) / 4)
    local sy = 4
    HOME.statCard(o, DX,               sy, cw, 84, 'heart',  'Лечение',   tostring(stats.healedCount),   'вылечено игроков', { 0.25, 0.60, 1.00 })
    HOME.statCard(o, DX + (cw + 12),   sy, cw, 84, 'dollar', 'Заработано', formatMoney(totalEarned) .. ' $', 'сегодня ' .. formatMoney(today) .. ' $', ky.money)
    HOME.statCard(o, DX + (cw + 12) * 2, sy, cw, 84, 'kit',  'Медкарты',  tostring(stats.medCardCount),  'выдано медкарт', { 0.25, 0.60, 1.00 })
    HOME.statCard(o, DX + (cw + 12) * 3, sy, cw, 84, 'clock', 'За сессию', formatMoney(sessionEarned) .. ' $', rate > 0 and (formatMoney(math.floor(rate)) .. ' $/ч') or 'считаем...', { 0.25, 0.60, 1.00 }, hours)

    -- 2) changelog / PRO panel
    local chY = sy + 84 + 10
    imgui.SetCursorPos(V2(DX, chY))
    imgui.BeginChild('mh_changelog_pro', V2(DW, 58), true)
    imgui.TextColored(V4(ar, ag, ab, 1.0), u8('MHelper 1.1 — обновления и подписка'))
    imgui.SameLine()
    imgui.TextColored(muted, u8('• авторизация • безопасность • сезоны'))
    imgui.TextColored(online.pro and V4(1.0,0.82,0.25,1.0) or muted, u8(online.pro and 'PRO: активен' or 'PRO: не активен'))
    imgui.SameLine()
    if imgui.SmallButton(u8('Купить PRO')) then openFunPay() end
    imgui.EndChild()

    -- 3) три панели
    local py, ph = chY + 58 + 10, 232
    local w1 = math.floor((DW - 24) / 3)
    local w3 = DW - (w1 + 12) * 2
    local x1, x2, x3 = DX, DX + w1 + 12, DX + (w1 + 12) * 2

    HOME.panelBegin('mh_h1', o, x1, py, w1, ph, 'Основные настройки', 'sliders')
    HOME.toggle('autoHealEnabled',  'Авто-лечение (/heal)',  'bolt',   48,  w1)
    HOME.toggle('autoBloodEnabled', 'Авто-приём крови',      'drop',   82,  w1)
    HOME.toggle('autoMedCardMenu',  'Меню медкарт',          'card',   116, w1)
    HOME.toggle('soundNotify',      'Звуковые уведомления',  'sound',  150, w1)
    HOME.toggle('strictRequests',   'Строгая проверка',      'shield', 184, w1)
    imgui.EndChild()

    HOME.panelBegin('mh_h2', o, x2, py, w1, ph, 'Параметры', 'sliders')
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V2(8, 4))
    HOME.sliderF('healDistance',   'Расстояние', 54,  w1, 1.0, 15.0, '%.1f м', 10)
    HOME.sliderI('healDelay',      'Задержка',   86,  w1, 500, 3000, '%d мс')
    HOME.sliderI('playerCooldown', 'Кулдаун',    118, w1, 1, 30, '%d сек')
    HOME.sliderI('soundVolume',    'Громкость',  150, w1, 0, 100, '%d%%', 100)
    imgui.PopStyleVar(1)
    imgui.SetCursorPos(V2(16, ph - 46))
    local lbl = (os.clock() < HOME.savedUntil) and 'Сохранено!' or 'Сохранить настройки'
    if imgui.Button(u8(lbl) .. '##dsave', V2(w1 - 32, 34)) then
        saveConfig()
        saveProfiles()
        HOME.savedUntil = os.clock() + 1.5
    end
    imgui.EndChild()

    HOME.panelBegin('mh_h3', o, x3, py, w3, ph, 'Активность', 'pulse')
    local cdl = imgui.GetWindowDrawList()
    local wp3 = imgui.GetWindowPos()
    local log = HOME.log
    if #log == 0 then
        imgui.SetCursorPos(V2(16, 56))
        imgui.PushTextWrapPos(w3 - 16)
        imgui.TextColored(muted, u8('Пока пусто. Здесь появятся запросы, лечения и выплаты.'))
        imgui.PopTextWrapPos()
    end
    for i = 1, math.min(#log, 5) do
        local e = log[i]
        local ry = 50 + (i - 1) * 27
        local col = ky[e.kind] or ky.req
        local cx, cy = wp3.x + 28, wp3.y + ry + 13
        local c32 = U32(col[1], col[2], col[3], 1.0)
        cdl:AddCircleFilled(V2(cx, cy), 10, U32(col[1], col[2], col[3], 0.18))
        if e.kind == 'money' then
            local dw = HOME.dwidth(0.95, '$')
            HOME.dtext(cx - dw / 2, cy - lh * 0.95 / 2, 0.95, V4(col[1], col[2], col[3], 1.0), '$')
        elseif e.kind == 'blood' then
            HOME.icon('drop', cdl, cx, cy, c32)
        elseif e.kind == 'card' then
            HOME.icon('card', cdl, cx, cy, c32)
        elseif e.kind == 'warn' then
            local dw = HOME.dwidth(0.95, '!')
            HOME.dtext(cx - dw / 2, cy - lh * 0.95 / 2, 0.95, V4(col[1], col[2], col[3], 1.0), '!')
        else
            cdl:AddLine(V2(cx - 5, cy), V2(cx + 5, cy), c32, 2.6)
            cdl:AddLine(V2(cx, cy - 5), V2(cx, cy + 5), c32, 2.6)
        end
        HOME.dtext(wp3.x + 46, wp3.y + ry + 13 - lh * 0.88 / 2, 0.88, V4(0.89, 0.91, 0.94, 1.0), cutUtf8(u8(e.text), 48))
        local ts = os.date('%H:%M', e.t)
        local tw = HOME.dwidth(0.8, ts)
        HOME.dtext(wp3.x + w3 - 16 - tw, wp3.y + ry + 13 - lh * 0.8 / 2, 0.8, muted, ts)
    end
    imgui.SetCursorPos(V2(16, ph - 42))
    imgui.PushStyleColor(imgui.Col.Button, V4(1, 1, 1, 0.06))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, V4(1, 1, 1, 0.14))
    imgui.PushStyleColor(imgui.Col.ButtonActive, V4(1, 1, 1, 0.20))
    if imgui.Button(u8('Очистить ленту') .. '##dclear', V2(w3 - 32, 30)) then
        for i = #HOME.log, 1, -1 do HOME.log[i] = nil end
    end
    imgui.PopStyleColor(3)
    imgui.EndChild()

    -- 3) профили и HUD
    local by, bh = py + ph + 12, 170
    local wProf = 468
    local wHud = DW - wProf - 12

    HOME.panelBegin('mh_h4', o, DX, by, wProf, bh, 'Профили игроков', 'user')
    local pdl = imgui.GetWindowDrawList()
    local pw = 80
    local shown = math.min(#profOrder, 4)
    for i = 1, shown do
        local id = profOrder[i]
        local p = getProf(id)
        local px0 = 16 + (i - 1) * (pw + 8)
        imgui.SetCursorPos(V2(px0, 54))
        local sp = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##hp' .. id, V2(pw, 104)) then switchProfile(id) end
        local hov = imgui.IsItemHovered()
        local act = (id == activeId)
        local pe = V2(sp.x + pw, sp.y + 104)
        pdl:AddRectFilled(sp, pe, act and U32(ar, ag, ab, 0.14) or U32(1, 1, 1, hov and 0.07 or 0.03), 12)
        pdl:AddRect(sp, pe, act and U32(ar, ag, ab, 0.85) or U32(1, 1, 1, 0.10), 12)
        drawAvatar(pdl, id, sp.x + pw / 2, sp.y + 34, 22, profLetter(p))
        local nm = cutUtf8(u8(tostring(p.name or '')), 16)
        local nw = HOME.dwidth(0.82, nm)
        HOME.dtext(sp.x + (pw - nw) / 2, sp.y + 70, 0.82, act and V4(1, 1, 1, 1) or V4(0.78, 0.85, 0.95, 1.0), nm)
        if act then
            pdl:AddCircleFilled(V2(sp.x + pw / 2 - 5, sp.y + 94), 2.5, U32(ar, ag, ab, 1.0))
            pdl:AddCircleFilled(V2(sp.x + pw / 2 + 5, sp.y + 94), 2.5, U32(ar, ag, ab, 0.45))
        end
    end
    if #profOrder < MAX_PROFILES and shown < 5 then
        local px0 = 16 + shown * (pw + 8)
        imgui.SetCursorPos(V2(px0, 54))
        local sp = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##hpnew', V2(pw, 104)) then createProfile() end
        local hov = imgui.IsItemHovered()
        local pe = V2(sp.x + pw, sp.y + 104)
        pdl:AddRectFilled(sp, pe, U32(1, 1, 1, hov and 0.07 or 0.03), 12)
        pdl:AddRect(sp, pe, U32(ar, ag, ab, hov and 0.7 or 0.35), 12)
        HOME.icon('plus', pdl, sp.x + pw / 2, sp.y + 34, U32(ar, ag, ab, 1.0))
        local t1, t2 = u8('Создать'), u8('профиль')
        HOME.dtext(sp.x + (pw - HOME.dwidth(0.8, t1)) / 2, sp.y + 66, 0.8, muted, t1)
        HOME.dtext(sp.x + (pw - HOME.dwidth(0.8, t2)) / 2, sp.y + 66 + lh * 0.8, 0.8, muted, t2)
    end
    imgui.EndChild()

    HOME.panelBegin('mh_h5', o, DX + wProf + 12, by, wHud, bh, 'HUD статистика', 'bars', 'hudVisible', 'Показать')
    local tx0 = 150
    HOME.miniToggle('hudShowCount',    'Лечение',         50,  wHud, tx0, 32)
    HOME.miniToggle('hudShowEarned',   'Заработок',       77,  wHud, tx0, 32)
    HOME.miniToggle('hudShowMcCount',  'Медкарты',        104, wHud, tx0, 32)
    HOME.miniToggle('hudShowMcEarned', 'Доход с медкарт', 131, wHud, tx0, 32)

    local cx0 = 196
    imgui.SetCursorPos(V2(cx0, 50))
    imgui.SetWindowFontScale(0.82)
    imgui.TextColored(muted, u8('Позиция (X, Y)'))
    imgui.SetWindowFontScale(1.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V2(8, 4))
    if not HOME.bufX then
        HOME.bufX = ffi.new('char[?]', 8)
        HOME.bufY = ffi.new('char[?]', 8)
    end
    imgui.PushItemWidth(60)
    imgui.SetCursorPos(V2(cx0, 70))
    if imgui.InputText('##hudx', HOME.bufX, 8, imgui.InputTextFlags.CharsDecimal) then
        cfg.hudPosX = tonumber(safeCStr(HOME.bufX)) or cfg.hudPosX
        HOME.hudDirty = true
        saveConfig()
    end
    if not imgui.IsItemActive() then ffi.copy(HOME.bufX, tostring(math.floor(cfg.hudPosX))) end
    imgui.SetCursorPos(V2(cx0 + 68, 70))
    if imgui.InputText('##hudy', HOME.bufY, 8, imgui.InputTextFlags.CharsDecimal) then
        cfg.hudPosY = tonumber(safeCStr(HOME.bufY)) or cfg.hudPosY
        HOME.hudDirty = true
        saveConfig()
    end
    if not imgui.IsItemActive() then ffi.copy(HOME.bufY, tostring(math.floor(cfg.hudPosY))) end
    imgui.PopItemWidth()
    imgui.SetCursorPos(V2(cx0, 104))
    imgui.SetWindowFontScale(0.82)
    imgui.TextColored(muted, u8('Прозрачность'))
    imgui.SetWindowFontScale(1.0)
    imgui.SetCursorPos(V2(cx0, 124))
    local iv = imgui.new.int(math.floor((tonumber(cfg.hudBgAlpha) or 0.65) * 100 + 0.5))
    imgui.PushItemWidth(wHud - cx0 - 16)
    if imgui.SliderInt('##hudalpha', iv, 20, 100, u8('%d%%')) then
        cfg.hudBgAlpha = readIntPtr(iv) / 100
        saveConfig()
    end
    imgui.PopItemWidth()
    imgui.PopStyleVar(1)
    imgui.EndChild()

    -- 4) нижняя плашка
    local fy, fh = by + bh + 12, 40
    local dl = imgui.GetWindowDrawList()
    local fx = o.x + DX
    HOME.neon(dl, fx, o.y + fy, DW, fh, 14)
    HOME.icon('info', dl, fx + 24, o.y + fy + fh / 2, U32(0.80, 0.88, 0.98, 1.0))
    HOME.dtext(fx + 42, o.y + fy + (fh - lh * 0.88) / 2, 0.88, V4(0.80, 0.88, 0.98, 1.0), 'MHelper v' .. SCRIPT_VER .. '  |  ' .. u8('Разработано для SA-MP'))
    local mid = u8('Будь здоров!')
    local mw = HOME.dwidth(1.15, mid)
    local mx = fx + DW / 2 - mw / 2
    HOME.dtext(mx, o.y + fy + (fh - lh * 1.15) / 2, 1.15, V4(ar, ag, ab, 1.0), mid)
    HOME.ecg(dl, mx - 130, o.y + fy + 8, 110, fh - 16, U32(ar, ag, ab, 0.75), 1.5)
    HOME.ecg(dl, mx + mw + 20, o.y + fy + 8, 110, fh - 16, U32(ar, ag, ab, 0.75), 1.5)
    local r1, r2 = 'SAN ANDREAS', 'MEDICAL DEPARTMENT'
    local rw = math.max(HOME.dwidth(0.72, r1), HOME.dwidth(0.72, r2))
    local rxx = fx + DW - 18 - rw
    HOME.icon('plus', dl, rxx - 18, o.y + fy + fh / 2, U32(ar, ag, ab, 1.0))
    HOME.dtext(rxx, o.y + fy + 6, 0.72, V4(0.89, 0.93, 0.98, 1.0), r1)
    HOME.dtext(rxx, o.y + fy + 6 + lh * 0.72, 0.72, V4(0.89, 0.93, 0.98, 1.0), r2)

    contentEnd(fy + fh)
end
end

local ROULETTE_SECTORS = { {h=1,label='1 ч'}, {h=1,label='1 ч'}, {h=6,label='6 ч'}, {h=6,label='6 ч'}, {h=24,label='1 дн'}, {h=24,label='1 дн'}, {h=72,label='3 дн'}, {h=168,label='7 дн'} }
local function drawTab10()
    local lh = imgui.GetTextLineHeight()
    local top = cardTopY(lh)
    local ar, ag, ab = uiAccent()
    local muted = V4(0.58, 0.64, 0.72, 1.0)
    local btnH = lh + 14
    if not online.auth then
        local h = math.floor(top + lh * 5 + btnH + 40)
        beginCard('mh_c40a', PAD, 4, FULL_W, h, 'Рулетка')
        imgui.Text(u8('Сначала войдите в аккаунт во вкладке Сообщество.'))
        endCard()
        contentEnd(4 + h)
        return
    end
    if not cfg.onlineEnabled then
        local h = math.floor(top + lh * 5 + btnH + 40)
        beginCard('mh_c40b', PAD, 4, FULL_W, h, 'Рулетка')
        imgui.Text(u8('Включите онлайн-режим во вкладке Сообщество.'))
        endCard()
        contentEnd(4 + h)
        return
    end
    local H = 484
    beginCard('mh_c40', PAD, 4, FULL_W, H, 'Рулетка — PRO от 1 часа до 7 дней')
    if online.roulette.spinning then
        local elapsed = os.clock() - (online.roulette.spinStart or 0)
        online.roulette.angle = (online.roulette.angle or 0) + imgui.GetIO().DeltaTime * 10
        if elapsed >= 3 then online.roulette.spinning = false end
    end
    local p = imgui.GetCursorScreenPos()
    local cx, cy, r = p.x + 110, p.y + 110, 100
    local dl = imgui.GetWindowDrawList()
    dl:AddCircle(V2(cx, cy), r, U32(ar, ag, ab, 1.0), 32, 2.0)
    for i = 0, 7 do local a = (online.roulette.angle or 0) + i * math.pi / 4 dl:AddLine(V2(cx, cy), V2(cx + math.cos(a) * r, cy + math.sin(a) * r), U32(1, 1, 1, 0.35), 1.5) end
    dl:AddCircleFilled(V2(cx, cy), 8, U32(ar, ag, ab, 1.0))
    imgui.Dummy(V2(220, 220))
    imgui.Text(u8('Призы: 1 ч, 1 ч, 6 ч, 6 ч, 1 день, 1 день, 3 дня, 7 дней'))
    if online.roulette.lastPrizeHours then imgui.TextColored(V4(1.0, 0.82, 0.25, 1.0), u8('Последний выигрыш: ' .. roulettePrizeLabel(online.roulette.lastPrizeHours))) end
    if online.roulette.canSpin then
        if imgui.Button(u8('Крутить'), V2(200, btnH + 6)) then spinRoulette() end
    else
        imgui.TextColored(muted, u8('Следующая попытка: ' .. ((online.roulette.nextSpinAt or 0) > 0 and os.date('%d.%m.%Y %H:%M', online.roulette.nextSpinAt) or 'через неделю')))
    end
    if online.roulette.statusMsg ~= '' then imgui.Text(u8(online.roulette.statusMsg)) end
    endCard()
    contentEnd(4 + H)
end
local function drawTab11()
    local lh = imgui.GetTextLineHeight()
    local top = cardTopY(lh)
    local ar, ag, ab = uiAccent()
    local muted = V4(0.58, 0.64, 0.72, 1.0)
    if not online.auth then
        local h = math.floor(top + lh * 5 + 40)
        beginCard('mh_c41a', PAD, 4, FULL_W, h, 'Сезоны')
        imgui.Text(u8('Сначала войдите в аккаунт во вкладке Сообщество.'))
        endCard()
        contentEnd(4 + h)
        return
    end
    if not cfg.onlineEnabled then
        local h = math.floor(top + lh * 5 + 40)
        beginCard('mh_c41b', PAD, 4, FULL_W, h, 'Сезоны')
        imgui.Text(u8('Включите онлайн-режим во вкладке Сообщество.'))
        endCard()
        contentEnd(4 + h)
        return
    end
    local H = 484
    beginCard('mh_c41', PAD, 4, FULL_W, H, 'Сезоны')
    local s = online.season.current
    if s then
        imgui.Text(u8('Сезон: ') .. tostring(s.name or ''))
        imgui.Text(u8('Начало: ') .. os.date('%d.%m.%Y', parseIso(s.starts_at)))
        imgui.Text(u8('Конец: ') .. os.date('%d.%m.%Y %H:%M', parseIso(s.ends_at)))
        imgui.Text(u8('Приз: ') .. tostring(s.prize or ''))
    else
        imgui.TextColored(muted, u8(online.season.busy and 'Загрузка...' or 'Активный сезон не найден.'))
    end
    local listH = H - top - lh * 3 - 20
    imgui.SetCursorPos(V2(CARD_PX, top + lh * 3 + 8))
    imgui.BeginChild('mh_season_top', V2(curCardW - CARD_PX * 2, listH), false)
    if #online.season.top == 0 then imgui.TextColored(muted, u8('Пока нет данных. Топ обновляется каждые 20 секунд.')) end
    for i, u in ipairs(online.season.top) do
        local mine = (u.uid == online.uid)
        imgui.TextColored(mine and V4(ar, ag, ab, 1.0) or V4(0.90, 0.92, 0.96, 1.0), tostring(i) .. '. ' .. tostring(u.nick or '?') .. ' — ' .. tostring(u.healed or 0) .. u8(' лечений, ') .. tostring(u.medcards or 0) .. u8(' медкарт') .. (mine and u8('  (вы)') or ''))
    end
    imgui.EndChild()
    endCard()
    contentEnd(4 + H)
end
local TAB_DRAW = { drawTab1, drawTab2, drawTab3, drawTab4, drawTab5, drawTab6, drawTab7, drawTab8 }
TAB_DRAW[9] = HOME.draw
TAB_DRAW[10] = drawTab10
TAB_DRAW[11] = drawTab11

-- ============================================================
--  САЙДБАР И ОСНОВНАЯ ОБЛАСТЬ
-- ============================================================
local function drawSidebar()
    local lh = imgui.GetTextLineHeight()
    local wp = imgui.GetWindowPos()
    local dl = imgui.GetWindowDrawList()
    local ar, ag, ab = uiAccent()
    local muted = V4(0.58, 0.64, 0.72, 1.0)
    local lx, ly = 18, 24

    -- логотип
    dl:AddRectFilled(V2(wp.x + lx - 3, wp.y + ly - 3), V2(wp.x + lx + 39, wp.y + ly + 39), U32(ar, ag, ab, 0.20), 13)
    dl:AddRectFilled(V2(wp.x + lx, wp.y + ly), V2(wp.x + lx + 36, wp.y + ly + 36), U32(ar, ag, ab, 1.0), 10)
    local mw = imgui.CalcTextSize('M').x
    imgui.SetCursorPos(V2(lx + (36 - mw) / 2, ly + (36 - lh) / 2))
    imgui.Text('M')

    local tx = lx + 36 + 12
    local th, sh = lh * 1.15, lh * 0.72
    local ty = ly + (36 - th - sh) / 2
    imgui.SetWindowFontScale(1.15)
    imgui.SetCursorPos(V2(tx, ty))
    imgui.Text('MHelper')
    imgui.SetWindowFontScale(0.72)
    imgui.SetCursorPos(V2(tx, ty + th))
    imgui.TextColored(muted, 'V' .. SCRIPT_VER .. ' PRO')
    imgui.SetWindowFontScale(1.0)

    dl:AddLine(V2(wp.x + lx, wp.y + 82), V2(wp.x + SIDE_W - lx, wp.y + 82), U32(1, 1, 1, 0.08), 1.0)

    -- навигация
    local navY, navW, navH = 100, SIDE_W - 28, math.floor(lh + 24)
    for _, i in ipairs(HOME.nav) do
        local t = TABS[i]
        imgui.SetCursorPos(V2(14, navY))
        local p = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##nav' .. i, V2(navW, navH)) then activeTab = i end
        local hov = imgui.IsItemHovered()
        local act = (activeTab == i)
        local pe = V2(p.x + navW, p.y + navH)
        local tr, tg, tb
        if act then
            dl:AddRectFilled(p, pe, U32(ar, ag, ab, 0.12), 12)
            dl:AddRect(p, pe, U32(ar, ag, ab, 0.28), 12)
            dl:AddRectFilled(V2(p.x, p.y + 9), V2(p.x + 3, p.y + navH - 9), U32(ar, ag, ab, 1.0), 2)
            tr, tg, tb = ar, ag, ab
        elseif hov then
            dl:AddRectFilled(p, pe, U32(1, 1, 1, 0.04), 12)
            tr, tg, tb = 0.89, 0.91, 0.94
        else
            tr, tg, tb = 0.58, 0.64, 0.72
        end
        drawIcon(i, dl, p.x + 26, p.y + navH / 2, U32(tr, tg, tb, act and 1.0 or 0.85))
        imgui.SetCursorScreenPos(V2(p.x + 46, p.y + (navH - lh) / 2))
        imgui.TextColored(V4(tr, tg, tb, 1.0), u8(t.title))
        if i == 7 and cfg.onlineEnabled and totalUnread() > 0 then
            dl:AddCircleFilled(V2(p.x + navW - 20, p.y + navH / 2), 6, U32(0.94, 0.27, 0.27, 1.0))
        end
        navY = navY + navH + 6
    end

    -- логотип
    local py = WIN_H - 70
    dl:AddLine(V2(wp.x + lx, wp.y + py), V2(wp.x + SIDE_W - lx, wp.y + py), U32(1, 1, 1, 0.08), 1.0)
    local nick = getMyNick()
    local cx, cy = wp.x + lx + 16, wp.y + py + 35
    local curProf = getProf(activeId)
    drawAvatar(dl, activeId, cx, cy, 16, profLetter(curProf))
    imgui.SetCursorScreenPos(V2(cx + 28, cy - lh * 0.95))
    imgui.Text(nick)
    imgui.SetWindowFontScale(0.75)
    imgui.SetCursorScreenPos(V2(cx + 28, cy + 1))
    imgui.TextColored(muted, u8(tostring(curProf.name or 'Медик')))
    imgui.SetWindowFontScale(1.0)
end

local function drawMain()
    local lh = imgui.GetTextLineHeight()
    local tab = TABS[activeTab]
    local headH = HEAD_H

    if activeTab == 9 then
        HOME.header()
        headH = HOME.head
    else
        imgui.SetWindowFontScale(1.45)
        imgui.SetCursorPos(V2(PAD, 24))
        imgui.Text(u8(tab.title))
        imgui.SetWindowFontScale(0.88)
        imgui.SetCursorPos(V2(PAD, 24 + lh * 1.45 + 3))
        imgui.TextColored(V4(0.58, 0.64, 0.72, 1.0), u8(tab.sub))
        imgui.SetWindowFontScale(1.0)

        if closeButton('##mh_close', MAIN_W - PAD - 36, 26, 36) then
            isMenuOpen = false
        end
    end

    imgui.SetCursorPos(V2(0, headH))
    imgui.BeginChild('mh_content', V2(MAIN_W - 4, WIN_H - headH - 12), false, 0)
    TAB_DRAW[activeTab]()
    imgui.EndChild()
end

-- ============================================================
--  ЧАТ / ДИАЛОГИ (логика без изменений)
-- ============================================================
function sampev.onServerMessage(color, text)
    local cleanText = text:gsub('{.-}', '')
    local lowerFull = rusLower(cleanText)

    if lowerFull:find('у вас нет медикаментов', 1, true) then
        pendingMedCardPrice = 0
        noMedsBannerUntil = os.clock() + 5.0
        HOME.push('warn', 'Нет медикаментов')
        playAlertSound('nomeds')
        return
    end

    if not lowerFull:find('говорит:') and not lowerFull:find('%]:') then
        -- 1. Успешное лечение (100% суммы без комиссии)
        if lowerFull:find('вы вылечили', 1, true) or lowerFull:find('принял ваше предложение о лечении', 1, true)
        or lowerFull:find('приняла ваше предложение о лечении', 1, true) then
            stats.healedCount = stats.healedCount + 1
            local fullSum = extractCleanMoney(cleanText) or getCurrentHealPrice()
            stats.healEarned = stats.healEarned + fullSum
            recordIncome(fullSum)
            HOME.push('heal', 'Игрок вылечен')
            HOME.push('money', 'Получено: ' .. HOME.groupDigits(fullSum) .. ' $')
            saveProfiles()
            return
        end

        -- 2. Успешная оплата медкарты
        if (lowerFull:find('вы выдали', 1, true) and lowerFull:find('мед. карта', 1, true))
        or lowerFull:find('выдали медицинскую карту', 1, true)
        or lowerFull:find('принял ваше предложение о покупке мед', 1, true)
        or lowerFull:find('приняла ваше предложение о покупке мед', 1, true) then
            stats.medCardCount = stats.medCardCount + 1
            local mcBefore = stats.medCardEarned
            local daysMatched = lowerFull:match('сроком на%s*(%d+)')
            local priceByDays = getMedCardPriceByDays(daysMatched)
            if pendingMedCardPrice > 0 and (os.clock() - lastMedCardOfferTime) <= 65 then
                stats.medCardEarned = stats.medCardEarned + math.floor(pendingMedCardPrice * 0.5)
            elseif priceByDays then
                stats.medCardEarned = stats.medCardEarned + math.floor(priceByDays * 0.5)
            end
            pendingMedCardPrice = 0
            recordIncome(stats.medCardEarned - mcBefore)
            HOME.push('card', 'Медкарта оформлена')
            if stats.medCardEarned - mcBefore > 0 then
                HOME.push('money', 'Получено: ' .. HOME.groupDigits(stats.medCardEarned - mcBefore) .. ' $')
            end
            saveProfiles()
            return
        end
    end

    if cleanText:find('^%[R%]') or cleanText:find('^%[F%]') or cleanText:find('^%[VR%]')
    or cleanText:find('^%(%(') or cleanText:find('^%s*%*') then
        return
    end

    local senderId, msgBody = cleanText:match('%[(%d+)%]%sговорит:%s(.+)')
    if not senderId then
        senderId, msgBody = cleanText:match('%[(%d+)%]:%s*(.+)')
    end
    if not senderId or not msgBody then return end

    senderId = tonumber(senderId)
    local _, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if senderId == myId then return end

    if asBool(cfg.interiorOnly) and getActiveInterior() == 0 then return end

    local res, targetPed = sampGetCharHandleBySampPlayerId(senderId)
    if not res or not doesCharExist(targetPed) then return end

    local mx, my, mz = getCharCoordinates(PLAYER_PED)
    local tx, ty, tz = getCharCoordinates(targetPed)
    if getDistanceBetweenCoords3d(mx, my, mz, tx, ty, tz) > cfg.healDistance then return end

    local now = os.clock()

    if asBool(cfg.autoBloodEnabled) and matchListTrigger(msgBody, cfg.bloodTriggers) then
        if not bloodCooldowns[senderId] or (now - bloodCooldowns[senderId]) >= cfg.playerCooldown then
            bloodCooldowns[senderId] = now
            HOME.push('blood', 'Игрок запросил кровь')
            lua_thread.create(function()
                wait(cfg.healDelay)
                if not sampIsPlayerConnected(senderId) then return end
                if asBool(cfg.useRpAction) and #trim(tostring(cfg.rpBloodAction)) > 0 then
                    sampSendChat(rpText(cfg.rpBloodAction, senderId))
                    wait(800)
                end
                sampSendChat(string.format('/takeblood %d', senderId))
            end)
        end
        return
    end

    if asBool(cfg.autoMedCardMenu) and matchListTrigger(msgBody, cfg.medCardTriggers) then
        if not isMedCardOpen or medCardTargetId ~= senderId then
            medCardTargetId = senderId
            isMedCardOpen = true
            HOME.push('req', 'Игрок запросил медкарту')
            playAlertSound('medcard')
        end
        return
    end

    if asBool(cfg.autoHealEnabled) and matchListTrigger(msgBody, cfg.triggers) then
        if healCooldowns[senderId] and (now - healCooldowns[senderId]) < cfg.playerCooldown then
            return
        end
        healCooldowns[senderId] = now
        HOME.push('req', 'Игрок запросил лечение')
        lua_thread.create(function()
            wait(cfg.healDelay)
            if not sampIsPlayerConnected(senderId) then return end
            if asBool(cfg.useRpAction) and #trim(tostring(cfg.rpAction)) > 0 then
                sampSendChat(rpText(cfg.rpAction, senderId))
                wait(800)
            end
            sampSendChat(string.format('/heal %d %d', senderId, getCurrentHealPrice()))
        end)
    end
end

-- Строгая проверка окон (не затрагивает /report и другие серверные диалоги)
function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    local cleanTitle = rusLower((title or ''):gsub('{.-}', ''))
    local cleanText = rusLower((text or ''):gsub('{.-}', ''))

    if cleanTitle:find('лечение', 1, true) or cleanText:find('желаемую стоимость лечения', 1, true) or cleanText:find('стоимость лечения', 1, true) then
        sampSendDialogResponse(dialogId, 1, 0, tostring(getCurrentHealPrice()))
        return false
    end

    if cleanTitle:find('подтверждение выдачи медкарты', 1, true) or cleanText:find('подтвердите данные перед выдачей мед', 1, true) then
        sampSendDialogResponse(dialogId, 1, 0, '')
        return false
    end
end

-- ============================================================
--  ОКНА ИМГУИ
-- ============================================================

-- Плашка "нет медикаментов"
imgui.OnFrame(function() return os.clock() < noMedsBannerUntil end, function()
    applyCustomStyle()
    imgui.GetIO().FontGlobalScale = cfg.fontScale
    if loadedFonts[cfg.fontIndex + 1] then
        imgui.PushFont(loadedFonts[cfg.fontIndex + 1])
    end

    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw - 18, sh * 0.5), imgui.Cond.Always, imgui.ImVec2(1.0, 0.5))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.075, 0.082, 0.102, 0.92))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.94, 0.27, 0.27, 0.90))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.2)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 12))

    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoMove
    if imgui.Begin('MHelperNoMedsToast', nil, flags) then
        imgui.TextColored(imgui.ImVec4(0.94, 0.27, 0.27, 1.0), u8('Нет медикаментов!'))
        imgui.SetWindowFontScale(0.85)
        imgui.TextColored(imgui.ImVec4(0.58, 0.64, 0.72, 1.0), u8('Пополните склад в больнице'))
        imgui.SetWindowFontScale(1.0)
    end
    imgui.End()
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(2)

    if loadedFonts[cfg.fontIndex + 1] then
        imgui.PopFont()
    end
end).HideCursor = true

-- HUD статистики (двигается мышью, пока открыто меню)
imgui.OnFrame(function() return cfg.hudVisible end, function()
    applyCustomStyle()
    imgui.GetIO().FontGlobalScale = cfg.fontScale
    if loadedFonts[cfg.fontIndex + 1] then
        imgui.PushFont(loadedFonts[cfg.fontIndex + 1])
    end

    local ar, ag, ab = uiAccent()
    local hudCond = HOME.hudDirty and imgui.Cond.Always or imgui.Cond.FirstUseEver
    HOME.hudDirty = false
    imgui.SetNextWindowPos(imgui.ImVec2(cfg.hudPosX, cfg.hudPosY), hudCond)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.075, 0.082, 0.102, cfg.hudBgAlpha))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(ar, ag, ab, 0.45))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 12))

    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoScrollbar
                + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoSavedSettings
    if not isMenuOpen then flags = flags + imgui.WindowFlags.NoInputs end

    if imgui.Begin('MHelperHUD', nil, flags) then
        local lines = {}
        if cfg.hudShowCount    then table.insert(lines, { 'Вылечено:',         tostring(stats.healedCount) }) end
        if cfg.hudShowEarned   then table.insert(lines, { 'Доход (лечение):',  formatMoney(stats.healEarned) .. ' $' }) end
        if cfg.hudShowMcCount  then table.insert(lines, { 'Медкарт выдано:',   tostring(stats.medCardCount) }) end
        if cfg.hudShowMcEarned then table.insert(lines, { 'Доход (медкарты):', formatMoney(stats.medCardEarned) .. ' $' }) end

        imgui.TextColored(imgui.ImVec4(ar, ag, ab, 1.0), 'MHelper')
        local maxW = 0
        for _, l in ipairs(lines) do
            maxW = math.max(maxW, imgui.CalcTextSize(u8(l[1])).x)
        end
        for _, l in ipairs(lines) do
            imgui.TextColored(imgui.ImVec4(0.58, 0.64, 0.72, 1.0), u8(l[1]))
            imgui.SameLine(16 + maxW + 14)
            imgui.Text(u8(l[2]))
        end

        if isMenuOpen and imgui.IsMouseReleased(0) then
            local pos = imgui.GetWindowPos()
            if math.abs(pos.x - cfg.hudPosX) > 0.5 or math.abs(pos.y - cfg.hudPosY) > 0.5 then
                cfg.hudPosX, cfg.hudPosY = pos.x, pos.y
                saveConfig()
            end
        end
    end
    imgui.End()
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(2)

    if loadedFonts[cfg.fontIndex + 1] then
        imgui.PopFont()
    end
end).HideCursor = true

-- Быстрое меню выдачи медкарты (/mc [id])
local MC_OPTIONS = {
    { idx = 0, label = 'На 7 дней (неделя)', key = 'priceMedCard7SA'  },
    { idx = 1, label = 'На 14 дней',          key = 'priceMedCard14'   },
    { idx = 2, label = 'На 30 дней',          key = 'priceMedCard30SA' },
    { idx = 3, label = 'На 60 дней',          key = 'priceMedCard60'   }
}

imgui.OnFrame(function() return isMedCardOpen end, function()
    applyCustomStyle()
    imgui.GetIO().FontGlobalScale = cfg.fontScale
    if loadedFonts[cfg.fontIndex + 1] then
        imgui.PushFont(loadedFonts[cfg.fontIndex + 1])
    end

    local sw, sh = getScreenResolution()
    local lh = imgui.GetTextLineHeight()
    local W = 380
    local padX, padY = 20, 16
    local rowH = math.floor(lh + 26)
    local H = math.floor(padY + lh * 1.95 + 22 + 4 * rowH + 3 * 8 + padY + 4)
    local inner = W - padX * 2
    local ar, ag, ab = uiAccent()

    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(padX, padY))
    local winFlags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar
    local opened = imgui.Begin('MedCardQuick', nil, winFlags)
    imgui.PopStyleVar()
    if opened then
        local dl = imgui.GetWindowDrawList()
        local targetNick = sampIsPlayerConnected(medCardTargetId) and sampGetPlayerNickname(medCardTargetId) or u8:decode('Игрок')

        imgui.SetWindowFontScale(0.8)
        imgui.SetCursorPos(V2(padX, padY))
        imgui.TextColored(V4(ar, ag, ab, 1.0), u8('ВЫДАЧА МЕДКАРТЫ'))
        imgui.SetWindowFontScale(1.1)
        imgui.SetCursorPos(V2(padX, padY + lh * 0.8 + 2))
        imgui.Text(u8(string.format('%s [%d]', targetNick, medCardTargetId)))
        imgui.SetWindowFontScale(1.0)

        if closeButton('##mc_close', W - padX - 30, padY, 30) then
            isMedCardOpen = false
        end

        local y = padY + lh * 1.95 + 22
        for i, opt in ipairs(MC_OPTIONS) do
            imgui.SetCursorPos(V2(padX, y))
            local p = imgui.GetCursorScreenPos()
            local clicked = imgui.InvisibleButton('##mcopt' .. i, V2(inner, rowH))
            local hov = imgui.IsItemHovered()
            local pe = V2(p.x + inner, p.y + rowH)
            dl:AddRectFilled(p, pe, hov and U32(ar, ag, ab, 0.18) or U32(1, 1, 1, 0.04), 10)
            dl:AddRect(p, pe, hov and U32(ar, ag, ab, 0.55) or U32(1, 1, 1, 0.08), 10)

            local price = tonumber(cfg[opt.key]) or 0
            local priceStr = u8(formatMoney(price) .. ' $')
            local pw = imgui.CalcTextSize(priceStr).x
            imgui.SetCursorScreenPos(V2(p.x + 14, p.y + (rowH - lh) / 2))
            imgui.Text(u8(opt.label))
            imgui.SetCursorScreenPos(V2(p.x + inner - 14 - pw, p.y + (rowH - lh) / 2))
            imgui.TextColored(V4(ar, ag, ab, 1.0), priceStr)

            if clicked then issueMedCard(opt.idx, price) end
            y = y + rowH + 8
        end
    end
    imgui.End()

    if loadedFonts[cfg.fontIndex + 1] then
        imgui.PopFont()
    end
end)

-- Главное меню (/mhelper)
local menuWantsText = false
local mainFrame = imgui.OnFrame(function() return isMenuOpen end, function()
    applyCustomStyle()
    imgui.GetIO().FontGlobalScale = cfg.fontScale
    menuWantsText = imgui.GetIO().WantTextInput
    local font = loadedFonts[cfg.fontIndex + 1]
    if font then imgui.PushFont(font) end

    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(WIN_W, WIN_H), imgui.Cond.Always)

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    local winFlags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    local opened = imgui.Begin('MHelper', nil, winFlags)
    imgui.PopStyleVar()

    if opened then
        local wp = imgui.GetWindowPos()
        local dl = imgui.GetWindowDrawList()

        -- фон сайдбара (скруглены только левые углы)
        local gar, gag, gab = uiAccent()
        local bg = HOME.bg()
        if bg then
            pcall(dl.AddImageRounded, dl, bg, wp, V2(wp.x + WIN_W, wp.y + WIN_H), V2(0, 0), V2(1, 1), U32(1, 1, 1, 0.42), 14)
            dl:AddRectFilled(wp, V2(wp.x + WIN_W, wp.y + WIN_H), U32(0.01, 0.03, 0.08, 0.50), 14)
        end
        for gi = 1, 3 do
            dl:AddRect(V2(wp.x + gi, wp.y + gi), V2(wp.x + WIN_W - gi, wp.y + WIN_H - gi), U32(gar, gag, gab, 0.34 - gi * 0.09), 14)
        end
        local sideCol = U32(0.015, 0.030, 0.075, cfg.menuBgAlpha * 0.9)
        dl:AddRectFilled(wp, V2(wp.x + SIDE_W, wp.y + WIN_H), sideCol, 14)
        dl:AddRectFilled(V2(wp.x + 14, wp.y), V2(wp.x + SIDE_W, wp.y + WIN_H), sideCol, 0)
        dl:AddLine(V2(wp.x + SIDE_W, wp.y + 1), V2(wp.x + SIDE_W, wp.y + WIN_H - 1), U32(1, 1, 1, 0.08), 1.0)

        imgui.SetCursorPos(V2(0, 0))
        imgui.BeginChild('mh_side', V2(SIDE_W, WIN_H), false, noScroll())
        drawSidebar()
        imgui.EndChild()

        imgui.SetCursorPos(V2(SIDE_W, 0))
        imgui.BeginChild('mh_main', V2(MAIN_W, WIN_H), false, noScroll())
        drawMain()
        imgui.EndChild()
    end
    imgui.End()

    if font then imgui.PopFont() end
end)
mainFrame.LockPlayer = true

-- ============================================================
--  MAIN
-- ============================================================
function main()
    while not isSampAvailable() do wait(100) end
    restoreAuthSession()
    if tostring(cfg.savedAuthEmail or '') ~= '' then pcall(ffi.copy, authEmailBuf, cfg.savedAuthEmail, #cfg.savedAuthEmail) end

    sampRegisterChatCommand('mhelper', function()
        isMenuOpen = not isMenuOpen
    end)

    sampRegisterChatCommand('mhud', function()
        cfg.hudVisible = not cfg.hudVisible
    end)

    sampRegisterChatCommand('mc', function(arg)
        local id = tonumber(arg)
        if not id then
            sampAddChatMessage('[MHelper] {FFFFFF}Использование: /mc [id]', 0x3B82F6)
            return
        end
        if not sampIsPlayerConnected(id) then
            sampAddChatMessage('[MHelper] {FFFFFF}Игрок с таким ID не найден.', 0xFF5555)
            return
        end
        medCardTargetId = id
        isMedCardOpen = true
    end)

    sampRegisterChatCommand('mprof', function(arg)
        local n = tonumber(arg)
        if n and profOrder[n] then
            switchProfile(profOrder[n])
            sampAddChatMessage('[MHelper] {FFFFFF}Профиль: {3B82F6}' .. tostring(getProf(activeId).name), 0x3B82F6)
        else
            for i, id in ipairs(profOrder) do
                sampAddChatMessage(string.format('[MHelper] {FFFFFF}%d. %s%s', i, tostring(getProf(id).name), id == activeId and ' {3B82F6}(активен)' or ''), 0x3B82F6)
            end
            sampAddChatMessage('[MHelper] {FFFFFF}Сменить: {3B82F6}/mprof [номер]', 0x3B82F6)
        end
    end)

    sampRegisterChatCommand('mg', function(arg)
        if not cfg.onlineEnabled then
            sampAddChatMessage('[MHelper] {FFFFFF}Онлайн-режим выключен. Включить: {3B82F6}/mhelper{FFFFFF} - Сообщество', 0x3B82F6)
            return
        end
        local t = trim(arg or '')
        if t == '' then
            sampAddChatMessage('[MHelper] {FFFFFF}Сообщение в общий чат: {3B82F6}/mg [текст]', 0x3B82F6)
            return
        end
        sendMessage(u8(t), 'all')
    end)

    sampRegisterChatCommand('mstop', function()
        if stopAlertSound() then
            sampAddChatMessage('[MHelper] {FFFFFF}Мелодия остановлена.', 0x3B82F6)
        else
            sampAddChatMessage('[MHelper] {FFFFFF}Сейчас ничего не играет.', 0x3B82F6)
        end
    end)

    sampRegisterChatCommand('mstats', function()
        sampAddChatMessage('[MHelper] {FFFFFF}Профиль: {3B82F6}' .. tostring(getProf(activeId).name), 0x3B82F6)
        sampAddChatMessage(string.format('[MHelper] {FFFFFF}Вылечено: {3B82F6}%d{FFFFFF} (%s $), медкарт: {3B82F6}%d{FFFFFF} (%s $)',
            stats.healedCount, formatMoney(stats.healEarned), stats.medCardCount, formatMoney(stats.medCardEarned)), 0x3B82F6)
        sampAddChatMessage(string.format('[MHelper] {FFFFFF}Итого: {3B82F6}%s $', formatMoney(stats.healEarned + stats.medCardEarned)), 0x3B82F6)
    end)

    sampAddChatMessage('[MHelper] {FFFFFF}v' .. SCRIPT_VER .. ' загружен. Меню: {3B82F6}/mhelper{FFFFFF}, медкарта: {3B82F6}/mc [id]{FFFFFF}, итоги: {3B82F6}/mstats', 0x3B82F6)

    local nickChecked = false
    while true do
        wait(0)
        local okT, errT = pcall(online.tick)
        if not okT then online.status = 'Error: ' .. tostring(errT):sub(1, 100); online.statusOk = false end
        if not nickChecked and sampIsLocalPlayerSpawned() then
            nickChecked = true
            local myNick = getMyNick()
            local okS, myServer = pcall(sampGetCurrentServerName)
            myServer = okS and tostring(myServer) or ''
            local found
            for _, id in ipairs(profOrder) do
                local p = getProf(id)
                if tostring(p.nick or '') == myNick and (tostring(p.server or '') == '' or tostring(p.server) == myServer) then
                    found = id
                    break
                end
            end
            if found then
                local p = getProf(found)
                if tostring(p.server or '') == '' then p.server = myServer; saveProfiles() end
                if found ~= activeId then
                    switchProfile(found)
                    sampAddChatMessage('[MHelper] {FFFFFF}Выбран профиль: {3B82F6}' .. tostring(p.name) .. '{FFFFFF} (' .. myNick .. ')', 0x3B82F6)
                end
            else
                local p = getProf(activeId)
                if tostring(p.nick or '') == '' then
                    p.nick, p.server = myNick, myServer
                    saveProfiles()
                    sampAddChatMessage('[MHelper] {FFFFFF}Профиль {3B82F6}' .. tostring(p.name) .. '{FFFFFF} привязан: ' .. myNick .. ' | ' .. myServer, 0x3B82F6)
                end
            end
        end
        if alertStream then
            if wasKeyPressed(cfg.soundStopKey) and not sampIsChatInputActive() and not sampIsDialogActive() then
                stopAlertSound()
                sampAddChatMessage('[MHelper] {FFFFFF}Мелодия остановлена.', 0x3B82F6)
            elseif getAudioStreamState(alertStream) == 0 then
                stopAlertSound() -- доиграла до конца
            end
        end
        if isMenuOpen and not menuWantsText and wasKeyPressed(vkeys.VK_RETURN) then
            isMenuOpen = false
        end
    end
end
