--- Проверки текста руками: знаки вне кавычек и комментариев, `??`,
--- один оператор, сверка числа знаков, сборка под диалект.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local sql = helper.sql
local built = helper.built
local wrong = helper.wrong

local g = t.group('tnt.sql.raw')

g.test_signs_become_the_dialect_ones = function()
    local raw = sql.raw('select ? as a, ? as b', 1, 'x')

    t.assert_equals(built(raw, 'postgres'), { 'select $1::int8 as a, $2 as b', { n = 2, 1, 'x' } })
    t.assert_equals(built(raw, 'mysql'), { 'select ? as a, ? as b', { n = 2, 1, 'x' } })
    t.assert_equals(built(raw, 'tarantool'), { 'select ? as a, ? as b', { n = 2, 1, 'x' } })
end

g.test_nil_in_the_middle_is_null = function()
    t.assert_equals(built(sql.raw('select ?, ?, ?', 1, nil, 3), 'tarantool'), {
        'select ?, ?, ?',
        { n = 3, 1, box.NULL, 3 },
    })
end

g.test_a_text_without_signs = function()
    t.assert_equals(built(sql.raw('select 1'), 'postgres'), { 'select 1', { n = 0 } })
    t.assert_equals(built(sql.raw(''), 'postgres'), { '', { n = 0 } })
end

g.test_signs_in_quotes_and_comments_are_text = function()
    local text = [[select '?' as "a?", `b?`, 'it''s ?', ? -- ? ;
from t /* ? ; ' */ where x = ?]]
    local raw = sql.raw(text, 1, 2)

    t.assert_equals(built(raw, 'postgres'), {
        [[select '?' as "a?", `b?`, 'it''s ?', $1::int8 -- ? ;
from t /* ? ; ' */ where x = $2::int8]],
        { n = 2, 1, 2 },
    })
end

g.test_empty_literals_and_tight_comments = function()
    t.assert_equals(built(sql.raw('select \'\', "", ``, ? /**/ -- ?', 1), 'postgres'), {
        'select \'\', "", ``, $1::int8 /**/ -- ?',
        { n = 1, 1 },
    })
    t.assert_equals(built(sql.raw("select 'a'?", 1), 'mysql'), { "select 'a'?", { n = 1, 1 } })
    helper.assert_blamed({
        {
            function()
                sql.raw('select 1 /*/ ?')
            end,
            'sql.raw: комментарий /* не закрыт',
        },
    })
end

g.test_the_text_may_end_right_after_a_quote_or_a_comment = function()
    t.assert_equals(built(sql.raw("select ?, 'a'", 1), 'postgres'), { "select $1::int8, 'a'", { n = 1, 1 } })
    t.assert_equals(built(sql.raw('select ?, "a"', 1), 'postgres'), { 'select $1::int8, "a"', { n = 1, 1 } })
    t.assert_equals(built(sql.raw('select ?, `a`', 1), 'mysql'), { 'select ?, `a`', { n = 1, 1 } })
    t.assert_equals(built(sql.raw('select ? /* a */', 1), 'postgres'), { 'select $1::int8 /* a */', { n = 1, 1 } })
    t.assert_equals(built(sql.raw('select ? --', 1), 'postgres'), { 'select $1::int8 --', { n = 1, 1 } })
    t.assert_equals(built(sql.raw('?', 1), 'postgres'), { '$1::int8', { n = 1, 1 } })
end

g.test_a_comment_to_the_end_of_the_text = function()
    t.assert_equals(built(sql.raw('select ? -- ?', 5), 'postgres'), { 'select $1::int8 -- ?', { n = 1, 5 } })
end

g.test_a_lone_minus_and_slash_are_text = function()
    t.assert_equals(built(sql.raw('select ? - 1, ? / 2', 5, 6), 'postgres'), {
        'select $1::int8 - 1, $2::int8 / 2',
        { n = 2, 5, 6 },
    })
end

g.test_a_double_sign_is_the_sign_itself = function()
    t.assert_equals(built(sql.raw('select ?::jsonb ?? ?', '{"a":1}', 'a'), 'postgres'), {
        'select $1::jsonb ? $2',
        { n = 2, '{"a":1}', 'a' },
    })
    t.assert_equals(built(sql.raw('select ??'), 'mysql'), { 'select ?', { n = 0 } })
end

g.test_the_count_of_signs_is_checked = function()
    helper.assert_blamed({
        {
            function()
                sql.raw('select ?, ?', 1)
            end,
            'sql.raw: знаков ? в тексте 2, а значений 1',
        },
        {
            function()
                sql.raw('select 1', 1)
            end,
            'sql.raw: знаков ? в тексте 0, а значений 1',
        },
        {
            function()
                sql.raw('select $1', 1)
            end,
            'sql.raw: знаков ? в тексте 0, а значений 1',
        },
        {
            function()
                sql.raw('select ?, ?', 1, nil, nil)
            end,
            'sql.raw: знаков ? в тексте 2, а значений 3',
        },
    })
end

g.test_one_statement_per_call = function()
    helper.assert_blamed({
        {
            function()
                sql.raw('select 1; select 2')
            end,
            'sql.raw: один оператор на вызов, а в тексте «;» вне кавычек',
        },
        {
            function()
                sql.raw('select 1;')
            end,
            'sql.raw: один оператор на вызов, а в тексте «;» вне кавычек',
        },
    })
end

g.test_unclosed_quotes_and_comments_are_refused = function()
    helper.assert_blamed({
        {
            function()
                sql.raw("select 'it")
            end,
            "sql.raw: кавычка ' не закрыта",
        },
        {
            function()
                sql.raw("select 'it''")
            end,
            "sql.raw: кавычка ' не закрыта",
        },
        {
            function()
                sql.raw('select "a')
            end,
            'sql.raw: кавычка " не закрыта',
        },
        {
            function()
                sql.raw('select `a')
            end,
            'sql.raw: кавычка ` не закрыта',
        },
        {
            function()
                sql.raw('select 1 /* ?')
            end,
            'sql.raw: комментарий /* не закрыт',
        },
        {
            function()
                sql.raw(wrong(5))
            end,
            'sql.raw: текст — строка, а не 5',
        },
    })
end

g.test_a_backslash_is_not_an_escape = function()
    helper.assert_blamed({
        {
            function()
                sql.raw([[select 'it\'s ?']])
            end,
            "sql.raw: кавычка ' не закрыта",
        },
    })
end

g.test_values_of_a_raw_text_are_encoded_like_the_driver_does = function()
    local raw = sql.raw('select ?, ?', 9007199254740993LL, helper.storage.binary('\0\255'))

    t.assert_equals(built(raw, 'postgres'), {
        'select $1::int8, $2::bytea',
        { n = 2, '9007199254740993', '\\x00ff' },
    })
    t.assert_equals(built(raw, 'mysql'), { 'select ?, ?', { n = 2, '9007199254740993', '\0\255' } })
end

g.test_a_raw_text_nests_in_a_raw_text = function()
    local inner = sql.raw('coalesce(?, ?)', 1, 2)

    t.assert_equals(built(sql.raw('select ?, ?', 0, inner), 'postgres'), {
        'select $1::int8, coalesce($2::int8, $3::int8)',
        { n = 3, 0, 1, 2 },
    })
end

g.test_the_values_are_taken_at_the_call = function()
    local raw = sql.raw('select ?', 1)

    t.assert_equals(built(raw, 'postgres'), built(raw, 'postgres'))
    t.assert_equals(raw.params, { n = 1, 1 })
    t.assert_equals(raw.pieces, { 'select ', '' })
end
