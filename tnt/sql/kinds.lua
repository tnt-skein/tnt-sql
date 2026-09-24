--- Пометки того, что идёт в текст запроса не параметром.
---
--- Текст руками (`sql.raw`), ссылка на столбец (`sql.column`) и объявление
--- таблицы (`sql.table`) узнаются по метатаблице, а не по полям: таблица
--- значений с полем `pieces`, пришедшая снаружи, не должна стать текстом
--- запроса. Пометки собраны в модуле без зависимостей: их узнаёт сборка,
--- а объявляют модули, которые сами от сборки зависят.

local Module = {}

--- Метатаблица текста руками.
Module.RAW = {}

--- Метатаблица ссылки на столбец.
Module.COLUMN = {}

--- Метатаблица объявления таблицы.
Module.TABLE = {}

--- Текст ли это руками.
---@param value any
---@return boolean
function Module.is_raw(value)
    return getmetatable(value) == Module.RAW
end

--- Ссылка ли это на столбец.
---@param value any
---@return boolean
function Module.is_column(value)
    return getmetatable(value) == Module.COLUMN
end

--- Объявление ли это таблицы.
---@param value any
---@return boolean
function Module.is_table(value)
    return getmetatable(value) == Module.TABLE
end

return Module
