--- Выборка: `select … from … join … where … group by … having … order by
--- … limit … offset …`.
---
---     users:select('id', 'name as title')
---         :join(posts, 'posts.user_id', '=', 'users.id')
---         :where('votes', '>', 100)
---         :order_by('name', 'desc')
---         :limit(10)
---         :build('postgres')
---
--- Без столбцов выборка берёт объявленные столбцы таблицы, а не `*`: белый
--- список сторожит и чтение, и то, что лежит в таблице сверх объявления,
--- наружу не уходит.
---
--- **Имена в выборке уникальны**: рок отдаёт строку словарём по именам
--- столбцов и повтор имён схлопывает в последнее значение молча, поэтому
--- второй `id` без псевдонима — исключение, а не потерянный столбец.
---
--- `limit` и `offset` — проверенные целые, и в текст они идут числами,
--- а не параметрами: `pg` отдаёт число типом `numeric`, а `limit $1`
--- с `numeric` сервер не принимает. `offset` без `limit` — отказ сборки:
--- MySQL и Tarantool так не умеют (проверено запуском).
---
--- `seqscan()` нужен только SQL Tarantool: без него выборка, которой
--- не хватает индекса, отказывает «Scanning is not allowed». Слово
--- ставится у каждой таблицы запроса — у присоединённой тоже; прочие
--- диалекты его не пишут.

local fail = require('tnt.must.fail')
local must = require('tnt.must')

local context = require('tnt.sql.context')
local kinds = require('tnt.sql.kinds')
local names = require('tnt.sql.names')
local where = require('tnt.sql.where')

local Module = {}

---@class TntSqlSelect: TntSqlWhere
---@field from TntSqlTable
---@field columns (TntSqlName|TntSqlRaw)[]
---@field joins table[]
---@field groups (TntSqlName|TntSqlRaw)[]
---@field havings table[]
---@field orders table[]
---@field unique boolean|nil
---@field scan boolean|nil
---@field count number|nil
---@field skip number|nil
local Select = setmetatable({}, { __index = where.Where })
Select.__index = Select

--- Сравнения, которыми связывают таблицы.
---@type table<any, boolean>
local JOINS = { ['='] = true, ['<>'] = true, ['<'] = true, ['<='] = true, ['>'] = true, ['>='] = true }

--- Направления порядка.
---@type table<any, boolean>
local DIRECTIONS = { asc = true, desc = true }

--- Больше этого целое в double уже неточно.
local EXACT = 2 ^ 53

--- Столбец либо текст руками.
---@param spec any
---@param what string
---@param level integer
---@param aliased boolean|nil
---@return TntSqlName|TntSqlRaw
local function item_of(spec, what, level, aliased)
    if kinds.is_raw(spec) then
        return spec
    end

    -- Не хвостовым вызовом: без кадра этой функции уровень вины ушёл бы
    -- на кадр дальше вызывающего.
    local item = names.parse(spec, what, level + 1, aliased)

    return item
end

--- Целое для limit и offset.
---@param value any
---@param what string
---@param level integer
---@return number
local function whole(value, what, level)
    if type(value) ~= 'number' or value % 1 ~= 0 or value < 0 or value > EXACT then
        error(fail.text(what, 'целое число от 0 до 2^53', fail.show(value)), level + 1)
    end

    return value
end

--- Выборка из таблицы.
---@param from TntSqlTable
---@param level integer
---@param count integer
---@param ... any Столбцы: `имя`, `таблица.имя`, `… as псевдоним`, `sql.raw`
---@return TntSqlSelect
function Module.new(from, level, count, ...)
    local specs = { ... }
    local columns = {}
    local seen = {}

    for index = 1, count do
        local item = item_of(specs[index], 'select: столбец', level + 1, true)

        if not kinds.is_raw(item) then
            local ref = item --[[@as TntSqlName]]
            local shown = ref.alias or ref.name

            if seen[shown] then
                error(
                    ('select: имя «%s» в выборке дважды, и рок оставит одно — дайте псевдоним: %s as другое'):format(
                        shown,
                        specs[index]
                    ),
                    level + 1
                )
            end

            seen[shown] = true
        end

        columns[index] = item
    end

    local query = {
        from = from,
        columns = columns,
        conditions = {},
        joins = {},
        groups = {},
        havings = {},
        orders = {},
    }

    return setmetatable(query, Select)
end

--- Присоединяет таблицу.
---@param query TntSqlSelect
---@param kind string
---@param other any
---@param first any
---@param op any
---@param second any
local function join(query, kind, other, first, op, second)
    if not kinds.is_table(other) then
        error(fail.text('join: таблица', 'объявление sql.table', fail.show(other)), 3)
    end

    local key = other.alias or other.name
    local taken = { query.from }

    for _, joined in ipairs(query.joins) do
        table.insert(taken, joined.table)
    end

    for _, declared in ipairs(taken) do
        if (declared.alias or declared.name) == key then
            local complaint = ('join: таблица %s в запросе уже есть — дайте псевдоним: :as(…)'):format(
                key
            )

            error(complaint, 3)
        end
    end

    local left = names.parse(first, 'join: столбец', 3)

    if not JOINS[op] then
        error(('join: оператор %s незнаком: есть =, <>, <, <=, >, >='):format(fail.show(op)), 3)
    end

    local right = names.parse(second, 'join: столбец', 3)

    table.insert(query.joins, { kind = kind, table = other, first = left, op = op, second = right })
end

--- Порядок по столбцу.
---@param query TntSqlSelect
---@param column any
---@param direction any
---@param level integer
local function order(query, column, direction, level)
    local item = item_of(column, 'order_by: столбец', level + 1)
    local way = direction or 'asc'

    if not DIRECTIONS[way] then
        error(fail.text('order_by: направление', 'asc либо desc', fail.show(direction)), level + 1)
    end

    table.insert(query.orders, { item = item, direction = way })
end

--- Без повторов в выдаче.
---@return self
function Select:distinct()
    self.unique = true

    return self
end

--- Внутреннее соединение: `join(posts, 'posts.user_id', '=', 'users.id')`.
---@param other TntSqlTable
---@param first string
---@param op string
---@param second string
---@return self
function Select:join(other, first, op, second)
    join(self, 'inner join', other, first, op, second)

    return self
end

--- Левое соединение тем же видом, что `join`.
---@param other TntSqlTable
---@param first string
---@param op string
---@param second string
---@return self
function Select:left_join(other, first, op, second)
    join(self, 'left join', other, first, op, second)

    return self
end

--- Группировка по столбцам либо тексту руками.
---@param ... string|TntSqlRaw
---@return self
function Select:group_by(...)
    local count = select('#', ...)
    local specs = { ... }

    for index = 1, count do
        table.insert(self.groups, item_of(specs[index], 'group_by: столбец', 2))
    end

    return self
end

--- Условие на группы тем же видом, что `where`: `having(sql.raw('count(*)'), '>', 5)`.
---@param ... any
---@return self
function Select:having(...)
    where.add(self.havings, 'and', 'having', 2, select('#', ...), ...)

    return self
end

--- Порядок: `order_by('name')`, `order_by('votes', 'desc')`; столбец —
--- объявленный либо псевдоним выборки.
---@param column string|TntSqlRaw
---@param direction string|nil asc (по умолчанию) либо desc
---@return self
function Select:order_by(column, direction)
    order(self, column, direction, 2)

    return self
end

--- Порядок, разобранный из адресной строки: `{ { field, direction } }`.
---@param list { field: string, direction: string }[]
---@return self
function Select:sort(list)
    local caller = must.at(2)

    caller.array(list, 'sort: порядок')

    for index, entry in ipairs(list) do
        caller.table(entry, ('sort[%d]'):format(index))
        order(self, entry.field, entry.direction, 2)
    end

    return self
end

--- Сколько строк отдать.
---@param count integer
---@return self
function Select:limit(count)
    self.count = whole(count, 'limit', 2)

    return self
end

--- Сколько строк пропустить; без `limit` сборка отказывает.
---@param skip integer
---@return self
function Select:offset(skip)
    self.skip = whole(skip, 'offset', 2)

    return self
end

--- Страница, разобранная из адресной строки: `{ size, offset }` — это `limit`
--- и `offset`.
---
--- Страница курсором (`after`) — исключение: курсор — строка приложения,
--- продолжение по ключу ставит `where`, и молча отданная первая страница
--- вместо следующей хуже отказа.
---@param page { size: integer, offset: integer|nil, after: string|nil }
---@return self
function Select:page(page)
    must.at(2).table(page, 'page')

    if page.after ~= nil then
        local complaint =
            'page: курсор after разбирает приложение — продолжение ставят where, а сюда отдают страницу без after'

        error(complaint, 2)
    end

    self.count = whole(page.size, 'page.size', 2)

    if page.offset ~= nil then
        self.skip = whole(page.offset, 'page.offset', 2)
    end

    return self
end

--- Разрешить SQL Tarantool просматривать таблицы целиком.
---@return self
function Select:seqscan()
    self.scan = true

    return self
end

--- Список выборки: названные столбцы либо объявленные у таблицы.
---@param into TntSqlContext
---@param query TntSqlSelect
---@return string
local function columns_of(into, query)
    if #query.columns > 0 then
        return into:items(query.columns, 'select')
    end

    local parts = {}
    local prefix = ''

    if #query.joins > 0 then
        prefix = into:quote(query.from.alias or query.from.name) .. '.'
    end

    for index, name in ipairs(query.from.columns) do
        parts[index] = prefix .. into:quote(name)
    end

    return table.concat(parts, ', ')
end

--- Порядок текстом; псевдонимы выборки в нём годятся.
---@param into TntSqlContext
---@param query TntSqlSelect
---@return string
local function orders_of(into, query)
    local aliases = {}

    for _, item in ipairs(query.columns) do
        if not kinds.is_raw(item) and item.alias ~= nil then
            aliases[item.alias] = true
        end
    end

    into.aliases = aliases

    local parts = {}

    for index, entry in ipairs(query.orders) do
        parts[index] = into:item(entry.item, 'order by') .. ' ' .. entry.direction
    end

    into.aliases = nil

    return table.concat(parts, ', ')
end

--- Дописывает часть, если она не пуста.
---@param parts string[]
---@param head string
---@param body string
local function clause(parts, head, body)
    if body ~= '' then
        table.insert(parts, head .. ' ' .. body)
    end
end

--- Выборка текстом.
---@param into TntSqlContext
---@param query TntSqlSelect
---@return string
local function render(into, query)
    local parts = { query.unique and 'select distinct' or 'select', columns_of(into, query) }

    table.insert(parts, 'from ' .. into:table(query.from, query.scan))

    for _, joined in ipairs(query.joins) do
        table.insert(
            parts,
            ('%s %s on %s %s %s'):format(
                joined.kind,
                into:table(joined.table, query.scan),
                into:column(joined.first, 'join'),
                joined.op,
                into:column(joined.second, 'join')
            )
        )
    end

    clause(parts, 'where', where.render(into, query.conditions, 'where'))
    clause(parts, 'group by', into:items(query.groups, 'group by'))
    clause(parts, 'having', where.render(into, query.havings, 'having'))
    clause(parts, 'order by', orders_of(into, query))

    if query.count ~= nil then
        table.insert(parts, ('limit %d'):format(query.count))
    end

    if query.skip ~= nil then
        if query.count == nil then
            fail.raise('offset без limit: MySQL и Tarantool так не умеют — задайте limit')
        end

        table.insert(parts, ('offset %d'):format(query.skip))
    end

    return table.concat(parts, ' ')
end

--- Текст и параметры под диалект.
---@param dialect any Имя диалекта либо таблица диалекта драйвера
---@return string|nil text
---@return table|TntStorageFailure params Параметры с полем `n` либо отказ данных
function Select:build(dialect)
    local scope = { self.from }

    for _, joined in ipairs(self.joins) do
        table.insert(scope, joined.table)
    end

    local text, params = context.run(self, dialect, render, scope)

    return text, params
end

return Module
