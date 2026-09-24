--- Диалекты: знак параметра, кавычка имени и то, чего у диалекта нет.
---
--- Три диалекта, под которые драйверы принимают текст и параметры, и у
--- каждого своё, проверенное запуском:
---
--- | | `postgres` | `mysql` | `tarantool` |
--- |---|---|---|---|
--- | параметр | `$1`, `$2`… | `?` | `?` |
--- | имя | `"имя"` | `` `имя` `` | `"имя"` |
--- | `returning` | есть | нет | нет |
--- | `upsert` | `on conflict … do update` | `on duplicate key update` | нет: SQL Tarantool не знает `on conflict` |
--- | полный просмотр | сам | сам | только с `seqscan` у каждой таблицы |
---
--- Диалект — имя либо таблица диалекта драйвера с полем `name`: драйвер
--- объявляет диалект сам, а собирает под него этот пакет, поэтому
--- из таблицы драйвера берётся только имя. Своё знание о знаке и кавычке
--- у драйвера и у пакета разойтись не может: оно здесь одно.

local value = require('tnt.storage.value')

local Module = {}

--- PostgreSQL: параметры `$n`, приведение `$n::тип`, `returning`.
Module.POSTGRES = value.POSTGRES

--- MySQL: параметры `?`, имена в обратных кавычках.
Module.MYSQL = value.MYSQL

--- SQL самого Tarantool (`box.execute`): параметры `?`, `seqscan`.
Module.TARANTOOL = value.TARANTOOL

---@class TntSqlDialect
---@field name string Имя диалекта
---@field quote string Кавычка имени
---@field numbered boolean Знак параметра с номером: `$1`, а не `?`
---@field returning boolean Умеет ли `returning`
---@field upsert string|nil Вид `upsert`: `conflict`, `duplicate` либо nil — не умеет
---@field seqscan boolean Нужен ли `seqscan` таблице, которую просматривают целиком

--- Правила диалектов по имени.
---@type table<string, TntSqlDialect>
local RULES = {
    [Module.POSTGRES] = {
        name = Module.POSTGRES,
        quote = '"',
        numbered = true,
        returning = true,
        upsert = 'conflict',
        seqscan = false,
    },
    [Module.MYSQL] = {
        name = Module.MYSQL,
        quote = '`',
        numbered = false,
        returning = false,
        upsert = 'duplicate',
        seqscan = false,
    },
    [Module.TARANTOOL] = {
        name = Module.TARANTOOL,
        quote = '"',
        numbered = false,
        returning = false,
        upsert = nil,
        seqscan = true,
    },
}

--- Правила диалекта либо текст отказа.
---
--- Отказ не бросается здесь: его бросает сборка, у которой уровень вины
--- свой, — строка того, кто позвал `build`.
---@param dialect any Имя либо таблица диалекта драйвера с полем `name`
---@return TntSqlDialect|nil rules
---@return string|nil complaint
function Module.explain(dialect)
    local name = dialect

    if type(dialect) == 'table' then
        name = dialect.name
    end

    local rules = RULES[name]

    if rules == nil then
        return nil, ('диалект %s незнаком: есть postgres, mysql, tarantool'):format(tostring(name))
    end

    return rules
end

return Module
