--- Проверки записи: вставка строки и списка, upsert по диалектам, правка
--- и удаление с условием и без, returning.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local built = helper.built
local wrong = helper.wrong

local g = t.group('tnt.sql.write')

--- Таблицы объявляются в before_all, а не при загрузке файла: почему —
--- в шапке помощника.
---@type TntSqlTable
local users

g.before_all(function()
    users = sql.table('users', { 'id', 'name', 'votes' })
end)

g.test_a_row_is_inserted_with_columns_in_name_order = function()
    local query = users:insert({ votes = 3, name = 'a', id = 1 })

    t.assert_equals(built(query, 'postgres'), {
        'insert into "users" ("id", "name", "votes") values ($1::int8, $2, $3::int8)',
        { n = 3, 1, 'a', 3 },
    })
    t.assert_equals(built(query, 'mysql'), {
        'insert into `users` (`id`, `name`, `votes`) values (?, ?, ?)',
        { n = 3, 1, 'a', 3 },
    })
end

g.test_a_list_of_rows_is_one_statement = function()
    local query = users:insert({ { id = 1, name = 'a' }, { name = box.NULL, id = 2 } })

    t.assert_equals(built(query, 'tarantool'), {
        'insert into "users" ("id", "name") values (?, ?), (?, ?)',
        { n = 4, 1, 'a', 2, box.NULL },
    })
end

g.test_values_are_encoded_like_the_driver_does = function()
    local query = users:insert({ id = 9007199254740993LL, name = helper.storage.json({ a = 1 }), votes = 1 })

    t.assert_equals(built(query, 'postgres'), {
        'insert into "users" ("id", "name", "votes") values ($1::int8, $2::jsonb, $3::int8)',
        { n = 3, '9007199254740993', '{"a":1}', 1 },
    })
    t.assert_equals(built(query, 'mysql'), {
        'insert into `users` (`id`, `name`, `votes`) values (?, ?, ?)',
        { n = 3, '9007199254740993', '{"a":1}', 1 },
    })
end

g.test_a_raw_value_goes_into_the_text = function()
    local query = users:insert({ id = 1, name = sql.raw('upper(?)', 'a') })

    t.assert_equals(built(query, 'postgres'), {
        'insert into "users" ("id", "name") values ($1::int8, upper($2))',
        { n = 2, 1, 'a' },
    })
end

g.test_bad_rows_are_refused_at_the_call = function()
    helper.assert_blamed({
        {
            function()
                users:insert(wrong('row'))
            end,
            'insert: строки — таблица, а не строка',
        },
        {
            function()
                users:insert({})
            end,
            'insert: строк нет — вставлять нечего',
        },
        {
            function()
                users:insert({ { id = 1 }, {} })
            end,
            'insert: строка №2 пуста — вставлять нечего',
        },
        {
            function()
                users:insert({ { id = 1 }, wrong(2) })
            end,
            'insert: строка №2 — таблица, а не число',
        },
        {
            function()
                users:insert({ { id = 1, name = 'a' }, { id = 2, votes = 1 } })
            end,
            'insert: у строки №2 столбцы id, votes, а у первой id, name',
        },
        {
            function()
                users:insert({ ['name; --'] = 1 })
            end,
            'insert: столбец — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «name; --»',
        },
    })
end

g.test_inserted_columns_go_through_the_white_list = function()
    local query = users:insert({ id = 1, password = 'x' })

    helper.assert_blamed({
        {
            function()
                query:build('mysql')
            end,
            'insert: столбца «password» нет в белом списке users (id, name, votes)',
        },
    })
end

g.test_upsert_by_dialect = function()
    local query = users:upsert({ { id = 1, name = 'a', votes = 1 }, { id = 2, name = 'b', votes = 2 } }, { 'id' })

    t.assert_equals(built(query, 'postgres'), {
        'insert into "users" ("id", "name", "votes") values ($1::int8, $2, $3::int8), ($4::int8, $5, $6::int8)'
            .. ' on conflict ("id") do update set "name" = "excluded"."name", "votes" = "excluded"."votes"',
        { n = 6, 1, 'a', 1, 2, 'b', 2 },
    })
    t.assert_equals(built(query, 'mysql'), {
        'insert into `users` (`id`, `name`, `votes`) values (?, ?, ?), (?, ?, ?)'
            .. ' as `excluded` on duplicate key update `name` = `excluded`.`name`, `votes` = `excluded`.`votes`',
        { n = 6, 1, 'a', 1, 2, 'b', 2 },
    })
    helper.assert_blamed({
        {
            function()
                query:build('tarantool')
            end,
            'upsert: в SQL tarantool нет on conflict, а insert or replace стёр бы столбцы, которых нет в строке',
        },
    })
end

g.test_upsert_updates_only_what_it_is_told = function()
    local query = users:upsert({ id = 1, name = 'a', votes = 1 }, { 'id', 'name' }, { 'votes' })

    t.assert_equals(built(query, 'postgres'), {
        'insert into "users" ("id", "name", "votes") values ($1::int8, $2, $3::int8)'
            .. ' on conflict ("id", "name") do update set "votes" = "excluded"."votes"',
        { n = 3, 1, 'a', 1 },
    })
end

g.test_bad_upserts_are_refused_at_the_call = function()
    helper.assert_blamed({
        {
            function()
                users:upsert({ id = 1, name = 'a' }, wrong('id'))
            end,
            'upsert: unique_by — массив, а не строка',
        },
        {
            function()
                users:upsert({ id = 1, name = 'a' }, { 'votes' })
            end,
            'upsert: unique_by[1]: столбца «votes» среди вставленных нет',
        },
        {
            function()
                users:upsert({ id = 1, name = 'a' }, { 'id' }, { 'name', 'id x' })
            end,
            'upsert: update[2] — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «id x»',
        },
        {
            function()
                users:upsert({ id = 1 }, { 'id' })
            end,
            'upsert: обновлять нечего — все столбцы в unique_by; вставка без обновления — не upsert',
        },
        {
            function()
                users:upsert({ id = 1, name = 'a' }, { 'id' }, {})
            end,
            'upsert: обновлять нечего — все столбцы в unique_by; вставка без обновления — не upsert',
        },
    })
end

g.test_update_sets_columns_in_name_order_before_the_conditions = function()
    local query = users:update({ votes = sql.raw('? + 1', sql.column('votes')), name = box.NULL }):where('id', '=', 7)

    t.assert_equals(built(query, 'postgres'), {
        'update "users" set "name" = $1, "votes" = "votes" + 1 where "id" = $2::int8',
        { n = 2, box.NULL, 7 },
    })
    t.assert_equals(built(query, 'mysql'), {
        'update `users` set `name` = ?, `votes` = `votes` + 1 where `id` = ?',
        { n = 2, box.NULL, 7 },
    })
end

g.test_delete_takes_conditions = function()
    local query = users:delete():where('votes', '<', 1):or_where('name', 'is null')

    t.assert_equals(built(query, 'tarantool'), {
        'delete from "users" where "votes" < ? or "name" is null',
        { n = 1, 1 },
    })
end

g.test_a_change_without_conditions_needs_everything = function()
    local update = users:update({ votes = 0 })
    local delete = users:delete():filter({})

    helper.assert_blamed({
        {
            function()
                update:build('postgres')
            end,
            'update без where меняет всю таблицу — если так и задумано, скажите everything()',
        },
        {
            function()
                delete:build('mysql')
            end,
            'delete без where меняет всю таблицу — если так и задумано, скажите everything()',
        },
    })
    t.assert_equals(built(update:everything(), 'postgres'), { 'update "users" set "votes" = $1::int8', { n = 1, 0 } })
    t.assert_equals(built(delete:everything(), 'mysql'), { 'delete from `users`', { n = 0 } })
    t.assert_equals(built(users:delete():everything():where('id', '=', 1), 'mysql'), {
        'delete from `users` where `id` = ?',
        { n = 1, 1 },
    })
end

g.test_bad_updates_are_refused_at_the_call = function()
    helper.assert_blamed({
        {
            function()
                users:update(wrong('votes = 0'))
            end,
            'update: значения — таблица, а не строка',
        },
        {
            function()
                users:update({})
            end,
            'update: значений нет — править нечего',
        },
        {
            function()
                users:update({ [1] = 'x' })
            end,
            'update: столбец — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не 1',
        },
    })
end

g.test_updated_columns_go_through_the_white_list = function()
    local query = users:update({ password = 'x' }):where('id', '=', 1)

    helper.assert_blamed({
        {
            function()
                query:build('tarantool')
            end,
            'update: столбца «password» нет в белом списке users (id, name, votes)',
        },
    })
end

g.test_returning_is_only_for_postgres = function()
    local insert = users:insert({ name = 'a' }):returning('id', 'users.name')
    local update = users:update({ votes = 1 }):where('id', '=', 1):returning('votes')
    local delete = users:delete():where('id', '=', 1):returning('id')

    t.assert_equals(built(insert, 'postgres'), {
        'insert into "users" ("name") values ($1) returning "id", "users"."name"',
        { n = 1, 'a' },
    })
    t.assert_equals(built(update, 'postgres'), {
        'update "users" set "votes" = $1::int8 where "id" = $2::int8 returning "votes"',
        { n = 2, 1, 1 },
    })
    t.assert_equals(built(delete, 'postgres'), {
        'delete from "users" where "id" = $1::int8 returning "id"',
        { n = 1, 1 },
    })
    helper.assert_blamed({
        {
            function()
                insert:build('mysql')
            end,
            'returning есть только у postgres, а не у mysql',
        },
        {
            function()
                delete:build('tarantool')
            end,
            'returning есть только у postgres, а не у tarantool',
        },
        {
            function()
                users:insert({ name = 'a' }):returning('id', wrong(1))
            end,
            'returning: столбец — имя столбца строкой, а не 1',
        },
        {
            function()
                users:delete():returning('id as x')
            end,
            'returning: столбец: псевдоним ставят только в списке select, а не «id as x»',
        },
    })
end

g.test_returned_columns_go_through_the_white_list = function()
    local query = users:delete():where('id', '=', 1):returning('password')

    helper.assert_blamed({
        {
            function()
                query:build('postgres')
            end,
            'returning: столбца «password» нет в белом списке users (id, name, votes)',
        },
    })
end
