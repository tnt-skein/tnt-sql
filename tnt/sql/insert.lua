--- Вставка и вставка с заменой: `insert(rows)`, `upsert(rows, unique_by, update)`.
---
--- Строка — таблица «столбец → значение», строк — одна либо список.
--- Столбцы идут по порядку имён (`tnt-collection`, `keys`): одинаковые
--- строки дают один и тот же текст, и подготовленный запрос у сервера
--- переиспользуется. У всех строк списка столбцы одни и те же: какое
--- значение ставить на место недостающего, пакет не угадывает. NULL
--- в строке — `box.NULL`: `nil` таблица не хранит, и столбец пропал бы.
---
--- `upsert` на конфликте по `unique_by` обновляет столбцы `update` —
--- по умолчанию все вставленные, кроме `unique_by`:
---
--- - PostgreSQL — `on conflict (…) do update set x = excluded.x`;
--- - MySQL — `as excluded on duplicate key update x = excluded.x`
---   (псевдоним строки, MySQL 8.0.19 и новее; `values(x)` устарел);
---   `unique_by` MySQL не пишет — конфликт он находит по любому
---   уникальному ключу, — но пакет его требует и проверяет всё равно;
--- - SQL Tarantool `on conflict` не знает — сборка отказывает; `insert or
---   replace` не то же самое: он стирает столбцы, которых нет в строке.

local collection = require('tnt.collection')
local fail = require('tnt.must.fail')
local must = require('tnt.must')

local context = require('tnt.sql.context')
local names = require('tnt.sql.names')

local Module = {}

---@class TntSqlInsert
---@field into TntSqlTable
---@field columns string[]
---@field rows any[][]
---@field conflict { unique_by: string[], update: string[] }|nil Что делать на конфликте у upsert
---@field returned TntSqlName[]|nil
local Insert = {}
Insert.__index = Insert

--- Имена столбцов списком, каждое — из вставленных.
---@param given any
---@param what string
---@param inserted table<string, boolean>
---@param level integer
---@return string[]
local function subset(given, what, inserted, level)
    must.at(level + 1).array(given, what)

    local list = {}

    for index, name in ipairs(given) do
        local place = ('%s[%d]'):format(what, index)

        names.check(name, place, level + 1)

        if not inserted[name] then
            error(('%s: столбца «%s» среди вставленных нет'):format(place, name), level + 1)
        end

        list[index] = name
    end

    return list
end

--- Строки вставки: столбцы по порядку и значения по ним.
---@param given any
---@param level integer
---@return string[] columns
---@return any[][] rows
local function rows_of(given, level)
    must.at(level + 1).table(given, 'insert: строки')

    local list = given

    if not collection.is_array(given) then
        list = { given }
    end

    if #list == 0 then
        error('insert: строк нет — вставлять нечего', level + 1)
    end

    ---@type string[]
    local columns = {}
    ---@type string|nil
    local expected
    local rows = {}

    for index, row in ipairs(list) do
        must.at(level + 1).table(row, ('insert: строка №%d'):format(index))

        local keys = collection.keys(row)
        local shown = table.concat(keys, ', ')

        if #keys == 0 then
            error(
                ('insert: строка №%d пуста — вставлять нечего'):format(index),
                level + 1
            )
        end

        if expected == nil then
            columns, expected = keys, shown
        elseif shown ~= expected then
            error(
                ('insert: у строки №%d столбцы %s, а у первой %s'):format(
                    index,
                    shown,
                    expected
                ),
                level + 1
            )
        end

        local values = {}

        for position, column in ipairs(columns) do
            names.check(column, 'insert: столбец', level + 1)
            values[position] = row[column]
        end

        rows[index] = values
    end

    return columns, rows
end

--- Вставка в таблицу.
---@param into TntSqlTable
---@param given any Строка либо список строк
---@param conflict table|nil `{ unique_by, update }` для `upsert`
---@param level integer
---@return TntSqlInsert
function Module.new(into, given, conflict, level)
    if into.alias ~= nil then
        error(
            'insert: у таблицы с псевдонимом вставки нет — псевдоним только для выборки',
            level + 1
        )
    end

    local columns, rows = rows_of(given, level + 1)
    local query = setmetatable({ into = into, columns = columns, rows = rows }, Insert)

    if conflict == nil then
        return query
    end

    local inserted = {}

    for _, column in ipairs(columns) do
        inserted[column] = true
    end

    local unique_by = subset(conflict.unique_by, 'upsert: unique_by', inserted, level + 1)
    local unique = {}

    for _, column in ipairs(unique_by) do
        unique[column] = true
    end

    local update = conflict.update

    if update == nil then
        update = {}

        for _, column in ipairs(columns) do
            if not unique[column] then
                table.insert(update, column)
            end
        end
    end

    local updated = subset(update, 'upsert: update', inserted, level + 1)

    if #updated == 0 then
        error(
            'upsert: обновлять нечего — все столбцы в unique_by; вставка без обновления — не upsert',
            level + 1
        )
    end

    query.conflict = { unique_by = unique_by, update = updated }

    return query
end

--- Вернуть столбцы вставленных строк: только PostgreSQL.
---@param ... string
---@return self
function Insert:returning(...)
    self.returned = names.list('returning: столбец', 2, select('#', ...), ...)

    return self
end

--- Хвост `upsert` по диалекту.
---@param into TntSqlContext
---@param conflict { unique_by: string[], update: string[] }
---@return string
local function conflict_of(into, conflict)
    local upsert = into.dialect.upsert

    if upsert == nil then
        fail.raise(
            ('upsert: в SQL %s нет on conflict, а insert or replace стёр бы столбцы, которых нет в строке'):format(
                into.dialect.name
            )
        )
    end

    local excluded = into:quote('excluded')
    local sets = {}

    for index, column in ipairs(conflict.update) do
        local quoted = into:quote(column)

        sets[index] = ('%s = %s.%s'):format(quoted, excluded, quoted)
    end

    if upsert == 'duplicate' then
        return (' as %s on duplicate key update %s'):format(excluded, table.concat(sets, ', '))
    end

    local unique = {}

    for index, column in ipairs(conflict.unique_by) do
        unique[index] = into:quote(column)
    end

    return (' on conflict (%s) do update set %s'):format(table.concat(unique, ', '), table.concat(sets, ', '))
end

--- Вставка текстом.
---@param into TntSqlContext
---@param query TntSqlInsert
---@return string
local function render(into, query)
    local columns = {}

    for index, column in ipairs(query.columns) do
        columns[index] = into:column({ name = column }, 'insert')
    end

    local rows = {}

    for index, row in ipairs(query.rows) do
        local markers = {}

        for position = 1, #query.columns do
            markers[position] = into:value(row[position])
        end

        rows[index] = '(' .. table.concat(markers, ', ') .. ')'
    end

    local text = ('insert into %s (%s) values %s'):format(
        into:table(query.into),
        table.concat(columns, ', '),
        table.concat(rows, ', ')
    )

    if query.conflict ~= nil then
        text = text .. conflict_of(into, query.conflict)
    end

    return text .. into:returning(query.returned)
end

--- Текст и параметры под диалект.
---@param dialect any Имя диалекта либо таблица диалекта драйвера
---@return string|nil text
---@return table|TntStorageFailure params Параметры с полем `n` либо отказ данных
function Insert:build(dialect)
    local text, params = context.run(self, dialect, render, { self.into })

    return text, params
end

return Module
