--- Имена: что годится в имя и как его прочесть из строки.
---
--- Имя в тексте запроса — единственное, что попадает туда не параметром,
--- поэтому годится только одно: латиница, цифры и `_`, не с цифры,
--- не длиннее 63 байтов. Такое имя в кавычках диалекта не может ни закрыть
--- кавычку, ни начать второй оператор, чем бы ни было. Сверх того имя
--- столбца обязано стоять в белом списке таблицы (`tnt.sql.context`):
--- форма имени бережёт текст запроса, белый список — чужие столбцы.
---
--- 63 байта — предел PostgreSQL: длиннее он обрезает имя молча, и два
--- длинных имени с общим началом стали бы одним.
---
--- Форма проверяется в миг вызова, на строке вызывающего; белый список —
--- при сборке, когда известны все таблицы запроса.

local fail = require('tnt.must.fail')

local kinds = require('tnt.sql.kinds')

local Module = {}

--- Самое длинное имя в байтах.
Module.MAX_LENGTH = 63

--- Имя: латиница, цифры и подчёркивание, не с цифры.
local IDENTIFIER = '^[%a_][%w_]*$'

---@class TntSqlName
---@field table string|nil Таблица: имя либо псевдоним, если названа
---@field name string Столбец
---@field alias string|nil Псевдоним в списке select

---@class TntSqlColumn
---@field ref TntSqlName

--- Текст отказа о негодном имени либо nil.
---@param name any
---@param what string Что это за имя — для отказа
---@return string|nil complaint
function Module.explain(name, what)
    if type(name) == 'string' and #name <= Module.MAX_LENGTH and name:find(IDENTIFIER) then
        return nil
    end

    return fail.text(
        what,
        ('имя из латиницы, цифр и _, не с цифры и не длиннее %d байтов'):format(
            Module.MAX_LENGTH
        ),
        fail.show(name)
    )
end

--- Бросает, если имя негодно.
---@param name any
---@param what string
---@param level integer Уровень вины в кадрах того, кто зовёт: 1 — его строка
---@return string
function Module.check(name, what, level)
    local complaint = Module.explain(name, what)

    if complaint ~= nil then
        error(complaint, level + 1)
    end

    return name
end

--- Ссылка на столбец из строки: `имя`, `таблица.имя`, а в списке select —
--- ещё и `… as псевдоним`.
---@param spec any
---@param what string Где стоит ссылка — для отказа
---@param level integer Уровень вины в кадрах того, кто зовёт
---@param aliased boolean|nil Можно ли псевдоним
---@return TntSqlName
function Module.parse(spec, what, level, aliased)
    if type(spec) ~= 'string' then
        error(fail.text(what, 'имя столбца строкой', fail.show(spec)), level + 1)
    end

    local body, alias = spec:match('^(.-) as (.*)$')

    if body == nil then
        body = spec
    elseif not aliased then
        error(
            ('%s: псевдоним ставят только в списке select, а не %s'):format(
                what,
                fail.show(spec)
            ),
            level + 1
        )
    else
        Module.check(alias, what .. ': псевдоним', level + 1)
    end

    local owner, name = body:match('^(.*)%.(.*)$')

    if owner ~= nil then
        Module.check(owner, what .. ': таблица', level + 1)
    end

    return { table = owner, name = Module.check(name or body, what, level + 1), alias = alias }
end

--- Ссылки на столбцы списком, без псевдонимов.
---@param what string
---@param level integer Уровень вины в кадрах того, кто зовёт
---@param count integer Сколько пришло
---@param ... any
---@return TntSqlName[]
function Module.list(what, level, count, ...)
    local specs = { ... }
    local list = {}

    for index = 1, count do
        list[index] = Module.parse(specs[index], what, level + 1)
    end

    return list
end

--- Ссылка на столбец там, где ждут значение: `where('updated_at', '>',
--- sql.column('created_at'))` сравнивает два столбца, а не столбец
--- со строкой.
---@param spec string `имя` либо `таблица.имя`
---@return TntSqlColumn
function Module.column(spec)
    return setmetatable({ ref = Module.parse(spec, 'sql.column', 2) }, kinds.COLUMN)
end

return Module
