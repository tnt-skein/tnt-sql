--- Правка и удаление: `update(values):where(…)`, `delete():where(…)`.
---
--- **Без условия — исключение.** `update` и `delete` без `where` меняют
--- всю таблицу, и чаще всего так выходит нечаянно: фильтр из адреса
--- оказался пуст (`filter({})` условий не ставит), группа ничего
--- не добавила. Всю таблицу меняют, сказав это явно: `everything()`.
---
--- Значения правки — таблица «столбец → значение»; столбцы идут
--- по порядку имён (`tnt-collection`, `keys`), и одинаковая правка даёт
--- один и тот же текст. NULL — `box.NULL`. Значением может быть и текст
--- руками: `{ votes = sql.raw('"votes" + ?', 1) }`.
---
--- `seqscan` правке и удалению в SQL Tarantool не нужен и не принимается:
--- проверено запуском, `update seqscan …` — синтаксическая ошибка.

local collection = require('tnt.collection')
local fail = require('tnt.must.fail')

local context = require('tnt.sql.context')
local names = require('tnt.sql.names')
local where = require('tnt.sql.where')

local Module = {}

---@class TntSqlChange: TntSqlWhere
---@field target TntSqlTable
---@field sets { column: string, value: any }[]|nil Правка по столбцам; nil — удаление
---@field all boolean|nil
---@field returned TntSqlName[]|nil
local Change = setmetatable({}, { __index = where.Where })
Change.__index = Change

--- Правка либо удаление.
---@param target TntSqlTable
---@param values table|nil Значения правки; nil — удаление
---@param level integer
---@return TntSqlChange
function Module.new(target, values, level)
    local verb = values == nil and 'delete' or 'update'

    if target.alias ~= nil then
        error(
            ('%s: у таблицы с псевдонимом правок нет — псевдоним только для выборки'):format(
                verb
            ),
            level + 1
        )
    end

    local query = setmetatable({ target = target, conditions = {} }, Change)

    if values == nil then
        return query
    end

    local columns = collection.keys(values)

    if #columns == 0 then
        error('update: значений нет — править нечего', level + 1)
    end

    local sets = {}

    for index, column in ipairs(columns) do
        sets[index] = { column = names.check(column, 'update: столбец', level + 1), value = values[column] }
    end

    query.sets = sets

    return query
end

--- Разрешить правку и удаление без условия — всей таблицы.
---@return self
function Change:everything()
    self.all = true

    return self
end

--- Вернуть столбцы затронутых строк: только PostgreSQL.
---@param ... string
---@return self
function Change:returning(...)
    self.returned = names.list('returning: столбец', 2, select('#', ...), ...)

    return self
end

--- Правка либо удаление текстом.
---@param into TntSqlContext
---@param query TntSqlChange
---@return string
local function render(into, query)
    local text = 'delete from ' .. into:table(query.target)
    local verb = 'delete'

    if query.sets ~= nil then
        local sets = {}

        for index, set in ipairs(query.sets) do
            sets[index] = into:column({ name = set.column }, 'update') .. ' = ' .. into:value(set.value)
        end

        text = ('update %s set %s'):format(into:table(query.target), table.concat(sets, ', '))
        verb = 'update'
    end

    local conditions = where.render(into, query.conditions, 'where')

    if conditions ~= '' then
        text = text .. ' where ' .. conditions
    elseif not query.all then
        fail.raise(
            ('%s без where меняет всю таблицу — если так и задумано, скажите everything()'):format(
                verb
            )
        )
    end

    return text .. into:returning(query.returned)
end

--- Текст и параметры под диалект.
---@param dialect any Имя диалекта либо таблица диалекта драйвера
---@return string|nil text
---@return table|TntStorageFailure params Параметры с полем `n` либо отказ данных
function Change:build(dialect)
    local text, params = context.run(self, dialect, render, { self.target })

    return text, params
end

return Module
