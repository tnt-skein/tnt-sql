--- Объявление таблицы — белый список её столбцов.
---
---     local users = sql.table('users', { 'id', 'name', 'email', 'votes' })
---
--- Всякий запрос начинается с объявления, и столбец, которого в нём нет,
--- в текст запроса не попадёт — ни в выборку, ни в условие, ни в порядок,
--- откуда бы ни пришло имя. Без объявления фильтр из адресной строки
--- становится способом прочитать чужое: `filter[password_hash][prefix]=a`
--- отвечает числом найденных строк, и хеш подбирается по знаку.
---
--- Объявление не держит состояния и не знает диалекта: одно на всё
--- приложение, собирается под любой диалект при `build`. Псевдоним
--- (`users:as('u')`) — новое объявление с теми же столбцами: так таблицу
--- присоединяют к самой себе.

local must = require('tnt.must')

local change = require('tnt.sql.change')
local insert = require('tnt.sql.insert')
local kinds = require('tnt.sql.kinds')
local names = require('tnt.sql.names')
local query = require('tnt.sql.select')

local Module = {}

---@class TntSqlTable
---@field name string Имя таблицы
---@field alias string|nil Псевдоним
---@field columns string[] Столбцы по порядку объявления
---@field known table<string, boolean> Белый список
local Table = kinds.TABLE
Table.__index = Table

--- Объявляет таблицу и её столбцы.
---@param name string Имя таблицы
---@param columns string[] Столбцы: белый список
---@return TntSqlTable
function Module.new(name, columns)
    names.check(name, 'sql.table: имя таблицы', 2)
    must.at(2).array(columns, 'sql.table: столбцы')

    if #columns == 0 then
        local complaint = ('sql.table: у таблицы %s столбцов нет — белый список пуст'):format(
            name
        )

        error(complaint, 2)
    end

    local known = {}
    local list = {}

    for index, column in ipairs(columns) do
        names.check(column, ('sql.table: столбец №%d'):format(index), 2)

        if known[column] then
            error(('sql.table: столбец %s объявлен дважды'):format(column), 2)
        end

        known[column] = true
        list[index] = column
    end

    return setmetatable({ name = name, columns = list, known = known }, Table)
end

--- Та же таблица под псевдонимом — для выборки.
---@param alias string
---@return TntSqlTable
function Table:as(alias)
    names.check(alias, 'as: псевдоним', 2)

    return setmetatable({ name = self.name, alias = alias, columns = self.columns, known = self.known }, Table)
end

--- Выборка: `select()` — все объявленные столбцы, `select('id', 'name as title')`
--- — названные.
---@param ... string|TntSqlRaw
---@return TntSqlSelect
function Table:select(...)
    local built = query.new(self, 2, select('#', ...), ...)

    return built
end

--- Вставка строки либо списка строк.
---@param rows table
---@return TntSqlInsert
function Table:insert(rows)
    local built = insert.new(self, rows, nil, 2)

    return built
end

--- Вставка с обновлением на конфликте по `unique_by`.
---@param rows table
---@param unique_by string[]
---@param update string[]|nil Что обновить; nil — все вставленные, кроме unique_by
---@return TntSqlInsert
function Table:upsert(rows, unique_by, update)
    local built = insert.new(self, rows, { unique_by = unique_by, update = update }, 2)

    return built
end

--- Правка: `update({ name = 'x' }):where('id', '=', 7)`.
---@param values table Столбец → значение
---@return TntSqlChange
function Table:update(values)
    must.at(2).table(values, 'update: значения')

    local built = change.new(self, values, 2)

    return built
end

--- Удаление: `delete():where('id', '=', 7)`.
---@return TntSqlChange
function Table:delete()
    local built = change.new(self, nil, 2)

    return built
end

return Module
