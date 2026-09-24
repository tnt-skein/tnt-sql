rockspec_format = '3.0'

package = 'tnt-sql'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-sql.git',
    branch = 'main',
}

description = {
    summary = 'Построитель запросов: текст и параметры под PostgreSQL, MySQL и SQL Tarantool',
    detailed = [[
        Построитель, который ничего не выполняет: build отдаёт пару
        «текст и параметры», а в базу ходит драйвер. Значение
        не склеивается с текстом никогда — оно уходит параметром,
        закодированное так же, как его кодирует драйвер, и внедрению SQL
        взяться неоткуда. Диалекты postgres ($1, приведение $1::int8,
        returning, on conflict), mysql (?, on duplicate key update)
        и tarantool (?, seqscan для box.execute).

        Имя столбца обязано стоять в белом списке объявленной таблицы,
        а форма имени — латиница, цифры и _: фильтр из адресной строки
        не станет ни способом прочитать чужой столбец, ни текстом запроса.
        Выборка с join, group by, having, order by, limit и offset;
        insert, upsert, update и delete, причём правка и удаление без
        условия отказывают, пока всю таблицу не назвали явно. Условия,
        порядок и страница, разобранные из адресной строки, принимаются
        данными. Текст руками — со сверкой числа знаков и одним оператором
        на вызов.

        Отказ данных — пара nil, err: строка с нулевым байтом у PostgreSQL.
        Незнакомый столбец, оператор или диалект — исключение на строке
        вызывающего. Настроек и состояния у пакета нет.

        Зависит от tnt-must (проверки аргументов и тексты отказов),
        tnt-collection (столбцы строки по порядку имён) и tnt-storage
        (кодирование значений параметров и отказ TntStorageFailure).
        Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-sql',
    issues_url = 'https://github.com/tnt-skein/tnt-sql/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'sql', 'query-builder', 'postgresql', 'mysql', 'database' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки аргументов на строке вызывающего и бросок отказа сборки без места.
    'tnt-must',
    -- Столбцы строки и правки по порядку имён, строка или список строк.
    'tnt-collection',
    -- Значения параметров кодируются так же, как их кодирует драйвер.
    'tnt-storage',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.sql'] = 'tnt/sql.lua',
        ['tnt.sql.change'] = 'tnt/sql/change.lua',
        ['tnt.sql.context'] = 'tnt/sql/context.lua',
        ['tnt.sql.dialect'] = 'tnt/sql/dialect.lua',
        ['tnt.sql.insert'] = 'tnt/sql/insert.lua',
        ['tnt.sql.kinds'] = 'tnt/sql/kinds.lua',
        ['tnt.sql.names'] = 'tnt/sql/names.lua',
        ['tnt.sql.raw'] = 'tnt/sql/raw.lua',
        ['tnt.sql.select'] = 'tnt/sql/select.lua',
        ['tnt.sql.table'] = 'tnt/sql/table.lua',
        ['tnt.sql.where'] = 'tnt/sql/where.lua',
    },
}
