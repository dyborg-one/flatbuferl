%% @doc Stock validation and transformation functions for flatbuferl field hooks.
%%
%% These functions return field-hook-compatible funs that can be used
%% directly as a `field_hook` or composed with `compose/1`.
%%
%% Validators return:
%%   ok            — field passes
%%   {error, _}    — field fails (short-circuits compose)
%%
%% Transformers return:
%%   ok            — field passes unchanged
%%   {ok, Value}   — field passes, value transformed
%%   {error, _}    — field fails
%%
%% Usage:
%%   flatbuferl:parse_schema(Schema, #{
%%       field_hook => flatbuferl_validations:compose([
%%           flatbuferl_validations:utf8_string(),
%%           flatbuferl_validations:ubyte_to_binary(),
%%           my_custom_hook()
%%       ])
%%   }).
-module(flatbuferl_validations).

-export([
    utf8_string/0,
    non_empty_string/0,
    non_empty_list/0,
    ubyte_to_binary/0,
    compose/1
]).

%% =============================================================================
%% Stock Validators
%% =============================================================================

%% @doc Validate that binary string fields contain valid UTF-8.
%% Applies on both encode and decode.
-spec utf8_string() -> fun((atom(), atom(), term(), encode | 'decode', map()) ->
    ok | {ok, term()} | {error, term()}).
utf8_string() ->
    fun(_MsgType, _Field, Value, _Dir, _Attrs) when is_binary(Value) ->
        case unicode:characters_to_binary(Value, utf8, utf8) of
            Value -> ok;
            _ -> {error, {invalid_utf8, Value}}
        end;
       (_MsgType, _Field, _Value, _Dir, _Attrs) ->
        ok
    end.

%% @doc Validate that string fields are non-empty binaries.
%% Applies on encode only.
-spec non_empty_string() -> fun((atom(), atom(), term(), encode | 'decode', map()) ->
    ok | {ok, term()} | {error, term()}).
non_empty_string() ->
    fun(_MsgType, _Field, <<>>, encode, _Attrs) ->
        {error, empty_string};
       (_MsgType, _Field, _Value, _Dir, _Attrs) ->
        ok
    end.

%% @doc Validate that list fields are non-empty.
%% Applies on encode only.
-spec non_empty_list() -> fun((atom(), atom(), term(), encode | 'decode', map()) ->
    ok | {ok, term()} | {error, term()}).
non_empty_list() ->
    fun(_MsgType, _Field, [], encode, _Attrs) ->
        {error, empty_list};
       (_MsgType, _Field, _Value, _Dir, _Attrs) ->
        ok
    end.

%% =============================================================================
%% Stock Transformers
%% =============================================================================

%% @doc Convert [ubyte] lists to binaries on decode.
%% FlatBuffer [ubyte] fields decode as integer lists; this converts them back.
-spec ubyte_to_binary() -> fun((atom(), atom(), term(), encode | 'decode', map()) ->
    ok | {ok, term()} | {error, term()}).
ubyte_to_binary() ->
    fun(_MsgType, _Field, Value, decode, _Attrs) when is_list(Value) ->
        case lists:all(fun(X) -> is_integer(X) andalso X >= 0 andalso X =< 255 end, Value) of
            true -> {ok, list_to_binary(Value)};
            false -> ok
        end;
       (_MsgType, _Field, _Value, _Dir, _Attrs) ->
        ok
    end.

%% =============================================================================
%% Composition
%% =============================================================================

%% @doc Compose multiple hook functions into one.
%%
%% Each hook is called in order. The output of one feeds into the next.
%% Short-circuits on first {error, _} — subsequent hooks are NOT called.
%%
%% Return value propagation:
%%   ok              → passes current value to next hook
%%   {ok, NewValue}  → passes NewValue to next hook
%%   {error, Reason} → stops, returns {error, Reason} immediately
-spec compose([fun((atom(), atom(), term(), encode | 'decode', map()) ->
    ok | {ok, term()} | {error, term()})]) ->
    fun((atom(), atom(), term(), encode | 'decode', map()) ->
        ok | {ok, term()} | {error, term()}).
compose(Hooks) ->
    fun(MsgType, Field, Value0, Dir, Attrs) ->
        compose_apply(Hooks, MsgType, Field, Value0, Dir, Attrs)
    end.

%% @private
compose_apply([], _MsgType, _Field, Value, _Dir, _Attrs) ->
    {ok, Value};
compose_apply([Hook | Rest], MsgType, Field, Value, Dir, Attrs) ->
    case Hook(MsgType, Field, Value, Dir, Attrs) of
        ok ->
            compose_apply(Rest, MsgType, Field, Value, Dir, Attrs);
        {ok, NewValue} ->
            compose_apply(Rest, MsgType, Field, NewValue, Dir, Attrs);
        {error, _} = Error ->
            Error
    end.