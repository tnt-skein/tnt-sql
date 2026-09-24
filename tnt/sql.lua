--- Построитель запросов: текст и параметры, а выполняет драйвер.
---
---     local sql = require('tnt.sql')
---
---     local users = sql.table('users', { 'id', 'name', 'email', 'votes' })
---
---     local text, params = users:select('id', 'name')
---         :where('votes', '>', 100)
---         :order_by('name', 'desc')
---         :limit(10)
---         :build('postgres')
---     -- select "id", "name" from "users" where "votes" > $1 order by "name" desc limit 10
---     -- { n = 1, 100 }
---
--- Запрос собирается вызовами, а не склейкой строк, и пакет **ничего не
--- выполняет**: `build` отдаёт пару «текст и параметры» — параметры
--- массивом с полем `n`, — а в базу ходит драйвер. Отсюда два
--- следствия. Значение никогда не склеивается с текстом — оно уходит
--- параметром, и внедрению SQL взяться неоткуда. И пакет проверяется
--- целиком без базы.
---
--- Диалект — `postgres` (`$1`, `"имя"`, приведение `$1::int8`), `mysql`
--- (`?`, `` `имя` ``) либо `tarantool` (`?`, `"имя"`, `seqscan`), именем
--- либо таблицей диалекта драйвера с полем `name`. Значения кодирует
--- `tnt-storage` (`value.wire`) — так же, как драйвер: `int64`, `decimal`,
--- `uuid`, время, `storage.json` и `storage.binary` доезжают без потерь.
---
--- Имя столбца обязано стоять в белом списке таблицы (`sql.table`), а
--- его форма — латиница, цифры и `_`: имя, пришедшее снаружи, не станет
--- ни чужим столбцом, ни текстом запроса.
---
--- Отказ — пара `nil, err` только у `build` и только за данные: строка
--- с нулевым байтом у PostgreSQL (`TntStorageFailure`, род `rejected`).
--- Всё прочее — незнакомый столбец, оператор, диалект, `update` без
--- `where` — ошибка программиста и исключение на строке вызывающего.
---
--- Настроек и состояния у пакета нет. Подробно — `docs/sql.md`.

local dialect = require('tnt.sql.dialect')
local names = require('tnt.sql.names')
local raw = require('tnt.sql.raw')
local tables = require('tnt.sql.table')
local where = require('tnt.sql.where')

local Module = {}

--- PostgreSQL.
Module.POSTGRES = dialect.POSTGRES

--- MySQL.
Module.MYSQL = dialect.MYSQL

--- SQL самого Tarantool (`box.execute`).
Module.TARANTOOL = dialect.TARANTOOL

--- Операторы условий по порядку.
Module.OPERATORS = where.OPERATORS

--- Объявление таблицы: имя и белый список столбцов.
Module.table = tables.new

--- Текст руками со знаками `?`: целый запрос либо кусок другого.
Module.raw = raw.new

--- Ссылка на столбец там, где ждут значение.
Module.column = names.column

return Module
