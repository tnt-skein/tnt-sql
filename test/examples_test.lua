--- Примеры `docs/sql.md` дословно: документ обязан совпадать с кодом,
--- и каждый его пример проверяется здесь тем же текстом.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local storage = helper.storage
local built = helper.built

local g = t.group('tnt.sql.examples')

--- Таблицы объявляются в before_all, а не при загрузке файла: почему —
--- в шапке помощника.
---@type TntSqlTable
local users
---@type TntSqlTable
local posts

g.before_all(function()
    users = sql.table('users', { 'id', 'name', 'email', 'votes' })
    posts = sql.table('posts', { 'id', 'user_id', 'title' })
end)

--- Текст отказа без места: примеры документа места не показывают.
---@param call function
---@return string
local function refusal(call)
    local ok, err = pcall(call)

    t.assert_not(ok)

    return (tostring(err):gsub('^[^:]+:%d+: ', ''))
end

g.test_the_header = function()
    local text, params = users:select('id', 'name'):where('votes', '>', 100):build('postgres')

    t.assert_equals({ text, params }, { 'select "id", "name" from "users" where "votes" > $1::int8', { n = 1, 100 } })
end

g.test_how_to_use = function()
    local query = users:select('id', 'name'):where('votes', '>', 100):order_by('name', 'desc'):limit(10)

    t.assert_equals(built(query, 'postgres'), {
        'select "id", "name" from "users" where "votes" > $1::int8 order by "name" desc limit 10',
        { n = 1, 100 },
    })
    t.assert_equals(built(query, 'mysql'), {
        'select `id`, `name` from `users` where `votes` > ? order by `name` desc limit 10',
        { n = 1, 100 },
    })
    t.assert_equals(built(query, 'tarantool'), {
        'select "id", "name" from "users" where "votes" > ? order by "name" desc limit 10',
        { n = 1, 100 },
    })
end

g.test_the_white_list = function()
    local query = users:select('id'):filter({ { field = 'password_hash', op = 'prefix', value = 'a' } })

    t.assert_equals(
        refusal(function()
            query:build('postgres')
        end),
        'where: столбца «password_hash» нет в белом списке users (id, name, email, votes)'
    )
    t.assert_equals(
        refusal(function()
            users:select('id'):where('name; drop table users', '=', 1)
        end),
        'where: столбец — имя из латиницы, цифр и _, не с цифры и не длиннее 63 байтов, а не «name; drop table users»'
    )
end

g.test_select = function()
    local joined = users
        :select('users.id', 'title', 'posts.id as post_id')
        :left_join(posts, 'posts.user_id', '=', 'users.id')
        :where('title', 'prefix', 'p')

    t.assert_equals(built(joined, 'mysql'), {
        'select `users`.`id`, `title`, `posts`.`id` as `post_id` from `users`'
            .. ' left join `posts` on `posts`.`user_id` = `users`.`id`'
            .. [[ where `title` like ? escape '!']],
        { n = 1, 'p%' },
    })
    t.assert_equals(built(users:select():join(posts, 'posts.user_id', '=', 'users.id'), 'postgres'), {
        'select "users"."id", "users"."name", "users"."email", "users"."votes" from "users"'
            .. ' inner join "posts" on "posts"."user_id" = "users"."id"',
        { n = 0 },
    })
    t.assert_equals(
        refusal(function()
            users:select('users.id', 'posts.id')
        end),
        'select: имя «id» в выборке дважды, и рок оставит одно — дайте псевдоним: posts.id as другое'
    )

    local grouped = users
        :select('votes', sql.raw('count(*) as total'))
        :group_by('votes')
        :having(sql.raw('count(*)'), '>=', 2)
        :order_by(sql.raw('total'), 'desc')

    t.assert_equals(built(grouped, 'postgres'), {
        'select "votes", count(*) as total from "users" group by "votes" having count(*) >= $1::int8'
            .. ' order by total desc',
        { n = 1, 2 },
    })

    local scanned = users:select('name', 'title'):join(posts, 'posts.user_id', '=', 'users.id'):seqscan()

    t.assert_equals(built(scanned, 'tarantool'), {
        'select "name", "title" from seqscan "users" inner join seqscan "posts" on "posts"."user_id" = "users"."id"',
        { n = 0 },
    })
end

g.test_conditions = function()
    local query = users
        :select('id')
        :where('votes', '>', 1)
        :where(function(group)
            group:where('name', '=', 'a'):or_where('email', 'is null')
        end)
        :where('id', 'in', { 1, 2 })

    t.assert_equals(built(query, 'postgres'), {
        'select "id" from "users" where "votes" > $1::int8 and ("name" = $2 or "email" is null)'
            .. ' and "id" in ($3::int8, $4::int8)',
        { n = 4, 1, 'a', 1, 2 },
    })
    t.assert_equals(built(users:select('id'):where('name', 'contains', '50%'), 'mysql'), {
        [[select `id` from `users` where `name` like ? escape '!']],
        { n = 1, '%50!%%' },
    })
    t.assert_equals(
        refusal(function()
            users:select('id'):where('email', '=', nil)
        end),
        'where: сравнение с NULL не бывает истинным — пишите «is null» либо «is not null»'
    )
end

g.test_conditions_from_the_address = function()
    local asked = {
        filter = {
            { field = 'votes', op = 'gte', value = 10 },
            { field = 'name', op = 'prefix', value = 'st' },
            { field = 'id', op = 'in', value = { 5, 6 } },
        },
        sort = { { field = 'votes', direction = 'desc' }, { field = 'id', direction = 'asc' } },
        page = { size = 50, number = 2, offset = 50 },
    }
    local query = users:select('id', 'name'):filter(asked.filter):sort(asked.sort):page(asked.page)

    t.assert_equals(built(query, 'postgres'), {
        [[select "id", "name" from "users" where "votes" >= $1::int8 and "name" like $2 escape '!']]
            .. ' and "id" in ($3::int8, $4::int8)'
            .. ' order by "votes" desc, "id" asc limit 50 offset 50',
        { n = 4, 10, 'st%', 5, 6 },
    })
end

g.test_writes = function()
    t.assert_equals(built(users:insert({ { id = 1, name = 'a' }, { id = 2, name = box.NULL } }), 'tarantool'), {
        'insert into "users" ("id", "name") values (?, ?), (?, ?)',
        { n = 4, 1, 'a', 2, box.NULL },
    })

    local update = users:update({ votes = sql.raw('? + 1', sql.column('votes')), name = 'z' }):where('id', '=', 7)

    t.assert_equals(built(update, 'postgres'), {
        'update "users" set "name" = $1, "votes" = "votes" + 1 where "id" = $2::int8',
        { n = 2, 'z', 7 },
    })
    t.assert_equals(built(users:delete():where('votes', '<', 1), 'mysql'), {
        'delete from `users` where `votes` < ?',
        { n = 1, 1 },
    })
    t.assert_equals(
        refusal(function()
            users:delete():filter({}):build('postgres')
        end),
        'delete без where меняет всю таблицу — если так и задумано, скажите everything()'
    )
    t.assert_equals(built(users:delete():everything(), 'postgres'), { 'delete from "users"', { n = 0 } })
end

g.test_upsert = function()
    local query = users:upsert({ id = 1, name = 'a', votes = 3 }, { 'id' })

    t.assert_equals(built(query, 'postgres'), {
        'insert into "users" ("id", "name", "votes") values ($1::int8, $2, $3::int8)'
            .. ' on conflict ("id") do update set "name" = "excluded"."name", "votes" = "excluded"."votes"',
        { n = 3, 1, 'a', 3 },
    })
    t.assert_equals(built(query, 'mysql'), {
        'insert into `users` (`id`, `name`, `votes`) values (?, ?, ?)'
            .. ' as `excluded` on duplicate key update `name` = `excluded`.`name`, `votes` = `excluded`.`votes`',
        { n = 3, 1, 'a', 3 },
    })
    t.assert_equals(
        refusal(function()
            query:build('tarantool')
        end),
        'upsert: в SQL tarantool нет on conflict, а insert or replace стёр бы столбцы, которых нет в строке'
    )
    t.assert_equals(built(users:insert({ name = 'a' }):returning('id'), 'postgres'), {
        'insert into "users" ("name") values ($1) returning "id"',
        { n = 1, 'a' },
    })
end

g.test_values = function()
    local query = users:insert({ id = 9007199254740993LL, name = storage.json({ a = 1 }) })

    t.assert_equals(built(query, 'postgres'), {
        'insert into "users" ("id", "name") values ($1::int8, $2::jsonb)',
        { n = 2, '9007199254740993', '{"a":1}' },
    })

    local text, err = users:select('id'):where('name', '=', 'a\0b'):build('postgres')

    t.assert_equals({ text, tostring(err), err.kind, err.sent }, {
        nil,
        'строка с нулевым байтом: pg обрезал бы её молча',
        'rejected',
        false,
    })
end

g.test_raw_text = function()
    t.assert_equals(built(sql.raw('select ? as a, ? as b', 1, nil), 'postgres'), {
        'select $1::int8 as a, $2 as b',
        { n = 2, 1, box.NULL },
    })
    t.assert_equals(built(sql.raw("select 'it''s ?', ? -- ?", 1), 'postgres'), {
        "select 'it''s ?', $1::int8 -- ?",
        { n = 1, 1 },
    })
    t.assert_equals(
        refusal(function()
            sql.raw('select ?, ?', 1)
        end),
        'sql.raw: знаков ? в тексте 2, а значений 1'
    )
    t.assert_equals(
        refusal(function()
            sql.raw('select 1; select 2')
        end),
        'sql.raw: один оператор на вызов, а в тексте «;» вне кавычек'
    )
end
