%% @doc FlatBuffers implementation for Erlang.
%%
%% Schemas are parsed at runtime without code generation. Encoding produces
%% iolists and decoding returns sub-binaries, both avoiding unnecessary copies.
-module(flatbuferl).

-include("flatbuferl_records.hrl").

-export([
    parse_schema/1,
    parse_schema_file/1,
    new/2,
    get/2,
    get/3,
    get_bytes/2,
    file_id/1,
    has/2,
    to_map/1,
    to_map/2,
    from_map/2,
    from_map/3,
    update/2,
    validate/2,
    validate/3,
    schema_to_module/3
]).

%% @private Context accessors for internal modules
-export([ctx_buffer/1, ctx_schema/1, ctx_root/1]).

-export_type([ctx/0, path/0, decode_opts/0, schema/0, validate_opts/0, validation_error/0]).

-type schema() :: {flatbuferl_schema:definitions(), flatbuferl_schema:options()}.

%% Options for decoding:
%%   deprecated => skip | allow | error
%%     - skip: silently omit deprecated fields from output (default)
%%     - allow: include deprecated fields in output
%%     - error: raise error if deprecated field is present in buffer
-type decode_opts() :: #{
    deprecated => skip | allow | error
}.

-record(ctx, {
    buffer :: binary(),
    defs :: flatbuferl_schema:definitions(),
    root_type :: atom(),
    root :: {table, non_neg_integer(), binary()},
    opts = #{} :: map()
}).

-opaque ctx() :: #ctx{}.
-type path() :: [atom()].

%% =============================================================================
%% Schema Parsing
%% =============================================================================

%% @doc Parse a FlatBuffers schema from a string or binary.
-spec parse_schema(string() | binary()) -> {ok, schema()} | {error, term()}.
parse_schema(Schema) ->
    flatbuferl_schema:parse(Schema).

%% @doc Parse a FlatBuffers schema from a file.
%% Resolves `include' directives relative to the file's directory.
-spec parse_schema_file(file:filename()) -> {ok, schema()} | {error, term()}.
parse_schema_file(Filename) ->
    flatbuferl_schema:parse_file(Filename).

%% =============================================================================
%% Context Creation
%% =============================================================================

%% @doc Create a decoding context from a buffer and schema.
%% The context can be used with `get/2', `has/2', and `to_map/1'.
-spec new(binary(), schema()) -> ctx().
new(Buffer, {Defs, SchemaOpts}) ->
    RootType = maps:get(root_type, SchemaOpts),
    Root = flatbuferl_reader:get_root(Buffer),
    #ctx{
        buffer = Buffer,
        defs = Defs,
        root_type = RootType,
        root = Root,
        opts = SchemaOpts
    }.

%% =============================================================================
%% Access API
%% =============================================================================

%% @doc Get a field value by path. Raises if field is missing and has no default.
-spec get(ctx(), path()) -> term().
get(Ctx, Path) ->
    case get_internal(Ctx, Path) of
        {ok, Value} -> Value;
        missing -> error({missing_field, Path, no_default})
    end.

%% @doc Get a field value by path, returning Default if missing.
-spec get(ctx(), path(), term()) -> term().
get(Ctx, Path, Default) ->
    case get_internal(Ctx, Path) of
        {ok, Value} -> Value;
        missing -> Default
    end.

%% @doc Check if a field is present in the buffer.
-spec has(ctx(), path()) -> boolean().
has(Ctx, Path) ->
    case get_internal(Ctx, Path) of
        {ok, _} -> true;
        missing -> false
    end.

%% =============================================================================
%% Full Deserialization
%% =============================================================================

%% @doc Decode the entire buffer to an Erlang map.
-spec to_map(ctx()) -> map().
to_map(Ctx) ->
    to_map(Ctx, #{}).

%% @doc Decode the entire buffer to an Erlang map with options.
-spec to_map(ctx(), decode_opts()) -> map().
to_map(
    #ctx{buffer = Buffer, defs = Defs, root_type = RootType, root = Root, opts = SchemaOpts}, Opts
) ->
    Map = table_to_map(Root, Defs, RootType, Buffer, Opts),
    apply_field_hooks(Map, Defs, 'decode', SchemaOpts).

%% @doc Encode an Erlang map to FlatBuffers iodata.
-spec from_map(map(), schema()) -> iodata().
from_map(Map, {Defs, Opts} = Schema) ->
    Map1 = apply_field_hooks(Map, Defs, encode, Opts),
    flatbuferl_builder:from_map(Map1, Schema).

%% @doc Encode an Erlang map to FlatBuffers iodata with options.
-spec from_map(map(), schema(), flatbuferl_builder:encode_opts()) -> iodata().
from_map(Map, {Defs, Opts} = Schema, EncodeOpts) ->
    Map1 = apply_field_hooks(Map, Defs, encode, Opts),
    flatbuferl_builder:from_map(Map1, Schema, EncodeOpts).

%% @doc Update fields in a FlatBuffer.
%%
%% For fixed-size scalar fields that exist in the buffer, performs an efficient
%% in-place splice without copying the buffer. For variable-length fields or
%% fields not present in the buffer, falls back to full re-encoding.
%%
%% Changes is a nested map mirroring the structure from `to_map/1':
%% ```
%% update(Ctx, #{hp => 150})              %% update scalar
%% update(Ctx, #{pos => #{x => 5.0}})     %% update nested struct field
%% update(Ctx, #{hp => 200, level => 10}) %% update multiple fields
%% '''
-spec update(ctx(), map()) -> iodata().
update(Ctx, Changes) ->
    flatbuferl_update:update(Ctx, Changes).

table_to_map(TableRef, Defs, TableType, Buffer, Opts) ->
    #table_def{all_fields = Fields} = maps:get(TableType, Defs),
    DeprecatedOpt = maps:get(deprecated, Opts, skip),
    VTable = flatbuferl_reader:read_vtable(TableRef),
    decode_fields(Fields, VTable, Defs, TableType, Buffer, Opts, DeprecatedOpt, #{}).

%% Recursive field decoder - reads vtable once, dispatches by field type
decode_fields([], _VTable, _Defs, _TableType, _Buffer, _Opts, _DeprecatedOpt, Acc) ->
    Acc;
%% Skip deprecated fields (common case: DeprecatedOpt = skip)
decode_fields(
    [#field_def{deprecated = true} | Rest], VTable, Defs, TableType, Buffer, Opts, skip, Acc
) ->
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, skip, Acc);
%% Inline array field - read fixed-size array data directly
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type = #array_def{} = RT,
            default = Def,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
            {ok, Value} -> Acc#{Name => Value};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing -> Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Union type field - read discriminator and convert index to atom
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type = #union_type_def{reverse_map = ReverseMap},
            deprecated = false,
            is_primitive = true
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    %% Use precomputed reverse map (index -> atom) for decoding
    Acc1 =
        case flatbuferl_reader:read_union_type_field(VTable, VTS, Buffer) of
            {ok, 0} ->
                Acc;
            {ok, TypeIndex} ->
                MemberType = maps:get(TypeIndex, ReverseMap),
                Acc#{Name => MemberType};
            missing ->
                Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Union value field - use precomputed vtable slot offsets and reverse_map
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type = #union_value_def{
                reverse_map = ReverseMap, type_vtable_slot_offset = TypeVTS
            },
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_union_type_field(VTable, TypeVTS, Buffer) of
            {ok, 0} ->
                Acc;
            {ok, TypeIndex} ->
                case flatbuferl_reader:read_union_value_field(VTable, VTS, Buffer) of
                    {ok, TableRef} ->
                        MemberType = maps:get(TypeIndex, ReverseMap),
                        Acc#{Name => table_to_map(TableRef, Defs, MemberType, Buffer, Opts)};
                    missing ->
                        Acc
                end;
            missing ->
                Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Enum field - scalar with value conversion (must come before primitive scalar)
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type = #enum_resolved{base_type = Base, reverse_map = ReverseMap},
            default = Def,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_scalar_field(VTable, VTS, Base, Buffer) of
            {ok, Value} -> Acc#{Name => maps:get(Value, ReverseMap, Value)};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing -> Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Primitive scalar - fast path with only 11 clause function
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type = RT,
            default = Def,
            deprecated = false,
            is_primitive = true
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_scalar_field(VTable, VTS, RT, Buffer) of
            {ok, Value} -> Acc#{Name => Value};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing -> Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Non-primitive atom type (nested table) - recursively decode
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            type = Type,
            resolved_type = RT,
            default = Def,
            deprecated = false,
            is_primitive = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) when Type /= string, is_atom(Type), is_atom(RT) ->
    Acc1 =
        case flatbuferl_reader:read_ref_field(VTable, VTS, RT, Buffer) of
            {ok, TableRef} -> Acc#{Name => table_to_map(TableRef, Defs, Type, Buffer, Opts)};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing -> Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Non-deprecated string field - use fast string reader
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            type = string,
            default = Def,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_string_field(VTable, VTS, Buffer) of
            {ok, Value} -> Acc#{Name => Value};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing -> Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Vector of tables - use precomputed is_table_element flag
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type = #vector_def{element_type = ElemType, is_table_element = true} = RT,
            default = Def,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
            {ok, TableRefs} ->
                Acc#{Name => [table_to_map(V, Defs, ElemType, Buffer, Opts) || V <- TableRefs]};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing ->
                Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Vector of union types - use precomputed reverse_map from element_type
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type =
                #vector_def{element_type = #union_type_def{reverse_map = ReverseMap}} = RT,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
            {ok, TypeIndices} ->
                TypeNames = [maps:get(Idx, ReverseMap) || Idx <- TypeIndices, Idx > 0],
                Acc#{Name => TypeNames};
            missing ->
                Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Vector of union values - use precomputed reverse_map from element_type
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type =
                #vector_def{element_type = #union_value_def{reverse_map = ReverseMap}} = RT,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    %% Type field is immediately before value field
    TypeVTS = VTS - 2,
    TypeVecDef = #vector_def{element_type = uint8, is_primitive = true, element_size = 1},
    Acc1 =
        case flatbuferl_reader:read_field(VTable, TypeVTS, TypeVecDef, Buffer) of
            {ok, TypeIndices} ->
                case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
                    {ok, TableRefs} ->
                        DecodedValues = lists:zipwith(
                            fun(TypeIdx, TableValueRef) ->
                                MemberType = maps:get(TypeIdx, ReverseMap),
                                table_to_map(TableValueRef, Defs, MemberType, Buffer, Opts)
                            end,
                            TypeIndices,
                            TableRefs
                        ),
                        Acc#{Name => DecodedValues};
                    missing ->
                        Acc
                end;
            missing ->
                Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Vector of union values (partial - used in vector element types)
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type =
                #vector_def{element_type = #union_value_partial{reverse_map = ReverseMap}} = RT,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    %% Type field is immediately before value field
    TypeVTS = VTS - 2,
    TypeVecDef = #vector_def{element_type = uint8, is_primitive = true, element_size = 1},
    Acc1 =
        case flatbuferl_reader:read_field(VTable, TypeVTS, TypeVecDef, Buffer) of
            {ok, TypeIndices} ->
                case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
                    {ok, TableRefs} ->
                        DecodedValues = lists:zipwith(
                            fun(TypeIdx, TableValueRef) ->
                                MemberType = maps:get(TypeIdx, ReverseMap),
                                table_to_map(TableValueRef, Defs, MemberType, Buffer, Opts)
                            end,
                            TypeIndices,
                            TableRefs
                        ),
                        Acc#{Name => DecodedValues};
                    missing ->
                        Acc
                end;
            missing ->
                Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Vector of enums - convert integers to atoms using reverse_map
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type =
                #vector_def{element_type = #enum_resolved{reverse_map = ReverseMap}} = RT,
            default = Def,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
            {ok, Values} ->
                Acc#{Name => [maps:get(V, ReverseMap, V) || V <- Values]};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing ->
                Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Vector of non-tables (scalars, strings, structs) - return raw values
decode_fields(
    [
        #field_def{
            name = Name,
            vtable_slot_offset = VTS,
            resolved_type = #vector_def{is_table_element = false} = RT,
            default = Def,
            deprecated = false
        }
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    DepOpt,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
            {ok, Value} -> Acc#{Name => Value};
            missing when Def /= undefined -> Acc#{Name => Def};
            missing -> Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, DepOpt, Acc1);
%% Deprecated field with error option
decode_fields(
    [
        #field_def{name = Name, vtable_slot_offset = VTS, resolved_type = RT, deprecated = true}
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    error,
    Acc
) ->
    case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
        {ok, _} -> error({deprecated_field_present, TableType, Name});
        missing -> decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, error, Acc)
    end;
%% Deprecated field with allow option
decode_fields(
    [
        #field_def{name = Name, vtable_slot_offset = VTS, resolved_type = RT, deprecated = true}
        | Rest
    ],
    VTable,
    Defs,
    TableType,
    Buffer,
    Opts,
    allow,
    Acc
) ->
    Acc1 =
        case flatbuferl_reader:read_field(VTable, VTS, RT, Buffer) of
            {ok, Value} -> Acc#{Name => Value};
            missing -> Acc
        end,
    decode_fields(Rest, VTable, Defs, TableType, Buffer, Opts, allow, Acc1).

%% =============================================================================
%% Raw Bytes Access
%% =============================================================================

%% @doc Get raw bytes for a field, returning a sub-binary from the buffer.
-spec get_bytes(ctx(), path()) -> binary().
get_bytes(#ctx{buffer = Buffer, defs = Defs, root_type = RootType, root = Root}, Path) ->
    case get_bytes_internal(Root, Defs, RootType, Path, Buffer) of
        {ok, Bytes} -> Bytes;
        missing -> error({missing_field, Path})
    end.

get_bytes_internal(TableRef, Defs, TableType, [FieldName], Buffer) ->
    #table_def{field_map = FieldMap} = maps:get(TableType, Defs),
    case maps:get(FieldName, FieldMap, undefined) of
        #field_def{id = FieldId} ->
            get_field_bytes(TableRef, FieldId, Buffer);
        undefined ->
            error({unknown_field, FieldName})
    end;
get_bytes_internal(TableRef, Defs, TableType, [FieldName | Rest], Buffer) ->
    #table_def{field_map = FieldMap} = maps:get(TableType, Defs),
    case maps:get(FieldName, FieldMap, undefined) of
        #field_def{id = FieldId, resolved_type = NestedType} when is_atom(NestedType) ->
            case flatbuferl_reader:get_field(TableRef, FieldId, NestedType, Buffer) of
                {ok, NestedTableRef} ->
                    get_bytes_internal(NestedTableRef, Defs, NestedType, Rest, Buffer);
                missing ->
                    missing
            end;
        #field_def{resolved_type = Type} ->
            error({not_a_table, FieldName, Type});
        undefined ->
            error({unknown_field, FieldName})
    end.

get_field_bytes({table, TableOffset, Buffer}, FieldId, _Buffer) ->
    <<_:TableOffset/binary, VTableSOffset:32/little-signed, _/binary>> = Buffer,
    VTableOffset = TableOffset - VTableSOffset,
    <<_:VTableOffset/binary, VTableSize:16/little-unsigned, _/binary>> = Buffer,
    FieldOffsetPos = 4 + (FieldId * 2),
    case FieldOffsetPos < VTableSize of
        true ->
            FieldOffsetInBuffer = VTableOffset + FieldOffsetPos,
            <<_:FieldOffsetInBuffer/binary, FieldOffset:16/little-unsigned, _/binary>> = Buffer,
            case FieldOffset of
                0 ->
                    missing;
                _ ->
                    FieldPos = TableOffset + FieldOffset,
                    <<_:FieldPos/binary, DataOffset:32/little-unsigned, _/binary>> = Buffer,
                    DataPos = FieldPos + DataOffset,
                    <<_:DataPos/binary, Rest/binary>> = Buffer,
                    {ok, Rest}
            end;
        false ->
            missing
    end.

%% =============================================================================
%% Metadata
%% =============================================================================

%% @doc Extract the 4-byte file identifier from a buffer.
-spec file_id(ctx() | binary()) -> binary().
file_id(#ctx{buffer = Buffer}) ->
    flatbuferl_reader:get_file_id(Buffer);
file_id(Buffer) when is_binary(Buffer) ->
    flatbuferl_reader:get_file_id(Buffer).

%% @hidden
-spec ctx_buffer(ctx()) -> binary().
ctx_buffer(#ctx{buffer = Buffer}) -> Buffer.

%% @hidden
-spec ctx_schema(ctx()) -> schema().
ctx_schema(#ctx{defs = Defs, root_type = RootType}) ->
    {Defs, #{root_type => RootType}}.

%% @hidden
-spec ctx_root(ctx()) ->
    {
        Defs :: flatbuferl_schema:definitions(),
        RootType :: atom(),
        Root :: flatbuferl_reader:table_ref()
    }.
ctx_root(#ctx{defs = Defs, root_type = RootType, root = Root}) ->
    {Defs, RootType, Root}.

%% =============================================================================
%% Internal
%% =============================================================================

get_internal(
    #ctx{buffer = Buffer, defs = Defs, root_type = RootType, root = Root, opts = SchemaOpts}, Path
) ->
    get_path(Root, Defs, RootType, Path, Buffer, SchemaOpts).

get_path(TableRef, Defs, TableType, [FieldName], Buffer, SchemaOpts) ->
    #table_def{field_map = FieldMap} = maps:get(TableType, Defs),
    case maps:get(FieldName, FieldMap, undefined) of
        #field_def{id = FieldId, resolved_type = Type, default = Default, attrs = Attrs} ->
            ReaderType = resolve_for_reader(Type, Defs),
            case flatbuferl_reader:get_field(TableRef, FieldId, ReaderType, Buffer) of
                {ok, Value} ->
                    {ok,
                        apply_get_hook(
                            TableType,
                            FieldName,
                            convert_enum_value(Value, Type, Defs),
                            Attrs,
                            SchemaOpts
                        )};
                missing when Default /= undefined ->
                    {ok, apply_get_hook(TableType, FieldName, Default, Attrs, SchemaOpts)};
                missing ->
                    missing
            end;
        undefined ->
            error({unknown_field, FieldName})
    end;
get_path(TableRef, Defs, TableType, [FieldName | Rest], Buffer, SchemaOpts) ->
    #table_def{field_map = FieldMap} = maps:get(TableType, Defs),
    case maps:get(FieldName, FieldMap, undefined) of
        #field_def{id = FieldId, resolved_type = NestedType} when is_atom(NestedType) ->
            case flatbuferl_reader:get_field(TableRef, FieldId, NestedType, Buffer) of
                {ok, NestedTableRef} ->
                    get_path(NestedTableRef, Defs, NestedType, Rest, Buffer, SchemaOpts);
                missing ->
                    missing
            end;
        #field_def{resolved_type = Type} ->
            error({not_a_table, FieldName, Type});
        undefined ->
            error({unknown_field, FieldName})
    end.

%% @private Apply the field hook to a value read via get/fetch, if registered.
apply_get_hook(_TableType, _FieldName, Value, _Attrs, #{field_hook := Hook}) when
    is_function(Hook, 5)
->
    case Hook(_TableType, _FieldName, Value, 'decode', _Attrs) of
        ok -> Value;
        {ok, NewValue} -> NewValue;
        {error, Reason} -> error({field_hook_error, _TableType, _FieldName, Reason})
    end;
apply_get_hook(_TableType, _FieldName, Value, _Attrs, _Opts) ->
    Value.

%% Resolve type name to reader-compatible type
%% Handle types with defaults (unwrap first, but not type constructors)
resolve_for_reader({TypeName, Default}, Defs) when
    is_atom(TypeName),
    is_atom(Default),
    TypeName /= vector,
    TypeName /= enum,
    TypeName /= struct,
    TypeName /= array,
    TypeName /= union_type,
    TypeName /= union_value
->
    resolve_for_reader(TypeName, Defs);
resolve_for_reader({TypeName, Default}, Defs) when is_atom(TypeName), is_number(Default) ->
    resolve_for_reader(TypeName, Defs);
resolve_for_reader({TypeName, Default}, Defs) when is_atom(TypeName), is_boolean(Default) ->
    resolve_for_reader(TypeName, Defs);
resolve_for_reader(TypeName, Defs) when is_atom(TypeName) ->
    case maps:get(TypeName, Defs, undefined) of
        #enum_def{base_type = Base} -> Base;
        _ -> TypeName
    end;
resolve_for_reader(Type, _Defs) ->
    Type.

%% Convert integer enum value back to atom
%% Handle types with defaults (unwrap first, but not type constructors)
convert_enum_value(Value, {TypeName, Default}, Defs) when
    is_atom(TypeName),
    is_atom(Default),
    TypeName /= vector,
    TypeName /= enum,
    TypeName /= struct,
    TypeName /= array,
    TypeName /= union_type,
    TypeName /= union_value
->
    convert_enum_value(Value, TypeName, Defs);
convert_enum_value(Value, {TypeName, Default}, Defs) when is_atom(TypeName), is_number(Default) ->
    convert_enum_value(Value, TypeName, Defs);
convert_enum_value(Value, {TypeName, Default}, Defs) when is_atom(TypeName), is_boolean(Default) ->
    convert_enum_value(Value, TypeName, Defs);
%% Handle resolved enum type #enum_resolved{} from resolved_type
convert_enum_value(Value, #enum_resolved{reverse_map = ReverseMap}, _Defs) when
    is_integer(Value)
->
    %% O(1) lookup using precomputed reverse map
    maps:get(Value, ReverseMap, Value);
convert_enum_value(Value, TypeName, Defs) when is_atom(TypeName), is_integer(Value) ->
    case maps:get(TypeName, Defs, undefined) of
        #enum_def{reverse_map = ReverseMap} ->
            %% O(1) lookup using precomputed reverse map
            maps:get(Value, ReverseMap, Value);
        _ ->
            Value
    end;
convert_enum_value(Value, _Type, _Defs) ->
    Value.

%% =============================================================================
%% Field Hooks
%% =============================================================================

%% @doc Apply the field hook function (if present in schema options) to fields
%% in the map that have non-empty attributes in the schema.
%%
%% The hook signature:
%%   fun((FieldName :: atom(), Value :: term(), Direction :: encode | decode,
%%        Attrs :: map()) -> ok | {ok, term()} | {error, term()})
%%
%% The hook is stored in schema options under the key `field_hook`.
-spec apply_field_hooks(
    map(),
    flatbuferl_schema:definitions(),
    encode | 'decode',
    map()
) -> map().
apply_field_hooks(Map, Defs, Direction, #{field_hook := Hook, root_type := RootType}) when
    is_function(Hook, 5)
->
    apply_hook_to_table(Map, RootType, Defs, Hook, Direction);
apply_field_hooks(Map, _Defs, _Direction, _Opts) ->
    Map.

%% @private Apply hook to a table map, looking up field attrs from the schema.
apply_hook_to_table(Map, TableType, Defs, Hook, Dir) when is_map(Map), is_atom(TableType) ->
    case maps:get(TableType, Defs, undefined) of
        #table_def{all_fields = Fields} ->
            FieldMap = maps:from_list([{F#field_def.name, F} || F <- Fields]),
            maps:fold(
                fun(K, V, Acc) ->
                    V1 = apply_hook_to_field(
                        V, K, maps:get(K, FieldMap, undefined), TableType, Defs, Hook, Dir
                    ),
                    Acc#{K => V1}
                end,
                #{},
                Map
            );
        _ ->
            apply_hook_recursive(Map, Hook, Dir)
    end;
apply_hook_to_table(Other, _TableType, _Defs, _Hook, _Dir) ->
    Other.

%% @private Apply hook to a single field value, using field_def for attrs and nested type info.
apply_hook_to_field({UnionType, Fields}, _Key, _FieldDef, _TableType, Defs, Hook, Dir) when
    is_atom(UnionType), is_map(Fields)
->
    {UnionType, apply_hook_to_table(Fields, UnionType, Defs, Hook, Dir)};
apply_hook_to_field(Map, _Key, #field_def{attrs = Attrs} = FD, TableType, Defs, Hook, Dir) when
    is_map(Map), map_size(Attrs) > 0
->
    Map1 =
        case FD#field_def.type of
            Type when is_atom(Type) -> apply_hook_to_table(Map, Type, Defs, Hook, Dir);
            _ -> apply_hook_recursive(Map, Hook, Dir)
        end,
    case Hook(TableType, _Key, Map1, Dir, Attrs) of
        ok -> Map1;
        {ok, NewValue} -> NewValue;
        {error, Reason} -> error({field_hook_error, TableType, _Key, Reason})
    end;
apply_hook_to_field(Map, _Key, #field_def{type = Type}, _TableType, Defs, Hook, Dir) when
    is_map(Map), is_atom(Type)
->
    apply_hook_to_table(Map, Type, Defs, Hook, Dir);
apply_hook_to_field(Map, _Key, _FieldDef, _TableType, _Defs, Hook, Dir) when is_map(Map) ->
    apply_hook_recursive(Map, Hook, Dir);
apply_hook_to_field(List, _Key, #field_def{attrs = Attrs}, TableType, _Defs, Hook, Dir) when
    is_list(List), map_size(Attrs) > 0
->
    List1 = [apply_hook_recursive(E, Hook, Dir) || E <- List],
    case Hook(TableType, _Key, List1, Dir, Attrs) of
        ok -> List1;
        {ok, NewValue} -> NewValue;
        {error, Reason} -> error({field_hook_error, TableType, _Key, Reason})
    end;
apply_hook_to_field(List, _Key, _FieldDef, _TableType, _Defs, Hook, Dir) when is_list(List) ->
    [apply_hook_recursive(E, Hook, Dir) || E <- List];
apply_hook_to_field(Value, Key, #field_def{attrs = Attrs}, TableType, _Defs, Hook, Dir) when
    map_size(Attrs) > 0
->
    case Hook(TableType, Key, Value, Dir, Attrs) of
        ok -> Value;
        {ok, NewValue} -> NewValue;
        {error, Reason} -> error({field_hook_error, TableType, Key, Reason})
    end;
apply_hook_to_field(Value, _Key, _FieldDef, _TableType, _Defs, _Hook, _Dir) ->
    Value.

%% @private Recursively apply hook without schema awareness (fallback).
apply_hook_recursive({UnionType, Fields}, Hook, Dir) when is_atom(UnionType), is_map(Fields) ->
    {UnionType, apply_hook_recursive(Fields, Hook, Dir)};
apply_hook_recursive(Map, Hook, Dir) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{K => apply_hook_recursive(V, Hook, Dir)}
        end,
        #{},
        Map
    );
apply_hook_recursive(List, Hook, Dir) when is_list(List) ->
    [apply_hook_recursive(E, Hook, Dir) || E <- List];
apply_hook_recursive(Value, _Hook, _Dir) ->
    Value.

%% =============================================================================
%% Validation
%% =============================================================================

-type validate_opts() :: flatbuferl_schema:validate_opts().
-type validation_error() :: flatbuferl_schema:validation_error().

%% @doc Validate an Erlang map against a schema before encoding.
-spec validate(map(), schema()) -> ok | {error, [validation_error()]}.
validate(Map, Schema) ->
    validate(Map, Schema, #{}).

%% @doc Validate an Erlang map against a schema with options.
-spec validate(map(), schema(), validate_opts()) -> ok | {error, [validation_error()]}.
validate(Map, Schema, Opts) ->
    flatbuferl_schema:validate(Map, Schema, Opts).

%% =============================================================================
%% Schema Module Generation
%% =============================================================================

%% @doc Generate an Erlang module with the parsed schema inlined.
%% Delegates to flatbuferl_codegen. See flatbuferl_codegen:schema_to_module/3
%% for details.
-spec schema_to_module(schema(), module(), file:filename()) -> ok | {error, term()}.
schema_to_module(Schema, ModuleName, OutDir) ->
    flatbuferl_codegen:schema_to_module(Schema, ModuleName, OutDir).
