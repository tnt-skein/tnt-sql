--- Проверки сборки: диалект именем и таблицей драйвера, отказ данных
--- парой, броски значений и белого списка на строке того, кто позвал build.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local built = helper.built

local g = t.group('tnt.sql.build')

--- Таблицы объявляются в before_all, а не при загрузке файла: почему —
--- в шапке помощника.
---@type TntSqlTable
local users

g.before_all(function()
    users = sql.table('users', { 'id', 'name' })
end)

g.test_a_dialect_is_a_name_or_a_table_of_the_driver = function()
    local query = users:select('id'):where('name', '=', 'a')

    t.assert_equals(built(query, { name = 'postgres', placeholder = '?', quote = '`' }), {
        'select "id" from "users" where "name" = $1',
        { n = 1, 'a' },
    })
    t.assert_equals(built(query, { name = 'mysql' }), { 'select `id` from `users` where `name` = ?', { n = 1, 'a' } })
end

g.test_an_unknown_dialect_is_refused_on_the_line_of_build = function()
    local query = users:select('id')

    helper.assert_blamed({
        {
            function()
                query:build('sqlite')
            end,
            'диалект sqlite незнаком: есть postgres, mysql, tarantool',
        },
        {
            function()
                query:build({ name = 'oracle' })
            end,
            'диалект oracle незнаком: есть postgres, mysql, tarantool',
        },
        {
            function()
                query:build(nil)
            end,
            'диалект nil незнаком: есть postgres, mysql, tarantool',
        },
        {
            function()
                sql.raw('select 1'):build('mssql')
            end,
            'диалект mssql незнаком: есть postgres, mysql, tarantool',
        },
    })
end

g.test_parameters_are_numbered_across_the_whole_statement = function()
    local query = users
        :select('id', sql.raw('? as tag', 't'))
        :where('id', 'in', { 1, 2 })
        :where(sql.raw('? = ?', 3, 4))
        :order_by(sql.raw('coalesce(?, ?)', sql.column('name'), 'z'))

    t.assert_equals(built(query, 'postgres'), {
        'select "id", $1 as tag from "users" where "id" in ($2::int8, $3::int8) and $4::int8 = $5::int8'
            .. ' order by coalesce("name", $6) asc',
        { n = 6, 't', 1, 2, 3, 4, 'z' },
    })
end

g.test_a_zero_byte_for_postgres_is_a_refusal_not_an_exception = function()
    local query = users:select('id'):where('name', '=', 'a\0b'):where('id', '=', 1)
    local text, err = query:build('postgres')

    t.assert_equals(text, nil)
    t.assert_equals({ err.kind, err.sent, err.retriable, err.message }, {
        'rejected',
        false,
        false,
        'строка с нулевым байтом: pg обрезал бы её молча',
    })
    t.assert_equals(built(query, 'mysql'), {
        'select `id` from `users` where `name` = ? and `id` = ?',
        { n = 2, 'a\0b', 1 },
    })
end

g.test_a_value_that_cannot_be_passed_is_refused_on_the_line_of_build = function()
    local tabled = users:select('id'):where('name', '=', { 1 })
    local huge = users:insert({ id = 2 ^ 60 })

    helper.assert_blamed({
        {
            function()
                tabled:build('postgres')
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                huge:build('mysql')
            end,
            'число 1.1529215046068e+18 за пределом ±2^53: целые там неточны — передайте int64 либо decimal',
        },
    })
end

g.test_a_column_reference_in_a_standalone_raw_text_has_no_table = function()
    local bare = sql.raw('select ?', sql.column('id'))
    local qualified = sql.raw('select ?', sql.column('users.id'))

    helper.assert_blamed({
        {
            function()
                bare:build('postgres')
            end,
            'sql.column: у текста руками таблиц нет — имя «id» пишут в самом тексте',
        },
        {
            function()
                qualified:build('mysql')
            end,
            'sql.column: у текста руками таблиц нет — имя «id» пишут в самом тексте',
        },
    })
end

g.test_a_statement_builds_again_the_same = function()
    local query = users:select('id'):where('name', '=', 'a')

    t.assert_equals(built(query, 'postgres'), built(query, 'postgres'))
    t.assert_equals(built(query, 'tarantool'), { 'select "id" from "users" where "name" = ?', { n = 1, 'a' } })
end
