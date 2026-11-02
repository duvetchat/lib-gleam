%% The few JSON facts Erlang keeps that Gleam cannot spell.
%%
%% The OTP json module decodes null to the atom `null`, while Gleam's own
%% `dynamic.nil()` is `nil`; a field is absent or null either way, and this
%% tells them apart from a value.
-module(duvet_json_ffi).

-export([is_null/1, null/0, bytes/1, byte_to_string/1, unique_integer/0, now_ms/0]).

null() -> null.

is_null(nil) -> true;
is_null(null) -> true;
is_null(_) -> false.

%% The bytes of a UTF-8 string, as integers.
bytes(Binary) ->
    binary_to_list(Binary).

%% One byte as a one-character binary.
byte_to_string(Byte) ->
    <<Byte>>.

%% A positive integer no other call in this VM has had, for a multipart
%% boundary.
unique_integer() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).

%% Monotonic milliseconds, for measuring intervals.
now_ms() ->
    erlang:monotonic_time(millisecond).
