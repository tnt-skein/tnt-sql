--- Проверки выборки: столбцы и псевдонимы, соединения, группы, порядок,
--- предел и страница, разобранная из адреса, seqscan и отказы.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local built = helper.built
local wrong = helper.wrong

local g = t.group('tnt.sql.select')

--- Таблицы объявляются в before_all, а не при загрузке файла: почему —
--- в шапке помощника.
---@type TntSqlTable
local users
---@type TntSqlTable
local posts

g.before_all(function()
    users = sql.table('users', { 'id', 'name', 'votes' })
    posts = sql.table('posts', { 'id', 'user_id', 'title' })
end)

g.test_without_columns_the_declared_ones_are_selected = function()
    t.assert_equals(built(users:select(), 'postgres'), { 'select "id", "name", "votes" from "users"', { n = 0 } })
    t.assert_equals(built(users:select(), 'mysql'), { 'select `id`, `name`, `votes` from `users`', { n = 0 } })
    t.assert_equals(built(users:select(), 'tarantool'), { 'select "id", "name", "votes" from "users"', { n = 0 } })
end

g.test_named_columns_keep_their_order_and_aliases = function()
    local query = users:select('votes', 'users.name as title', sql.raw('count(*) as total'), 'id as uid')

    t.assert_equals(built(query, 'postgres'), {
        'select "votes", "users"."name" as "title", count(*) as total, "id" as "uid" from "users"',
        { n = 0 },
    })
end

g.test_a_raw_column_carries_its_values = function()
    local query = users:select('id', sql.raw('? as tag', 'x')):where('votes', '>', 1)

    t.assert_equals(built(query, 'postgres'), {
        'select "id", $1 as tag from "users" where "votes" > $2::int8',
        { n = 2, 'x', 1 },
    })
end

g.test_names_in_the_result_are_unique = function()
    helper.assert_blamed({
        {
            function()
                users:select('id', 'posts.id')
            end,
            'select: имя «id» в выборке дважды, и рок оставит одно — дайте псевдоним: posts.id as другое',
        },
        {
            function()
                users:select('name', 'votes as name')
            end,
            'select: имя «name» в выборке дважды, и рок оставит одно — дайте псевдоним: votes as name as другое',
        },
    })

    t.assert_equals(built(users:select('id', 'id as other'), 'mysql'), {
        'select `id`, `id` as `other` from `users`',
        { n = 0 },
    })
end

g.test_bad_columns_are_refused_at_the_call = function()
    helper.assert_blamed({
        {
            function()
                users:select('id', wrong(1))
            end,
            'select: столбец — имя столбца строкой, а не 1',
        },
        {
            function()
                users:select('id as 2x')
            end,
            'select: столбец: псевдоним — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «2x»',
        },
        {
            function()
                users:select('*')
            end,
            'select: столбец — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «*»',
        },
    })
end

g.test_distinct = function()
    t.assert_equals(built(users:select('votes'):distinct(), 'mysql'), {
        'select distinct `votes` from `users`',
        { n = 0 },
    })
end

g.test_joins_resolve_names_across_the_tables = function()
    local query = users
        :select('users.id', 'title', 'user_id')
        :join(posts, 'posts.user_id', '=', 'users.id')
        :where('title', 'prefix', 'a')

    t.assert_equals(built(query, 'postgres'), {
        'select "users"."id", "title", "user_id" from "users"'
            .. ' inner join "posts" on "posts"."user_id" = "users"."id"'
            .. [[ where "title" like $1 escape '!']],
        { n = 1, 'a%' },
    })
end

g.test_a_left_join_and_every_join_operator = function()
    for _, op in ipairs({ '=', '<>', '<', '<=', '>', '>=' }) do
        local query = users:select('name'):left_join(posts, 'user_id', op, 'users.id')

        t.assert_equals(built(query, 'mysql'), {
            ('select `name` from `users` left join `posts` on `user_id` %s `users`.`id`'):format(op),
            { n = 0 },
        }, op)
    end
end

g.test_without_columns_a_join_selects_the_first_table_qualified = function()
    local query = users:select():join(posts, 'posts.user_id', '=', 'users.id')

    t.assert_equals(built(query, 'tarantool'), {
        'select "users"."id", "users"."name", "users"."votes" from "users"'
            .. ' inner join "posts" on "posts"."user_id" = "users"."id"',
        { n = 0 },
    })
end

g.test_a_table_joins_itself_under_an_alias = function()
    local query = users:as('u'):select('u.id', 'boss.name as boss'):join(users:as('boss'), 'boss.id', '=', 'u.votes')

    t.assert_equals(built(query, 'postgres'), {
        'select "u"."id", "boss"."name" as "boss" from "users" as "u"'
            .. ' inner join "users" as "boss" on "boss"."id" = "u"."votes"',
        { n = 0 },
    })
end

g.test_bad_joins_are_refused_at_the_call = function()
    helper.assert_blamed({
        {
            function()
                users:select():join(wrong('posts'), 'user_id', '=', 'id')
            end,
            'join: таблица — объявление sql.table, а не «posts»',
        },
        {
            function()
                users:select():join(users, 'id', '=', 'id')
            end,
            'join: таблица users в запросе уже есть — дайте псевдоним: :as(…)',
        },
        {
            function()
                users:select():join(posts, 'user_id', '=', 'users.id'):left_join(posts, 'id', '=', 'id')
            end,
            'join: таблица posts в запросе уже есть — дайте псевдоним: :as(…)',
        },
        {
            function()
                users:select():left_join(posts, 'user_id', 'like', 'users.id')
            end,
            'join: оператор «like» незнаком: есть =, <>, <, <=, >, >=',
        },
        {
            function()
                users:select():join(posts, 'user id', '=', 'users.id')
            end,
            'join: столбец — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «user id»',
        },
        {
            function()
                users:select():left_join(posts, 'user_id', '=', wrong(1))
            end,
            'join: столбец — имя столбца строкой, а не 1',
        },
    })
end

g.test_names_are_checked_against_every_joined_table = function()
    local ambiguous = users:select('id'):join(posts, 'posts.user_id', '=', 'users.id')
    local missing = users:select('name'):join(posts, 'posts.user_id', '=', 'users.id'):where('email', '=', 'x')
    local foreign = users:select('name'):join(posts, 'posts.user_id', '=', 'users.id'):where('posts.name', '=', 'x')
    local stranger = users:select('name'):where('orders.id', '=', 1)

    helper.assert_blamed({
        {
            function()
                ambiguous:build('postgres')
            end,
            'select: столбец «id» есть у users и posts — назовите таблицу: users.id',
        },
        {
            function()
                missing:build('mysql')
            end,
            'where: столбца «email» нет в белом списке users (id, name, votes), posts (id, user_id, title)',
        },
        {
            function()
                foreign:build('tarantool')
            end,
            'where: столбца «posts.name» нет в белом списке posts (id, user_id, title)',
        },
        {
            function()
                stranger:build('postgres')
            end,
            'where: таблицы «orders» в запросе нет, есть users',
        },
    })
end

g.test_join_columns_go_through_the_white_list = function()
    local query = users:select('name'):join(posts, 'posts.author_id', '=', 'users.id')

    helper.assert_blamed({
        {
            function()
                query:build('postgres')
            end,
            'join: столбца «posts.author_id» нет в белом списке posts (id, user_id, title)',
        },
    })
end

g.test_group_by_and_having = function()
    local query = users
        :select('votes', sql.raw('count(*) as total'))
        :group_by('votes', sql.raw('lower(?)', sql.column('name')))
        :having(sql.raw('count(*)'), '>', 1)
        :having(function(group)
            group:where('votes', '<', 10):or_where('votes', 'is null')
        end)

    t.assert_equals(built(query, 'postgres'), {
        'select "votes", count(*) as total from "users" group by "votes", lower("name")'
            .. ' having count(*) > $1::int8 and ("votes" < $2::int8 or "votes" is null)',
        { n = 2, 1, 10 },
    })
    helper.assert_blamed({
        {
            function()
                users:select():group_by('votes', wrong(2))
            end,
            'group_by: столбец — имя столбца строкой, а не 2',
        },
        {
            function()
                users:select():having('votes', '!=', 1)
            end,
            'having: оператор «!=» незнаком: есть =, <>, <, <=, >, >=, in, not in, between, not between,'
                .. ' like, not like, prefix, contains, is null, is not null',
        },
    })
end

g.test_order_by_takes_a_direction_and_the_aliases_of_the_select = function()
    local query = users
        :select('name as title', sql.raw('count(*) as total'))
        :order_by('title')
        :order_by('votes', 'desc')
        :order_by(sql.raw('count(*)'), 'asc')

    t.assert_equals(built(query, 'mysql'), {
        'select `name` as `title`, count(*) as total from `users` order by `title` asc, `votes` desc, count(*) asc',
        { n = 0 },
    })
end

g.test_an_alias_is_a_name_only_in_order_by = function()
    local query = users:select('name as title'):where('title', '=', 'x')

    helper.assert_blamed({
        {
            function()
                query:build('mysql')
            end,
            'where: столбца «title» нет в белом списке users (id, name, votes)',
        },
        {
            function()
                users:select('name'):order_by('name', 'down')
            end,
            'order_by: направление — asc либо desc, а не «down»',
        },
        {
            function()
                users:select('name'):order_by(wrong(1))
            end,
            'order_by: столбец — имя столбца строкой, а не 1',
        },
    })
end

g.test_sort_takes_the_order_parsed_from_the_address = function()
    local query = users:select('id'):sort({
        { field = 'votes', direction = 'desc' },
        { field = 'name', direction = 'asc' },
    })

    t.assert_equals(built(query, 'postgres'), {
        'select "id" from "users" order by "votes" desc, "name" asc',
        { n = 0 },
    })
    helper.assert_blamed({
        {
            function()
                users:select():sort(wrong('name'))
            end,
            'sort: порядок — массив, а не строка',
        },
        {
            function()
                users:select():sort({ wrong('name') })
            end,
            'sort[1] — таблица, а не строка',
        },
        {
            function()
                users:select():sort({ { field = 'name', direction = 'up' } })
            end,
            'order_by: направление — asc либо desc, а не «up»',
        },
    })
end

g.test_limit_and_offset_are_whole_numbers_in_the_text = function()
    t.assert_equals(built(users:select('id'):limit(10):offset(20), 'postgres'), {
        'select "id" from "users" limit 10 offset 20',
        { n = 0 },
    })
    t.assert_equals(built(users:select('id'):limit(0), 'mysql'), { 'select `id` from `users` limit 0', { n = 0 } })
    t.assert_equals(built(users:select('id'):limit(2 ^ 53):offset(0), 'tarantool'), {
        'select "id" from "users" limit 9007199254740992 offset 0',
        { n = 0 },
    })
end

g.test_bad_limits_are_refused = function()
    helper.assert_blamed({
        {
            function()
                users:select():limit(-1)
            end,
            'limit — целое число от 0 до 2^53, а не -1',
        },
        {
            function()
                users:select():limit(wrong(1.5))
            end,
            'limit — целое число от 0 до 2^53, а не 1.5',
        },
        {
            function()
                users:select():offset(2 ^ 53 + 2)
            end,
            'offset — целое число от 0 до 2^53, а не 9.007199254741e+15',
        },
        {
            function()
                users:select():offset(wrong('5'))
            end,
            'offset — целое число от 0 до 2^53, а не «5»',
        },
        {
            function()
                users:select():limit(wrong(0 / 0))
            end,
            'limit — целое число от 0 до 2^53, а не NaN',
        },
    })
end

g.test_an_offset_without_a_limit_is_refused_by_build = function()
    local query = users:select('id'):offset(5)

    helper.assert_blamed({
        {
            function()
                query:build('postgres')
            end,
            'offset без limit: MySQL и Tarantool так не умеют — задайте limit',
        },
    })
end

g.test_page_takes_the_page_parsed_from_the_address = function()
    t.assert_equals(built(users:select('id'):page({ size = 50, number = 2, offset = 50 }), 'mysql'), {
        'select `id` from `users` limit 50 offset 50',
        { n = 0 },
    })
    t.assert_equals(built(users:select('id'):page({ size = 5 }), 'mysql'), {
        'select `id` from `users` limit 5',
        { n = 0 },
    })
    helper.assert_blamed({
        {
            function()
                users:select():page({ size = 5, after = 'eyJpZCI6N30' })
            end,
            'page: курсор after разбирает приложение — продолжение ставят where, а сюда отдают страницу без after',
        },
        {
            function()
                users:select():page(wrong(5))
            end,
            'page — таблица, а не число',
        },
        {
            function()
                users:select():page({ size = wrong(0.5) })
            end,
            'page.size — целое число от 0 до 2^53, а не 0.5',
        },
        {
            function()
                users:select():page({ size = 5, offset = -5 })
            end,
            'page.offset — целое число от 0 до 2^53, а не -5',
        },
    })
end

g.test_seqscan_is_written_only_for_tarantool_and_for_every_table = function()
    local query = users:select('name', 'title'):join(posts, 'posts.user_id', '=', 'users.id'):seqscan()

    t.assert_equals(built(query, 'tarantool'), {
        'select "name", "title" from seqscan "users" inner join seqscan "posts" on "posts"."user_id" = "users"."id"',
        { n = 0 },
    })
    t.assert_equals(built(query, 'postgres'), {
        'select "name", "title" from "users" inner join "posts" on "posts"."user_id" = "users"."id"',
        { n = 0 },
    })
    t.assert_equals(built(query, 'mysql'), {
        'select `name`, `title` from `users` inner join `posts` on `posts`.`user_id` = `users`.`id`',
        { n = 0 },
    })
    t.assert_equals(built(users:as('u'):select('u.id'):seqscan(), 'tarantool'), {
        'select "u"."id" from seqscan "users" as "u"',
        { n = 0 },
    })
end

g.test_every_clause_in_its_place = function()
    local query = users
        :select('users.name', sql.raw('count(*) as total'))
        :distinct()
        :left_join(posts, 'posts.user_id', '=', 'users.id')
        :where('votes', '>', 1)
        :group_by('users.name')
        :having(sql.raw('count(*)'), '>=', 2)
        :order_by(sql.raw('total'), 'desc')
        :limit(5)
        :offset(10)

    t.assert_equals(built(query, 'postgres'), {
        'select distinct "users"."name", count(*) as total from "users"'
            .. ' left join "posts" on "posts"."user_id" = "users"."id"'
            .. ' where "votes" > $1::int8 group by "users"."name" having count(*) >= $2::int8'
            .. ' order by total desc limit 5 offset 10',
        { n = 2, 1, 2 },
    })
end
