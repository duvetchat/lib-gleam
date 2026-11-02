%% The few JSON facts Erlang keeps that Gleam cannot spell.
%%
%% The OTP json module decodes null to the atom `null`, while Gleam's own
%% `dynamic.nil()` is `nil`; a field is absent or null either way, and this
%% tells them apart from a value.
-module(duvet_json_ffi).

-export([is_null/1]).

is_null(nil) -> true;
is_null(null) -> true;
is_null(_) -> false.
