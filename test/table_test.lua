--- Проверки объявления таблицы, имён и фасада: белый список собирается
--- один раз, негодное имя не проходит ни в объявлении, ни в ссылке.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local built = helper.built
local wrong = helper.wrong

local g = t.group('tnt.sql.table')

--- Негодные имена: пусто, цифра впереди, пробел, кавычки, точка с запятой,
--- кириллица, длиннее 63 байтов.
local BAD_NAMES = {
    '',
    '1id',
    'user id',
    'id"',
    'id`',
    "id'",
    'id;drop',
    'имя',
    ('a'):rep(64),
}

g.test_the_facade_names_the_dialects_and_the_operators = function()
    t.assert_equals({ sql.POSTGRES, sql.MYSQL, sql.TARANTOOL }, { 'postgres', 'mysql', 'tarantool' })
    t.assert_equals(
        table.concat(sql.OPERATORS, ', '),
        '=, <>, <, <=, >, >=, in, not in, between, not between, like, not like, prefix, contains, is null, is not null'
    )
end

g.test_a_table_keeps_its_columns_in_the_declared_order = function()
    local users = sql.table('users', { 'id', 'name', 'email' })

    t.assert_equals(users.name, 'users')
    t.assert_equals(users.columns, { 'id', 'name', 'email' })
    t.assert_equals(users.known, { id = true, name = true, email = true })
    t.assert_equals(users.alias, nil)
end

g.test_a_table_copies_its_columns = function()
    ---@type string[]
    local columns = { 'id', 'name' }
    local users = sql.table('users', columns)

    columns[3] = 'password'

    t.assert_equals(users.columns, { 'id', 'name' })
    t.assert_equals(built(users:select(), 'mysql'), { 'select `id`, `name` from `users`', { n = 0 } })
end

g.test_the_longest_name_is_63_bytes = function()
    local long = ('a'):rep(63)
    local declared = sql.table(long, { long })

    t.assert_equals(declared.name, long)
    t.assert_equals(built(declared:select(), 'mysql'), {
        ('select `%s` from `%s`'):format(long, long),
        { n = 0 },
    })
end

g.test_underscores_and_digits_make_a_name = function()
    local declared = sql.table('_t1', { '_a', 'b_2', 'Camel' })

    t.assert_equals(built(declared:select(), 'postgres'), { 'select "_a", "b_2", "Camel" from "_t1"', { n = 0 } })
end

g.test_a_bad_table_name_is_refused_on_the_caller_line = function()
    for _, name in ipairs(BAD_NAMES) do
        local ok, err = pcall(sql.table, name, { 'id' })

        t.assert_not(ok, name)
        t.assert_str_contains(
            tostring(err),
            'sql.table: имя таблицы — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «',
            false,
            name
        )
    end

    helper.assert_blamed({
        {
            function()
                sql.table(wrong(5), { 'id' })
            end,
            'sql.table: имя таблицы — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не 5',
        },
    })
end

g.test_bad_columns_are_refused_on_the_caller_line = function()
    helper.assert_blamed({
        {
            function()
                sql.table('users', wrong('id'))
            end,
            'sql.table: столбцы — массив, а не строка',
        },
        {
            function()
                sql.table('users', {})
            end,
            'sql.table: у таблицы users столбцов нет — белый список пуст',
        },
        {
            function()
                sql.table('users', { 'id', 'pass word' })
            end,
            'sql.table: столбец №2 — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «pass word»',
        },
        {
            function()
                sql.table('users', { 'id', 'name', 'id' })
            end,
            'sql.table: столбец id объявлен дважды',
        },
    })
end

g.test_an_alias_is_a_new_declaration_with_the_same_columns = function()
    local users = sql.table('users', { 'id', 'name' })
    local aliased = users:as('u')

    t.assert_equals({ aliased.name, aliased.alias, aliased.columns }, { 'users', 'u', { 'id', 'name' } })
    t.assert_equals(users.alias, nil)
    t.assert_equals(built(aliased:select('u.id'), 'postgres'), { 'select "u"."id" from "users" as "u"', { n = 0 } })
    helper.assert_blamed({
        {
            function()
                users:as('u 2')
            end,
            'as: псевдоним — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «u 2»',
        },
    })
end

g.test_a_column_reference_is_parsed_once = function()
    local column = sql.column('users.id')

    t.assert_equals(column.ref, { table = 'users', name = 'id' })
    t.assert_equals(sql.column('id').ref, { name = 'id' })
    helper.assert_blamed({
        {
            function()
                sql.column('users.id as uid')
            end,
            'sql.column: псевдоним ставят только в списке select, а не «users.id as uid»',
        },
        {
            function()
                sql.column(wrong(1))
            end,
            'sql.column — имя столбца строкой, а не 1',
        },
        {
            function()
                sql.column('a.b.c')
            end,
            'sql.column: таблица — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «a.b»',
        },
        {
            function()
                sql.column('users.')
            end,
            'sql.column — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «»',
        },
    })
end

g.test_writes_to_an_aliased_table_are_refused = function()
    local aliased = sql.table('users', { 'id' }):as('u')

    helper.assert_blamed({
        {
            function()
                aliased:insert({ id = 1 })
            end,
            'insert: у таблицы с псевдонимом вставки нет — псевдоним только для выборки',
        },
        {
            function()
                aliased:upsert({ id = 1 }, { 'id' })
            end,
            'insert: у таблицы с псевдонимом вставки нет — псевдоним только для выборки',
        },
        {
            function()
                aliased:update({ id = 1 })
            end,
            'update: у таблицы с псевдонимом правок нет — псевдоним только для выборки',
        },
        {
            function()
                aliased:delete()
            end,
            'delete: у таблицы с псевдонимом правок нет — псевдоним только для выборки',
        },
    })
end
