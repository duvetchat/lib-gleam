%% Reads the JSON fixtures the Dart package generates from the API and gateway
%% Go types (duvet-client/tool/fixtures/generate.sh). They are copied here by
%% tool/sync-fixtures.sh and must never be edited by hand.
-module(duvet_fixtures).

-export([read/2, read_text/1, zeroes/1, env/1]).

read(Name, Variant) ->
    Path = filename:join([
        "test",
        "fixtures",
        <<Name/binary, ".", Variant/binary, ".json">>
    ]),
    case file:read_file(Path) of
        {ok, Binary} -> Binary;
        {error, Reason} -> erlang:error({fixture_not_read, Path, Reason})
    end.

read_text(Path) ->
    {ok, Binary} = file:read_file(Path),
    Binary.

%% Bytes of zeros, for an upload of a size a test picks.
zeroes(Size) ->
    binary:copy(<<0>>, Size).

env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> "";
        Value -> Value
    end.
