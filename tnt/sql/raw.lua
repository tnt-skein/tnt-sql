--- Текст руками: `sql.raw('lower(?) = ?', name, other)`.
---
--- Текст пишет программист, а значения и тут уходят параметрами: знак
--- в тексте — `?` на любом диалекте, а `build` ставит вместо него знак
--- диалекта (`$1` у PostgreSQL) с приведением там, где оно нужно. Два
--- правила текста драйвер сам не проверяет, и рок тоже, — их проверяет
--- здесь разбор текста:
---
--- - **число знаков равно числу значений.** Рок не сверяет: у `pg` лишнее
---   значение молча пропадает, у `mysql` недостающее берётся со стека рока;
--- - **один оператор на вызов.** `;` вне кавычек и комментариев — отказ:
---   `mysql` теряет отказ второго оператора и фиксирует первый.
---
--- Знак внутри литерала `'…'`, имени в кавычках `"…"` и `` `…` ``,
--- комментария до конца строки и блочного комментария знаком не считается
--- (пары их открытия и закрытия здесь словами: генератор мутантов принял бы
--- их за комментарий C и ослеп до конца файла). `??` — сам знак
--- вопроса: одиночный `?` занят под параметр, а так пишется оператор `?`
--- у `jsonb` PostgreSQL.
--- Кавычка в литерале удваивается (`'it''s'`): обратную черту как знак
--- экранирования читает только MySQL, и разбор её не знает.
---
--- Фрагмент годится и целым запросом (`build`), и куском другого:
--- столбцом, условием, значением, порядком.

local fail = require('tnt.must.fail')

local context = require('tnt.sql.context')
local kinds = require('tnt.sql.kinds')

local Module = {}

---@class TntSqlRaw
---@field pieces string[] Куски текста между знаками
---@field params table Значения с полем `n`
local Raw = kinds.RAW
Raw.__index = Raw

--- Простой текст до первого особого знака, сам знак и всё, что за ним.
--- Особые — знак `?`, `;`, кавычки и начала комментариев; знака нет —
--- пустая строка.
local NEXT = '^([^%?;\'"`%-/]*)(.?)(.*)$'

--- Как начинается то, что за минусом и косой чертой идёт текстом:
--- без второго знака это просто минус и деление.
---@type table<string, string>
local OPENS = { ['-'] = '^%-', ['/'] = '^%*' }

--- Что за особым знаком идёт текстом, до конца включительно: литерал,
--- имя в кавычках, комментарий. Удвоенная кавычка (`'it''s'`) разбирается
--- как два литерала подряд — для подсчёта знаков это одно и то же.
---@type table<string, string>
local CLOSES = {
    ["'"] = "^(.-')(.*)$",
    ['"'] = '^(.-")(.*)$',
    ['`'] = '^(.-`)(.*)$',
    ['-'] = '^(%-[^\n]*)(.*)$',
    -- Пара закрытия блочного комментария склеена из двух строк: целиком
    -- её генератор мутантов принял бы за конец комментария C.
    ['/'] = '^(%*.-%*' .. '/)(.*)$',
}

--- Что сказать, если конца нет.
---@type table<string, string>
local UNCLOSED = {
    ["'"] = "кавычка ' не закрыта",
    ['"'] = 'кавычка " не закрыта',
    ['`'] = 'кавычка ` не закрыта',
    ['/'] = 'комментарий /' .. '* не закрыт',
}

--- Текст за особым знаком и остаток после него либо отказ.
---@param char string Особый знак
---@param tail string Всё, что за ним
---@return string|nil kept Что идёт текстом
---@return string rest Остаток либо текст отказа
local function enclosed(char, tail)
    if OPENS[char] ~= nil and not tail:find(OPENS[char]) then
        return '', tail
    end

    local kept, rest = tail:match(CLOSES[char])

    if kept == nil then
        return nil, UNCLOSED[char]
    end

    -- Два захвата образца совпадают вместе: есть текст — есть и остаток.
    return kept, rest --[[@as string]]
end

--- Куски текста между знаками либо отказ.
---
--- Текст съедается с головы: кусок за куском, без счёта позиций.
---@param text string
---@return string[]|nil pieces
---@return string|nil complaint
local function split(text)
    local pieces = {}
    local piece = ''
    local rest = text

    while true do
        -- Образец совпадает всегда: и простой текст, и знак могут быть пусты.
        local plain, char, tail = rest:match(NEXT)
        ---@cast plain string
        ---@cast char string
        ---@cast tail string

        piece = piece .. plain
        rest = tail

        if char == '' then
            break
        end

        if char == '?' and tail:find('^%?') then
            -- `??` — сам знак вопроса: кусок не кончается.
            piece = piece .. '?'
            rest = tail:sub(2)
        elseif char == '?' then
            table.insert(pieces, piece)
            piece = ''
        elseif char == ';' then
            return nil, 'один оператор на вызов, а в тексте «;» вне кавычек'
        else
            local kept, after = enclosed(char, tail)

            if kept == nil then
                return nil, after
            end

            piece = piece .. char .. kept
            rest = after
        end
    end

    table.insert(pieces, piece)

    return pieces
end

--- Текст руками со значениями.
---@param text string Текст со знаками `?`
---@param ... any Значения по порядку знаков; `nil` посреди — NULL
---@return TntSqlRaw
function Module.new(text, ...)
    if type(text) ~= 'string' then
        error(fail.text('sql.raw: текст', 'строка', fail.show(text)), 2)
    end

    local pieces, complaint = split(text)

    if pieces == nil then
        error('sql.raw: ' .. complaint, 2)
    end

    local count = select('#', ...)

    if #pieces - 1 ~= count then
        error(('sql.raw: знаков ? в тексте %d, а значений %d'):format(#pieces - 1, count), 2)
    end

    return setmetatable({ pieces = pieces, params = { n = count, ... } }, Raw)
end

--- Фрагмент целиком — как в тексте, со своими значениями.
---@param raw TntSqlRaw
---@param into TntSqlContext
---@return string
local function render(into, raw)
    return into:fragment(raw)
end

--- Текст и параметры под диалект.
---@param dialect any Имя диалекта либо таблица диалекта драйвера
---@return string|nil text
---@return table|TntStorageFailure params Параметры с полем `n` либо отказ данных
function Raw:build(dialect)
    local text, params = context.run(self, dialect, render, {})

    return text, params
end

return Module
