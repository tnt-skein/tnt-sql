--- Сборка: знаки параметров, имена в кавычках и белый список.
---
--- Здесь единственное место, где значение становится знаком параметра,
--- а имя — текстом. Значение в текст не попадает никогда: оно уходит
--- в `params` таким, каким его передаст рок (`tnt-storage`, `value.wire`),
--- а в тексте остаётся знак — `$n` у PostgreSQL, `?` у прочих. Приведение
--- `$n::тип` у PostgreSQL называет `value.wire`, и ставится оно двум родам
--- значений. Значениям не числом и не логикой: рок шлёт их типом `text`,
--- в столбец `int8`, `numeric` либо `jsonb` сервер их сам не приводит
--- и отказывает «expression is of type text». И целым — `int8`: число рок
--- шлёт типом `numeric`, и сравнение с целым столбцом идёт мимо индекса.
---
--- Имя столбца проходит белый список: оно обязано быть объявлено у одной
--- из таблиц запроса (`sql.table`). Имя без таблицы, объявленное у двух
--- таблиц, — неоднозначность, её пакет не угадывает.
---
--- Отказ данных (строка с нулевым байтом у PostgreSQL) прерывает сборку
--- и уходит парой `nil, err`. Прочие отказы сборки — ошибки программиста:
--- они бросаются без места (`fail.raise` из `tnt-must`: уровни 0 и -1
--- в Lua неотличимы, и своя копия броска потребовала бы своего исключения
--- мутационного гейта), а место — строку того, кто позвал `build`, —
--- приписывает `run`. Место внутри сборки человеку ничего не скажет:
--- чинить надо строку, где запрос собрали.

local fail = require('tnt.must.fail')
local value = require('tnt.storage.value')

local dialects = require('tnt.sql.dialect')
local kinds = require('tnt.sql.kinds')

local Module = {}

---@class TntSqlContext
---@field dialect TntSqlDialect
---@field params table Параметры с полем `n`
---@field scope TntSqlTable[] Таблицы запроса: первая — та, из которой выбирают
---@field aliases table<string, boolean>|nil Псевдонимы выборки, которые можно назвать в order by
local Context = {}
Context.__index = Context

--- Пометка отказа данных, брошенного из глубины сборки.
local Refused = {}

--- Под каким именем таблица стоит в запросе: псевдоним либо имя.
---@param declared TntSqlTable
---@return string
local function key_of(declared)
    return declared.alias or declared.name
end

--- Таблицы запроса с объявленными столбцами — для отказа.
---@param scope TntSqlTable[]
---@return string
local function listing(scope)
    local parts = {}

    for _, declared in ipairs(scope) do
        table.insert(parts, ('%s (%s)'):format(key_of(declared), table.concat(declared.columns, ', ')))
    end

    return table.concat(parts, ', ')
end

--- Имя в кавычках диалекта.
---
--- Имя уже прошло проверку формы (`tnt.sql.names`): кавычки внутри него
--- быть не может, и удваивать нечего.
---@param name string
---@return string
function Context:quote(name)
    return self.dialect.quote .. name .. self.dialect.quote
end

--- Таблица по имени либо псевдониму; nil — такой в запросе нет.
---@param key string
---@return TntSqlTable|nil
function Context:owner(key)
    for _, declared in ipairs(self.scope) do
        if key_of(declared) == key then
            return declared
        end
    end

    return nil
end

--- Столбец по белому списку, в кавычках.
---@param ref TntSqlName
---@param clause string Где стоит — для отказа
---@return string
function Context:column(ref, clause)
    if #self.scope == 0 then
        fail.raise(
            ('%s: у текста руками таблиц нет — имя «%s» пишут в самом тексте'):format(
                clause,
                ref.name
            )
        )
    end

    local quoted = self:quote(ref.name)

    if ref.table ~= nil then
        local owner = self:owner(ref.table)

        if owner == nil then
            local keys = {}

            for index, declared in ipairs(self.scope) do
                keys[index] = key_of(declared)
            end

            fail.raise(
                ('%s: таблицы «%s» в запросе нет, есть %s'):format(
                    clause,
                    ref.table,
                    table.concat(keys, ', ')
                )
            )
        end

        if not owner.known[ref.name] then
            fail.raise(
                ('%s: столбца «%s.%s» нет в белом списке %s'):format(
                    clause,
                    ref.table,
                    ref.name,
                    listing({ owner })
                )
            )
        end

        return self:quote(ref.table) .. '.' .. quoted
    end

    if self.aliases ~= nil and self.aliases[ref.name] then
        return quoted
    end

    local owners = {}

    for _, declared in ipairs(self.scope) do
        if declared.known[ref.name] then
            table.insert(owners, key_of(declared))
        end
    end

    if #owners > 1 then
        fail.raise(
            ('%s: столбец «%s» есть у %s — назовите таблицу: %s.%s'):format(
                clause,
                ref.name,
                table.concat(owners, ' и '),
                owners[1],
                ref.name
            )
        )
    end

    if #owners == 0 then
        fail.raise(
            ('%s: столбца «%s» нет в белом списке %s'):format(
                clause,
                ref.name,
                listing(self.scope)
            )
        )
    end

    return quoted
end

--- Таблица в from и join: `seqscan` там, где диалект без него не просмотрит
--- таблицу целиком, и псевдоним.
---@param declared TntSqlTable
---@param scan boolean|nil Просили ли `seqscan`
---@return string
function Context:table(declared, scan)
    local text = self:quote(declared.name)

    if scan and self.dialect.seqscan then
        text = 'seqscan ' .. text
    end

    if declared.alias ~= nil then
        text = text .. ' as ' .. self:quote(declared.alias)
    end

    return text
end

--- Значение параметром: знак в текст, значение в `params`.
---@param given any
---@return string
function Context:param(given)
    -- Через pcall: у кадра C места нет, и бросок `wire` уходит без места,
    -- которое иначе указало бы внутрь сборки.
    local ok, wired, cast, refusal = pcall(value.wire, self.dialect.name, given)

    if not ok then
        fail.raise(wired)
    end

    if refusal ~= nil then
        error(setmetatable({ failure = refusal }, Refused))
    end

    local params = self.params

    params.n = params.n + 1
    params[params.n] = wired

    local marker = '?'

    if self.dialect.numbered then
        marker = '$' .. params.n
    end

    if cast ~= nil then
        marker = marker .. '::' .. cast
    end

    return marker
end

--- Текст руками со своими значениями.
---@param raw TntSqlRaw
---@return string
function Context:fragment(raw)
    local parts = { raw.pieces[1] }

    for index = 1, raw.params.n do
        table.insert(parts, self:value(raw.params[index]))
        table.insert(parts, raw.pieces[index + 1])
    end

    return table.concat(parts)
end

--- Значение: текст руками — как есть, ссылка на столбец — именем, прочее —
--- параметром.
---@param given any
---@return string
function Context:value(given)
    if kinds.is_raw(given) then
        return self:fragment(given)
    end

    if kinds.is_column(given) then
        return self:column(given.ref, 'sql.column')
    end

    return self:param(given)
end

--- Столбец либо текст руками, с псевдонимом, если он есть.
---@param item TntSqlName|TntSqlRaw
---@param clause string
---@return string
function Context:item(item, clause)
    if kinds.is_raw(item) then
        return self:fragment(item --[[@as TntSqlRaw]])
    end

    local text = self:column(item --[[@as TntSqlName]], clause)

    if item.alias ~= nil then
        text = text .. ' as ' .. self:quote(item.alias)
    end

    return text
end

--- Список столбцов через запятую.
---@param items (TntSqlName|TntSqlRaw)[]
---@param clause string
---@return string
function Context:items(items, clause)
    local parts = {}

    for index, item in ipairs(items) do
        parts[index] = self:item(item, clause)
    end

    return table.concat(parts, ', ')
end

--- Хвост `returning` либо пустота.
---@param returned TntSqlName[]|nil
---@return string
function Context:returning(returned)
    if returned == nil then
        return ''
    end

    if not self.dialect.returning then
        fail.raise(('returning есть только у postgres, а не у %s'):format(self.dialect.name))
    end

    return ' returning ' .. self:items(returned, 'returning')
end

--- Собирает запрос: текст и параметры, либо `nil, err` при отказе данных.
---
--- Зовётся из `build` и не хвостовым вызовом: уровень 3 — строка того, кто
--- позвал `build`.
---@param statement any Что собирать
---@param dialect any Имя диалекта либо таблица диалекта драйвера
---@param render fun(context: TntSqlContext, statement: any): string
---@param scope TntSqlTable[]
---@return string|nil text
---@return table|TntStorageFailure params
function Module.run(statement, dialect, render, scope)
    local rules, complaint = dialects.explain(dialect)

    if rules == nil then
        error(complaint, 3)
    end

    local context = setmetatable({ dialect = rules, params = { n = 0 }, scope = scope }, Context)
    local ok, text = pcall(render, context, statement)

    if not ok then
        if getmetatable(text) == Refused then
            local refused = text --[[@as { failure: TntStorageFailure }]]

            return nil, refused.failure
        end

        error(text, 3)
    end

    return text, context.params
end

return Module
