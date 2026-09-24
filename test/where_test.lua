--- Проверки условий: операторы, группы, текст руками, столбец справа,
--- кусок строки буквально, условия, разобранные из адреса, и отказы.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local built = helper.built
local wrong = helper.wrong

local g = t.group('tnt.sql.where')

--- Таблицы объявляются в before_all, а не при загрузке файла: почему —
--- в шапке помощника.
---@type TntSqlTable
local users

g.before_all(function()
    users = sql.table('users', { 'id', 'name', 'email', 'votes', 'created_at', 'updated_at' })
end)

--- Выборка одного столбца: условия видны без лишнего.
---@return TntSqlSelect
local function ids()
    return users:select('id')
end

g.test_comparisons_go_as_parameters = function()
    local cases = {
        { '=', 'select "id" from "users" where "votes" = $1::int8' },
        { '<>', 'select "id" from "users" where "votes" <> $1::int8' },
        { '<', 'select "id" from "users" where "votes" < $1::int8' },
        { '<=', 'select "id" from "users" where "votes" <= $1::int8' },
        { '>', 'select "id" from "users" where "votes" > $1::int8' },
        { '>=', 'select "id" from "users" where "votes" >= $1::int8' },
        { 'like', 'select "id" from "users" where "votes" like $1::int8' },
        { 'not like', 'select "id" from "users" where "votes" not like $1::int8' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(built(ids():where('votes', case[1], 7), 'postgres'), { case[2], { n = 1, 7 } }, case[1])
    end
end

g.test_conditions_join_with_and_and_or = function()
    local query = ids():where('votes', '>', 1):or_where('name', '=', 'a'):where('email', 'is not null')

    t.assert_equals(built(query, 'mysql'), {
        'select `id` from `users` where `votes` > ? or `name` = ? and `email` is not null',
        { n = 2, 1, 'a' },
    })
end

g.test_the_first_or_is_a_plain_condition = function()
    t.assert_equals(built(ids():or_where('votes', '=', 1), 'mysql'), {
        'select `id` from `users` where `votes` = ?',
        { n = 1, 1 },
    })
end

g.test_null_checks_take_no_value = function()
    t.assert_equals(built(ids():where('email', 'is null'), 'tarantool'), {
        'select "id" from "users" where "email" is null',
        { n = 0 },
    })
    t.assert_equals(built(ids():where('email', 'is not null', nil):or_where('name', 'is null', box.NULL), 'mysql'), {
        'select `id` from `users` where `email` is not null or `name` is null',
        { n = 0 },
    })
    helper.assert_blamed({
        {
            function()
                ids():where('email', 'is null', 'x')
            end,
            'where: у «is null» значения нет, а пришло «x»',
        },
        {
            function()
                ids():where('email', 'is not null', 0)
            end,
            'where: у «is not null» значения нет, а пришло 0',
        },
    })
end

g.test_a_comparison_with_null_is_refused = function()
    helper.assert_blamed({
        {
            function()
                ids():where('email', '=', nil)
            end,
            'where: сравнение с NULL не бывает истинным — пишите «is null» либо «is not null»',
        },
        {
            function()
                ids():where('email', '<>', box.NULL)
            end,
            'where: сравнение с NULL не бывает истинным — пишите «is null» либо «is not null»',
        },
        {
            function()
                ids():where('email', '=')
            end,
            'where: сравнение с NULL не бывает истинным — пишите «is null» либо «is not null»',
        },
    })
end

g.test_lists_go_as_parameters_one_by_one = function()
    t.assert_equals(built(ids():where('id', 'in', { 1, 2, 3 }), 'postgres'), {
        'select "id" from "users" where "id" in ($1::int8, $2::int8, $3::int8)',
        { n = 3, 1, 2, 3 },
    })
    t.assert_equals(built(ids():where('id', 'not in', { 4 }), 'mysql'), {
        'select `id` from `users` where `id` not in (?)',
        { n = 1, 4 },
    })
end

g.test_an_empty_list_is_false_for_in_and_true_for_not_in = function()
    t.assert_equals(built(ids():where('id', 'in', {}), 'tarantool'), {
        'select "id" from "users" where 1 = 0',
        { n = 0 },
    })
    t.assert_equals(built(ids():where('id', 'not in', {}), 'tarantool'), {
        'select "id" from "users" where 1 = 1',
        { n = 0 },
    })
end

g.test_a_list_is_copied_at_the_call = function()
    ---@type integer[]
    local wanted = { 1, 2 }
    local query = ids():where('id', 'in', wanted)

    wanted[3] = 3

    t.assert_equals(built(query, 'mysql'), { 'select `id` from `users` where `id` in (?, ?)', { n = 2, 1, 2 } })
end

g.test_bad_lists_are_refused = function()
    helper.assert_blamed({
        {
            function()
                ids():where('id', 'in', wrong(5))
            end,
            'where: значения in — массив, а не число',
        },
        {
            function()
                ids():where('id', 'not in', { 1, box.NULL })
            end,
            'where: значения not in — массив, а не таблица с дырой на месте 2',
        },
        {
            function()
                ids():where('id', 'between', { 1 })
            end,
            'where: у between два значения, а пришло 1',
        },
        {
            function()
                ids():where('id', 'not between', { 1, 2, 3 })
            end,
            'where: у not between два значения, а пришло 3',
        },
    })
end

g.test_between_takes_a_pair = function()
    t.assert_equals(built(ids():where('votes', 'between', { 1, 5 }), 'postgres'), {
        'select "id" from "users" where "votes" between $1::int8 and $2::int8',
        { n = 2, 1, 5 },
    })
    t.assert_equals(built(ids():where('votes', 'not between', { 1, 5 }), 'mysql'), {
        'select `id` from `users` where `votes` not between ? and ?',
        { n = 2, 1, 5 },
    })
end

g.test_a_piece_of_a_string_is_literal = function()
    t.assert_equals(built(ids():where('name', 'prefix', 'a_b%c!d'), 'postgres'), {
        [[select "id" from "users" where "name" like $1 escape '!']],
        { n = 1, 'a!_b!%c!!d%' },
    })
    t.assert_equals(built(ids():where('name', 'contains', '50%'), 'mysql'), {
        [[select `id` from `users` where `name` like ? escape '!']],
        { n = 1, '%50!%%' },
    })
    t.assert_equals(built(ids():where('name', 'contains', ''), 'tarantool'), {
        [[select "id" from "users" where "name" like ? escape '!']],
        { n = 1, '%%' },
    })
    helper.assert_blamed({
        {
            function()
                ids():where('name', 'prefix', wrong(5))
            end,
            'where: кусок строки у prefix — строка, а не 5',
        },
    })
end

g.test_groups_go_in_parentheses = function()
    local query = ids()
        :where('votes', '>', 1)
        :where(function(group)
            group:where('name', '=', 'a'):or_where('name', '=', 'b')
        end)
        :or_where(function(group)
            group:where('email', 'is null'):where(function(inner)
                inner:where('id', '=', 1)
            end)
        end)

    t.assert_equals(built(query, 'postgres'), {
        'select "id" from "users" where "votes" > $1::int8 and ("name" = $2 or "name" = $3)'
            .. ' or ("email" is null and ("id" = $4::int8))',
        { n = 4, 1, 'a', 'b', 1 },
    })
end

g.test_an_empty_group_is_no_condition = function()
    local query = ids():where(function() end):where('id', '=', 1)

    t.assert_equals(built(query, 'mysql'), { 'select `id` from `users` where `id` = ?', { n = 1, 1 } })
    t.assert_equals(built(ids():where(function() end), 'mysql'), { 'select `id` from `users`', { n = 0 } })
end

g.test_raw_text_is_a_condition_a_subject_and_a_value = function()
    local query = ids()
        :where(sql.raw('lower(?) = ?', sql.column('name'), 'a'))
        :where(sql.raw('length(?)', sql.column('email')), '>', 3)
        :where('created_at', '<', sql.raw('now() - ?::interval', '1 day'))

    t.assert_equals(built(query, 'postgres'), {
        'select "id" from "users" where lower("name") = $1 and length("email") > $2::int8'
            .. ' and "created_at" < now() - $3::interval',
        { n = 3, 'a', 3, '1 day' },
    })
end

g.test_a_column_on_the_right_is_a_name = function()
    local query = ids():where('updated_at', '>', sql.column('created_at'))

    t.assert_equals(built(query, 'mysql'), { 'select `id` from `users` where `updated_at` > `created_at`', { n = 0 } })
end

g.test_a_fourth_argument_is_refused = function()
    helper.assert_blamed({
        {
            function()
                ids():where('id', '=', 1, 'or')
            end,
            'where: аргументов 4, а условие — столбец, оператор и значение; «или» пишут or_where',
        },
        {
            function()
                ids():or_where(sql.raw('x'), '=', 1, nil)
            end,
            'where: аргументов 4, а условие — столбец, оператор и значение; «или» пишут or_where',
        },
    })
    t.assert_equals(
        built(ids():where('id', '=', 1), 'mysql'),
        { 'select `id` from `users` where `id` = ?', { n = 1, 1 } }
    )
end

g.test_an_unknown_operator_is_refused_whatever_it_carries = function()
    helper.assert_blamed({
        {
            function()
                ids():where('id', '= 1 or 1 =', 1)
            end,
            'where: оператор «= 1 or 1 =» незнаком: есть =, <>, <, <=, >, >=, in, not in, between, not between,'
                .. ' like, not like, prefix, contains, is null, is not null',
        },
        {
            function()
                ids():where('id', 'John')
            end,
            'where: оператор «John» незнаком: есть =, <>, <, <=, >, >=, in, not in, between, not between,'
                .. ' like, not like, prefix, contains, is null, is not null',
        },
        {
            function()
                ids():or_where('id', wrong(nil), 1)
            end,
            'where: оператор nil незнаком: есть =, <>, <, <=, >, >=, in, not in, between, not between,'
                .. ' like, not like, prefix, contains, is null, is not null',
        },
    })
end

g.test_a_bad_column_is_refused_at_the_call = function()
    helper.assert_blamed({
        {
            function()
                ids():where('name; drop table users', '=', 1)
            end,
            'where: столбец — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов,'
                .. ' а не «name; drop table users»',
        },
        {
            function()
                ids():or_where(wrong(5), '=', 1)
            end,
            'where: столбец — имя столбца строкой, а не 5',
        },
        {
            function()
                ids():where('name as n', '=', 1)
            end,
            'where: столбец: псевдоним ставят только в списке select, а не «name as n»',
        },
    })
end

g.test_filter_takes_the_conditions_parsed_from_the_address = function()
    local query = ids():filter({
        { field = 'email', op = 'eq', value = 'a@b' },
        { field = 'email', op = 'ne', value = 'c@d' },
        { field = 'votes', op = 'gt', value = 1 },
        { field = 'votes', op = 'gte', value = 2 },
        { field = 'votes', op = 'lt', value = 9 },
        { field = 'votes', op = 'lte', value = 8 },
        { field = 'id', op = 'in', value = { 5, 6 } },
        { field = 'name', op = 'prefix', value = 'st_' },
        { field = 'name', op = 'contains', value = 'x' },
    })

    t.assert_equals(built(query, 'postgres'), {
        'select "id" from "users" where "email" = $1 and "email" <> $2 and "votes" > $3::int8'
            .. ' and "votes" >= $4::int8 and "votes" < $5::int8 and "votes" <= $6::int8'
            .. ' and "id" in ($7::int8, $8::int8)'
            .. [[ and "name" like $9 escape '!' and "name" like $10 escape '!']],
        { n = 10, 'a@b', 'c@d', 1, 2, 9, 8, 5, 6, 'st!_%', '%x%' },
    })
end

g.test_an_empty_filter_sets_no_condition = function()
    t.assert_equals(built(ids():filter({}), 'mysql'), { 'select `id` from `users`', { n = 0 } })
end

g.test_bad_filters_are_refused = function()
    helper.assert_blamed({
        {
            function()
                ids():filter(wrong('state=dead'))
            end,
            'filter: условия — массив, а не строка',
        },
        {
            function()
                ids():filter({ wrong('state') })
            end,
            'filter[1] — таблица, а не строка',
        },
        {
            function()
                ids():filter({ { field = 'id', op = 'eq', value = 1 }, { field = 'id', op = '=', value = 1 } })
            end,
            'filter[2]: оператор «=» незнаком: есть eq, ne, gt, gte, lt, lte, in, prefix, contains',
        },
        {
            function()
                ids():filter({ { field = 'id; --', op = 'eq', value = 1 } })
            end,
            'filter[1]: столбец — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «id; --»',
        },
        {
            function()
                ids():filter({ { field = 'id', op = 'in', value = 1 } })
            end,
            'filter[1]: значения in — массив, а не число',
        },
    })
end

g.test_a_filter_field_goes_through_the_white_list = function()
    local query = ids():filter({ { field = 'password', op = 'prefix', value = 'a' } })

    helper.assert_blamed({
        {
            function()
                query:build('postgres')
            end,
            'where: столбца «password» нет в белом списке users (id, name, email, votes, created_at, updated_at)',
        },
    })
end
