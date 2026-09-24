--- Общие средства проверок построителя запросов.
---
--- Пакет ничего не выполняет, поэтому проверяется без базы: текст
--- и параметры сверяются целиком и дословно на всех трёх диалектах.
--- Что эти тексты принимают настоящие серверы, проверено запуском
--- на PostgreSQL 16, MySQL 8.4 и Tarantool 3.8 (`docs/sql.md`, «Проверки»).
---
--- Таблицы проверки объявляют в `before_all`, а не при загрузке файла.
--- Бросок `sql.table` при загрузке роняет сам luatest — его обработчик
--- падает на броске `nil`, — и вместо упавшей проверки виден упавший
--- прогон, который мутационный гейт не отличит от сломанного запуска.
--- В `before_all` тот же бросок — обычный провал группы.
---
--- Исходники пакета читаются с диска, а не через `require`: у Tarantool
--- свой загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Поэтому
--- файлы читаются сами, в порядке зависимостей, и кладутся
--- в `package.loaded` под именами модулей: `require` изнутри пакета
--- находит их первыми. Зависимости — `tnt-must`, `tnt-collection`
--- и `tnt-storage` — стоят в `.rocks`, и пакет берёт их обычным `require`:
--- проверяется этот пакет, а не они.
---
--- Проверки берут всё через этот помощник: он — единственное, чем файл
--- проверок отличается от того же файла там, где пакет живёт рядом
--- со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули пакета в порядке зависимостей.
local MODULES = {
    { name = 'tnt.sql.kinds', path = 'tnt/sql/kinds.lua' },
    { name = 'tnt.sql.dialect', path = 'tnt/sql/dialect.lua' },
    { name = 'tnt.sql.names', path = 'tnt/sql/names.lua' },
    { name = 'tnt.sql.context', path = 'tnt/sql/context.lua' },
    { name = 'tnt.sql.raw', path = 'tnt/sql/raw.lua' },
    { name = 'tnt.sql.where', path = 'tnt/sql/where.lua' },
    { name = 'tnt.sql.select', path = 'tnt/sql/select.lua' },
    { name = 'tnt.sql.insert', path = 'tnt/sql/insert.lua' },
    { name = 'tnt.sql.change', path = 'tnt/sql/change.lua' },
    { name = 'tnt.sql.table', path = 'tnt/sql/table.lua' },
    { name = 'tnt.sql', path = 'tnt/sql.lua' },
}

--- Части пакета: имя модуля → его таблица.
---
--- Собираются при загрузке этого помощника, то есть по разу на каждый файл
--- проверок, который его берёт, — а не перед каждой проверкой: состояния
--- у пакета нет — ни настроек, ни подменяемых средств.
---@type table<string, any>
local PARTS = {}

for _, module in ipairs(MODULES) do
    local chunk, failure = loadfile(fio.abspath(module.path))

    if chunk == nil then
        error(('исходник %s не читается: %s'):format(module.name, tostring(failure)))
    end

    local value = chunk()

    -- Пустое значение в `package.loaded` для `require` значит «не загружен»,
    -- и следующий модуль списка молча взял бы установленную копию из `.rocks`.
    if value == nil then
        error(('исходник %s не вернул модуль'):format(module.name))
    end

    package.loaded[module.name] = value
    PARTS[module.name] = value
end

local helper = {}

--- Фасад пакета, собранный из исходников.
helper.sql = PARTS['tnt.sql']

--- Значения хранилищ: обёртки json и binary — той же копии, которой
--- пакет кодирует параметры.
helper.storage = require('tnt.storage')

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Текст и параметры одним списком: сверять их надо вместе.
---@param statement { build: fun(self: any, dialect: any): any, any }
---@param dialect any
---@return table
function helper.built(statement, dialect)
    local text, params = statement:build(dialect)

    return { text, params }
end

return helper
