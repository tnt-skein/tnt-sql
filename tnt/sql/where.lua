--- Условия: `where` выборки, правки и удаления, `having` выборки.
---
---     :where('votes', '>', 100)
---     :where('state', 'in', { 'alive', 'dead' })
---     :or_where(function(group) group:where('name', 'prefix', 'stor'):where('leader', '=', true) end)
---     :filter(asked.filter)                 -- условия, разобранные из адреса
---
--- Условие — столбец, оператор, значение. Оператор — только из перечня:
--- он единственное слово условия, которое попадает в текст запроса
--- как есть, и незнакомый оператор — исключение, откуда бы он ни пришёл.
--- Значение уходит параметром; справа может стоять и столбец
--- (`sql.column`), и текст руками (`sql.raw`). Функция — скобки: условия,
--- которые она поставит группе, идут вместе, и так пишется «или» внутри «и».
---
--- Сравнения с NULL нет: `x = NULL` не бывает истинным, и значение `nil` в
--- сравнении — исключение, а не молчаливое `is null`. Иначе фильтр, чьё
--- значение не пришло, превращался бы в поиск пустоты.
---
--- `prefix` и `contains` — кусок строки буквально: `%`, `_` и знак
--- экранирования в нём экранируются, и уходит он параметром `like ?
--- escape '!'`. Знак экранирования — `!`, а не обратная черта: её MySQL
--- читает экранированием уже в литерале, и `escape '\'` у него — незакрытая
--- строка. Проверено запуском на трёх диалектах.

local fail = require('tnt.must.fail')
local must = require('tnt.must')

local kinds = require('tnt.sql.kinds')
local names = require('tnt.sql.names')

local Module = {}

---@class TntSqlWhere
---@field conditions table[] Условия по порядку
local Where = {}
Where.__index = Where

--- Класс условий: от него идут выборка, правка и удаление.
Module.Where = Where

--- Операторы по порядку.
Module.OPERATORS = {
    '=',
    '<>',
    '<',
    '<=',
    '>',
    '>=',
    'in',
    'not in',
    'between',
    'not between',
    'like',
    'not like',
    'prefix',
    'contains',
    'is null',
    'is not null',
}

--- Что нужно оператору справа: значение, список, пару, кусок строки либо
--- ничего.
local NEEDS = {
    ['='] = 'value',
    ['<>'] = 'value',
    ['<'] = 'value',
    ['<='] = 'value',
    ['>'] = 'value',
    ['>='] = 'value',
    ['like'] = 'value',
    ['not like'] = 'value',
    ['in'] = 'list',
    ['not in'] = 'list',
    ['between'] = 'pair',
    ['not between'] = 'pair',
    ['prefix'] = 'text',
    ['contains'] = 'text',
    ['is null'] = 'none',
    ['is not null'] = 'none',
}

--- Операторы условий, разобранных из адресной строки
--- (`?filter[votes][gte]=10`), идут словами, и в текст запроса попадает
--- только знак из этого перевода, а не слово из адреса.
Module.FILTERS = {
    eq = '=',
    ne = '<>',
    gt = '>',
    gte = '>=',
    lt = '<',
    lte = '<=',
    ['in'] = 'in',
    prefix = 'prefix',
    contains = 'contains',
}

--- Кусок строки буквально: `%`, `_` и сам знак экранирования — со знаком.
---@param text string
---@param op string prefix либо contains
---@return string
local function pattern_of(text, op)
    local escaped = text:gsub('[!%%_]', '!%0')

    if op == 'prefix' then
        return escaped .. '%'
    end

    return '%' .. escaped .. '%'
end

--- Значения списка копией: правка таблицы вызывающего после вызова запрос
--- не меняет.
---@param given any
---@param clause string
---@param op string
---@param level integer
---@return any[]
local function list_of(given, clause, op, level)
    must.at(level + 1).array(given, ('%s: значения %s'):format(clause, op))

    local copy = {}

    -- NULL в списке `must.array` принимает за дыру и отказывает сам:
    -- `x in (NULL)` не бывает истинным, как и сравнение с NULL.
    for index, item in ipairs(given) do
        copy[index] = item
    end

    return copy
end

--- Проверенное значение условия под его оператор.
---@param clause string
---@param op string
---@param given any
---@param level integer
---@return any
local function right_of(clause, op, given, level)
    local need = NEEDS[op]

    if need == 'none' then
        -- Явный nil третьим аргументом — не значение: обёртка вида
        -- `where(f.field, f.op, f.value)` передаёт три аргумента всегда.
        if given ~= nil then
            error(
                ('%s: у «%s» значения нет, а пришло %s'):format(clause, op, fail.show(given)),
                level + 1
            )
        end

        return nil
    end

    if need == 'text' then
        if type(given) ~= 'string' then
            error(
                fail.text(('%s: кусок строки у %s'):format(clause, op), 'строка', fail.show(given)),
                level + 1
            )
        end

        return pattern_of(given, op)
    end

    if need == 'value' then
        if given == nil then
            error(
                ('%s: сравнение с NULL не бывает истинным — пишите «is null» либо «is not null»'):format(
                    clause
                ),
                level + 1
            )
        end

        return given
    end

    local copy = list_of(given, clause, op, level + 1)

    if need == 'pair' and #copy ~= 2 then
        error(('%s: у %s два значения, а пришло %d'):format(clause, op, #copy), level + 1)
    end

    return copy
end

--- Ставит в список сравнение: столбец либо `sql.raw`, оператор, значение.
---@param list table[] Куда
---@param glue string and либо or
---@param clause string Где стоит — для отказа
---@param level integer Уровень вины в кадрах того, кто зовёт
---@param left any Столбец либо `sql.raw`
---@param op any Оператор
---@param right any Значение
local function compare(list, glue, clause, level, left, op, right)
    local subject = left

    if not kinds.is_raw(left) then
        subject = names.parse(left, clause .. ': столбец', level + 1)
    end

    if NEEDS[op] == nil then
        error(
            ('%s: оператор %s незнаком: есть %s'):format(
                clause,
                fail.show(op),
                table.concat(Module.OPERATORS, ', ')
            ),
            level + 1
        )
    end

    local value = right_of(clause, op, right, level + 1)

    table.insert(list, { glue = glue, subject = subject, op = op, value = value })
end

--- Ставит условие в список.
---@param list table[] Куда
---@param glue string and либо or
---@param clause string where либо having — для отказа
---@param level integer Уровень вины в кадрах того, кто зовёт
---@param count integer Сколько аргументов пришло
---@param left any Столбец, `sql.raw` либо функция группы
---@param op any Оператор
---@param right any Значение
function Module.add(list, glue, clause, level, count, left, op, right)
    if type(left) == 'function' then
        local group = setmetatable({ conditions = {} }, Where)

        left(group)

        if #group.conditions > 0 then
            table.insert(list, { glue = glue, group = group.conditions })
        end

        return
    end

    if kinds.is_raw(left) and count == 1 then
        table.insert(list, { glue = glue, raw = left })

        return
    end

    if count > 3 then
        error(
            ('%s: аргументов %d, а условие — столбец, оператор и значение; «или» пишут or_where'):format(
                clause,
                count
            ),
            level + 1
        )
    end

    compare(list, glue, clause, level + 1, left, op, right)
end

--- Условие «и».
---
--- `where('votes', '>', 100)`, `where('deleted_at', 'is null')`,
--- `where(sql.raw('lower("name") = ?', name))`, `where(function(group) … end)`.
---@param ... any Столбец, оператор, значение; либо `sql.raw`; либо функция группы
---@return self
function Where:where(...)
    Module.add(self.conditions, 'and', 'where', 2, select('#', ...), ...)

    return self
end

--- Условие «или» — тем же видом, что `where`.
---@param ... any
---@return self
function Where:or_where(...)
    Module.add(self.conditions, 'or', 'where', 2, select('#', ...), ...)

    return self
end

--- Условия, разобранные из адресной строки: `{ field, op, value }`, все
--- через «и».
---
--- Поле — имя столбца, и белый список таблицы его всё равно проверит:
--- разбор адреса и сборка запроса сторожат каждый своё.
---@param conditions { field: string, op: string, value: any }[]
---@return self
function Where:filter(conditions)
    local caller = must.at(2)

    caller.array(conditions, 'filter: условия')

    for index, condition in ipairs(conditions) do
        local place = ('filter[%d]'):format(index)

        caller.table(condition, place)

        local op = Module.FILTERS[condition.op]

        if op == nil then
            local complaint = ('%s: оператор %s незнаком: есть eq, ne, gt, gte, lt, lte, in, prefix, contains'):format(
                place,
                fail.show(condition.op)
            )

            error(complaint, 2)
        end

        compare(self.conditions, 'and', place, 2, condition.field, op, condition.value)
    end

    return self
end

---@type fun(into: TntSqlContext, list: table[], clause: string): string
local render

--- Одно условие текстом.
---@param into TntSqlContext
---@param item table
---@param clause string
---@return string
local function condition(into, item, clause)
    if item.group ~= nil then
        return '(' .. render(into, item.group, clause) .. ')'
    end

    if item.raw ~= nil then
        return into:fragment(item.raw)
    end

    local subject = into:item(item.subject, clause)
    local op, given = item.op, item.value
    local need = NEEDS[op]

    if need == 'none' then
        return subject .. ' ' .. op
    end

    if need == 'list' then
        if #given == 0 then
            -- Пустой список: `in ()` — синтаксическая ошибка у всех трёх.
            return op == 'in' and '1 = 0' or '1 = 1'
        end

        local markers = {}

        for index, item_value in ipairs(given) do
            markers[index] = into:value(item_value)
        end

        return ('%s %s (%s)'):format(subject, op, table.concat(markers, ', '))
    end

    if need == 'pair' then
        -- Порядок знаков `?` — порядок значений в params: сначала нижняя
        -- граница, потом верхняя, и не на совести порядка вычисления аргументов.
        local low = into:value(given[1])
        local high = into:value(given[2])

        return ('%s %s %s and %s'):format(subject, op, low, high)
    end

    if need == 'text' then
        return ("%s like %s escape '!'"):format(subject, into:value(given))
    end

    return ('%s %s %s'):format(subject, op, into:value(given))
end

--- Условия текстом; пустой список — пустая строка.
---@param into TntSqlContext
---@param list table[]
---@param clause string
---@return string
render = function(into, list, clause)
    local parts = {}

    for index, item in ipairs(list) do
        if index > 1 then
            table.insert(parts, item.glue)
        end

        table.insert(parts, condition(into, item, clause))
    end

    return table.concat(parts, ' ')
end

Module.render = render

return Module
