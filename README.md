# tnt-sql

Построитель запросов для Tarantool: собирает SQL вызовами, а не склейкой
строк, и ничего не выполняет — `build` отдаёт пару «текст и параметры»
под PostgreSQL, MySQL либо SQL самого Tarantool, а в базу ходит драйвер.
Значение всегда уходит параметром, имя столбца — только из белого списка
объявленной таблицы.

```lua
local sql = require('tnt.sql')

local users = sql.table('users', { 'id', 'name', 'email', 'votes' })   -- белый список столбцов

local query = users:select('id', 'name'):where('votes', '>', 100):order_by('name', 'desc'):limit(10)

query:build('postgres')
--> 'select "id", "name" from "users" where "votes" > $1::int8 order by "name" desc limit 10', { n = 1, 100 }
query:build('mysql')
--> 'select `id`, `name` from `users` where `votes` > ? order by `name` desc limit 10', { n = 1, 100 }
```

Зависимости: `tnt-must` (проверки аргументов и тексты отказов),
`tnt-collection` (столбцы строки по порядку имён) и `tnt-storage`
(кодирование значений параметров и отказ `TntStorageFailure`). Настроек
и состояния у пакета нет.

## Зачем

Запрос, склеенный из строк, — это место, где значение становится
текстом, а имя из адресной строки — именем столбца. Пакет делает для
этого три вещи:

- **Значение — всегда параметр.** Внедрению SQL взяться неоткуда,
  а `int64`, `decimal`, `uuid`, время и JSON кодируются тем же правилом,
  что и у драйвера, и доезжают до сервера без потерь.
- **Имя — только из белого списка.** Столбец, которого нет в объявлении
  таблицы, в текст не попадёт, откуда бы ни пришло имя: фильтр
  `filter[password_hash][prefix]=a` не станет способом подобрать хеш.
- **Один построитель на три диалекта.** Знак параметра, кавычка имени,
  `returning`, `upsert` и `seqscan` у каждого свои; запрос собирается
  один раз и под любой из них.

## Установка

```sh
tt rocks install tnt-sql --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-sql.git
cd tnt-sql && tt rocks make
```

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `sql.table(name, columns)` | объявление таблицы — белый список столбцов |
| `T:as(alias)` | та же таблица под псевдонимом — для выборки |
| `T:select(...)` | выборка: `join`, `left_join`, `where`, `or_where`, `filter`, `group_by`, `having`, `order_by`, `sort`, `limit`, `offset`, `page`, `distinct`, `seqscan` |
| `T:insert(rows)` | вставка строки либо списка строк |
| `T:upsert(rows, unique_by, update)` | вставка с обновлением на конфликте |
| `T:update(values)`, `T:delete()` | правка и удаление; без условия — только `everything()` |
| `sql.raw(text, ...)` | текст руками со знаками `?` — целый запрос либо кусок другого |
| `sql.column(name)` | столбец там, где ждут значение |
| `query:build(dialect)` | текст и параметры: `postgres`, `mysql` либо `tarantool` |

Пара уходит драйверу как есть; для SQL Tarantool — прямо в `box.execute`:

```lua
local text, params = users:insert({ id = 1, name = 'a', email = box.NULL, votes = 3 }):build('tarantool')
--> 'insert into "users" ("email", "id", "name", "votes") values (?, ?, ?, ?)', { n = 4, box.NULL, 1, 'a', 3 }

box.execute(text, params)
```

Условия, порядок и страница, разобранные из адресной строки, идут
данными, а имя поля ещё раз проходит белый список таблицы:

```lua
users:select('id'):filter({ { field = 'password_hash', op = 'prefix', value = 'a' } }):build('postgres')
--> error: where: столбца «password_hash» нет в белом списке users (id, name, email, votes)
```

Отказ данных — пара `nil, err`: строка с нулевым байтом у PostgreSQL
(`TntStorageFailure` рода `rejected`, `sent = false`). Незнакомый столбец,
оператор, диалект, `update` без условия — исключение на строке
вызывающего.

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (104 проверки,
792 мутанта в десяти модулях). Пакет ничего не выполняет и проверяется
без базы: тексты и параметры сверяются целиком и дословно на всех трёх
диалектах, каждый бросок — с текстом и строкой вызывающего, каждый
пример документа — отдельной проверкой.

## Документ

Полное описание с обоснованием решений: [docs/sql.md](docs/sql.md).

## Лицензия

MIT.
