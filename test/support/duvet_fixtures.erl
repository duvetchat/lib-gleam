%% Reads the JSON fixtures the Dart package generates from the API and gateway
%% Go types (duvet-client/tool/fixtures/generate.sh). They are copied here by
%% tool/sync-fixtures.sh and must never be edited by hand.
-module(duvet_fixtures).

-export([read/2, read_text/1]).

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
