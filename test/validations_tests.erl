-module(validations_tests).
-include_lib("eunit/include/eunit.hrl").

%% =============================================================================
%% compose/1 Tests
%% =============================================================================

compose_empty_test() ->
    %% Empty compose should return {ok, Value} (no hooks = pass-through)
    Hook = flatbuferl_validations:compose([]),
    ?assertEqual({ok, <<"val">>}, Hook(foo, bar, <<"val">>, encode, #{})).

compose_single_ok_test() ->
    %% Single hook returning ok — value preserved
    Hook = flatbuferl_validations:compose([
        fun(_M, _F, _V, _D, _A) -> ok end
    ]),
    ?assertEqual({ok, <<"val">>}, Hook(foo, bar, <<"val">>, encode, #{})).

compose_single_transform_test() ->
    %% Single hook returning {ok, NewValue}
    Hook = flatbuferl_validations:compose([
        fun(_M, _F, V, _D, _A) -> {ok, V * 2} end
    ]),
    ?assertEqual({ok, 84}, Hook(foo, bar, 42, encode, #{})).

compose_chain_test() ->
    %% Multiple hooks chain: first transforms, second validates
    Hook = flatbuferl_validations:compose([
        fun(_M, _F, V, _D, _A) -> {ok, V * 2} end,
        fun(_M, _F, V, _D, _A) when V > 50 -> ok;
           (_M, _F, _V, _D, _A) -> {error, too_small}
        end
    ]),
    ?assertEqual({ok, 84}, Hook(foo, bar, 42, encode, #{})),
    ?assertEqual({error, too_small}, Hook(foo, bar, 10, encode, #{})).

compose_short_circuit_test() ->
    %% First hook errors — second never runs
    Self = self(),
    Hook = flatbuferl_validations:compose([
        fun(_M, _F, _V, _D, _A) -> {error, first_failed} end,
        fun(_M, _F, _V, _D, _A) -> Self ! second_ran, ok end
    ]),
    ?assertEqual({error, first_failed}, Hook(foo, bar, <<"x">>, encode, #{})),
    receive
        second_ran -> ?assert(false, "second hook ran after error")
    after 10 -> ok
    end.

compose_ok_propagates_value_test() ->
    %% ok passes the original value through to next hook
    Hook = flatbuferl_validations:compose([
        fun(_M, _F, _V, _D, _A) -> ok end,
        fun(_M, _F, V, _D, _A) -> {ok, V} end
    ]),
    ?assertEqual({ok, <<"original">>}, Hook(foo, bar, <<"original">>, encode, #{})).

compose_transform_chains_test() ->
    %% {ok, V1} → {ok, V2} chains correctly
    Hook = flatbuferl_validations:compose([
        fun(_M, _F, V, _D, _A) -> {ok, V + 1} end,
        fun(_M, _F, V, _D, _A) -> {ok, V * 3} end
    ]),
    ?assertEqual({ok, 15}, Hook(foo, bar, 4, encode, #{})).

%% =============================================================================
%% utf8_string/0 Tests
%% =============================================================================

utf8_valid_encode_test() ->
    Hook = flatbuferl_validations:utf8_string(),
    ?assertEqual(ok, Hook(foo, name, <<"hello">>, encode, #{})).

utf8_valid_decode_test() ->
    Hook = flatbuferl_validations:utf8_string(),
    ?assertEqual(ok, Hook(foo, name, <<"hello">>, decode, #{})).

utf8_invalid_encode_test() ->
    Hook = flatbuferl_validations:utf8_string(),
    ?assertMatch({error, {invalid_utf8, _}}, Hook(foo, name, <<128, 255>>, encode, #{})).

utf8_invalid_decode_test() ->
    Hook = flatbuferl_validations:utf8_string(),
    ?assertMatch({error, {invalid_utf8, _}}, Hook(foo, name, <<128, 255>>, decode, #{})).

utf8_non_binary_test() ->
    %% Non-binary values pass through (utf8 only checks binaries)
    Hook = flatbuferl_validations:utf8_string(),
    ?assertEqual(ok, Hook(foo, name, 42, encode, #{})),
    ?assertEqual(ok, Hook(foo, name, [1,2,3], decode, #{})).

%% =============================================================================
%% ubyte_to_binary/0 Tests
%% =============================================================================

ubyte_decode_list_test() ->
    Hook = flatbuferl_validations:ubyte_to_binary(),
    ?assertEqual({ok, <<1,2,3>>}, Hook(foo, data, [1,2,3], decode, #{})).

ubyte_decode_empty_test() ->
    Hook = flatbuferl_validations:ubyte_to_binary(),
    ?assertEqual({ok, <<>>}, Hook(foo, data, [], decode, #{})).

ubyte_decode_non_list_test() ->
    %% Non-list values pass through
    Hook = flatbuferl_validations:ubyte_to_binary(),
    ?assertEqual(ok, Hook(foo, data, <<"already_binary">>, decode, #{})),
    ?assertEqual(ok, Hook(foo, data, 42, decode, #{})).

ubyte_encode_noop_test() ->
    %% ubyte_to_binary only fires on decode
    Hook = flatbuferl_validations:ubyte_to_binary(),
    ?assertEqual(ok, Hook(foo, data, [1,2,3], encode, #{})).

ubyte_invalid_range_test() ->
    %% Values outside 0-255 pass through unchanged
    Hook = flatbuferl_validations:ubyte_to_binary(),
    ?assertEqual(ok, Hook(foo, data, [256, -1], decode, #{})).

%% =============================================================================
%% non_empty_string/0 Tests
%% =============================================================================

non_empty_string_pass_test() ->
    Hook = flatbuferl_validations:non_empty_string(),
    ?assertEqual(ok, Hook(foo, name, <<"hello">>, encode, #{})).

non_empty_string_fail_test() ->
    Hook = flatbuferl_validations:non_empty_string(),
    ?assertEqual({error, empty_string}, Hook(foo, name, <<>>, encode, #{})).

non_empty_string_decode_noop_test() ->
    %% non_empty_string only fires on encode
    Hook = flatbuferl_validations:non_empty_string(),
    ?assertEqual(ok, Hook(foo, name, <<>>, decode, #{})).

%% =============================================================================
%% non_empty_list/0 Tests
%% =============================================================================

non_empty_list_pass_test() ->
    Hook = flatbuferl_validations:non_empty_list(),
    ?assertEqual(ok, Hook(foo, items, [1,2,3], encode, #{})).

non_empty_list_fail_test() ->
    Hook = flatbuferl_validations:non_empty_list(),
    ?assertEqual({error, empty_list}, Hook(foo, items, [], encode, #{})).

non_empty_list_decode_noop_test() ->
    Hook = flatbuferl_validations:non_empty_list(),
    ?assertEqual(ok, Hook(foo, items, [], decode, #{})).