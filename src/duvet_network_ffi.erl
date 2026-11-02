%% The only module in libduvet that touches the network libraries.
%%
%% Gleam's core language has no atom literals, and the Erlang target's
%% gleam/erlang/atom is an opaque, target-specific interop type: it can hold an
%% atom, but not give it the shape of a proplist, a map key or a message tag in
%% a way the compiler checks. hackney and gun take and give those raw Erlang
%% terms, so every option, message tag and error shape is translated here into
%% the plain Gleam values the rest of this library uses. Keep it that way: no
%% other module should need hackney or gun.
%%
%% REST: request/7 performs a whole exchange with a streamed request body and
%% a streamed response, reporting progress to a Gleam fun. The caller must run
%% it in a process it can kill: killing that process closes the connection
%% (hackney monitors the process that started the request), which is how
%% libduvet aborts a request or times it out.
%%
%% WebSocket: ws_start/4 starts a socket owner process, which upgrades with Gun
%% and forwards each frame to a Gleam subject in the order it came. Frames are
%% forwarded one at a time: Gun hands them over in order, and a close frame in
%% the same read as the frames before it doesn't lose them (hackney's active
%% mode drops those). The owner, and the connection with it, stops when the
%% process that opened it (the subject's owner) exits.
-module(duvet_network_ffi).

-export([
    request/7,
    ws_start/4,
    ws_send/2,
    ws_close/3
]).

%% -------------------------------------------------------------------------
%% REST
%% -------------------------------------------------------------------------

%% request(Method, Url, Headers, Pieces, TimeoutMs, OnProgress, OnActivity)
%%
%% Method and Url are binaries, Headers a list of {binary, binary}, Pieces a
%% list of binaries ([] for no body), OnProgress a fun of one argument (the
%% bytes sent so far), OnActivity a fun of no arguments (any progress, the
%% answer's bytes included).
%%
%% Answers {ok, {Status, Headers, Body}} or {error, timeout} or
%% {error, {network, Reason}}.
request(Method, Url, Headers, Pieces, Timeout, OnProgress, OnActivity) ->
    Options = [
        {connect_timeout, Timeout},
        {recv_timeout, Timeout},
        {send_timeout, Timeout}
    ],
    try
        case hackney:request(Method, Url, Headers, stream, Options) of
            {ok, Ref} ->
                case send_pieces(Ref, Pieces, 0, OnProgress) of
                    ok ->
                        ok = hackney:finish_send_body(Ref),
                        case hackney:start_response(Ref) of
                            {ok, Status, RespHeaders, ResponseRef} ->
                                read_body(ResponseRef, Status, RespHeaders, [], 0, OnActivity);
                            {error, Reason} ->
                                close_request(Ref),
                                classify(Reason)
                        end;
                    {error, Reason} ->
                        close_request(Ref),
                        classify(Reason)
                end;
            {error, Reason} ->
                classify(Reason)
        end
    catch
        Class:Reason2 ->
            {error, {network, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason2]))}}
    end.

send_pieces(_Ref, [], _Sent, _OnProgress) ->
    ok;
send_pieces(Ref, [Piece | Rest], Sent, OnProgress) ->
    case hackney:send_body(Ref, Piece) of
        ok ->
            Sent2 = Sent + byte_size(Piece),
            OnProgress(Sent2),
            send_pieces(Ref, Rest, Sent2, OnProgress);
        {error, Reason} ->
            {error, Reason}
    end.

read_body(Ref, Status, Headers, Acc, Activity, OnActivity) ->
    case hackney:stream_body(Ref) of
        {ok, Data} ->
            OnActivity(),
            read_body(Ref, Status, Headers, [Data | Acc], Activity + 1, OnActivity);
        done ->
            {ok, {Status, Headers, iolist_to_binary(lists:reverse(Acc))}};
        {error, Reason} ->
            close_request(Ref),
            classify(Reason)
    end.

close_request(Ref) ->
    catch hackney:close(Ref),
    ok.

%% hackney's errors, narrowed to what the client tells apart.
classify(timeout) ->
    {error, timeout};
classify(connect_timeout) ->
    {error, timeout};
classify(recv_timeout) ->
    {error, timeout};
classify({error, timeout}) ->
    {error, timeout};
classify(Reason) ->
    {error, {network, reason_to_binary(Reason)}}.

reason_to_binary(Reason) when is_binary(Reason) ->
    Reason;
reason_to_binary(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

%% -------------------------------------------------------------------------
%% WebSocket
%% -------------------------------------------------------------------------

%% ws_start(Url, Headers, TimeoutMs, Subject)
%%
%% Starts a socket owner process and answers its pid at once. Subject is a
%% Gleam Subject(Tagged), compiled to {subject, OwnerPid, Tag}; the owner sends
%% it {tagged, self(), Event}, where Event is opened, {open_failed, Error},
%% {frames, [Frame]} or {socket_error, Reason}.
%%
%% Frames, as the Gleam type in libduvet/gateway/socket.gleam spells them:
%% {text_frame, Binary} | {binary_frame, Binary} | {close_frame, Code, Reason}
%% | socket_closed | ping | pong.
%%
%% The owner stops, closing the connection, when the subject's owner (the
%% process that will use the socket) exits.
ws_start(Url, Headers, Timeout, Subject) ->
    spawn(fun() -> ws_owner(Url, Headers, Timeout, Subject) end).

ws_owner(Url, Headers, Timeout, Subject) ->
    ParentRef = erlang:monitor(process, subject_owner(Subject, self())),
    _ = application:ensure_all_started(gun),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case open_connection(Url, Deadline) of
        {ok, ConnPid} ->
            case upgrade(ConnPid, Url, Headers, Deadline) of
                {ok, StreamRef} ->
                    subject_send(Subject, {tagged, self(), opened}),
                    ws_loop(ConnPid, StreamRef, Subject, ParentRef);
                {error, Error} ->
                    catch gun:close(ConnPid),
                    subject_send(Subject, {tagged, self(), {open_failed, Error}})
            end;
        {error, Error} ->
            subject_send(Subject, {tagged, self(), {open_failed, Error}})
    end.

open_connection(Url, Deadline) ->
    try uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Parsed ->
            Scheme = to_binary(Scheme0),
            Host = to_list(to_binary(Host0)),
            Port = maps:get(port, Parsed, default_port(Scheme)),
            Options0 = #{protocols => [http], supervise => false},
            Options = case Scheme of
                <<"wss">> -> Options0#{transport => tls, tls_opts => tls_options(Host)};
                <<"https">> -> Options0#{transport => tls, tls_opts => tls_options(Host)};
                _ -> Options0#{transport => tcp}
            end,
            case gun:open(Host, Port, Options) of
                {ok, ConnPid} ->
                    Left = remaining(Deadline),
                    case gun:await_up(ConnPid, Left) of
                        {ok, _Protocol} -> {ok, ConnPid};
                        {error, timeout} ->
                            catch gun:close(ConnPid),
                            {error, timeout};
                        {error, Reason} ->
                            catch gun:close(ConnPid),
                            {error, {network, reason_to_binary(Reason)}}
                    end;
                {error, Reason} ->
                    {error, {network, reason_to_binary(Reason)}}
            end;
        _ ->
            {error, {network, <<"the gateway URL is not one">>}}
    catch
        _:_ ->
            {error, {network, <<"the gateway URL is not one">>}}
    end.

upgrade(ConnPid, Url, Headers, Deadline) ->
    Parsed = uri_string:parse(Url),
    Path0 = to_binary(maps:get(path, Parsed, <<"/">>)),
    Path = case maps:get(query, Parsed, undefined) of
        undefined -> Path0;
        Query -> <<Path0/binary, "?", (to_binary(Query))/binary>>
    end,
    Ref = gun:ws_upgrade(ConnPid, Path, Headers),
    case gun:await(ConnPid, Ref, remaining(Deadline)) of
        {upgrade, _Protocols, _ResponseHeaders} ->
            {ok, Ref};
        {response, _Fin, Status, _ResponseHeaders} ->
            {error, {http_error, Status}};
        {error, timeout} ->
            {error, timeout};
        {error, Reason} ->
            {error, {network, reason_to_binary(Reason)}}
    end.

ws_loop(ConnPid, StreamRef, Subject, ParentRef) ->
    receive
        {gun_ws, ConnPid, StreamRef, Frame} ->
            subject_send(Subject, {tagged, self(), {frames, [normalize_gun(Frame)]}}),
            case is_close_gun(Frame) of
                true ->
                    catch gun:close(ConnPid),
                    ok;
                false ->
                    ws_loop(ConnPid, StreamRef, Subject, ParentRef)
            end;
        {gun_ws, ConnPid, _OtherRef, _Frame} ->
            ws_loop(ConnPid, StreamRef, Subject, ParentRef);
        {gun_down, ConnPid, _Protocol, Reason, _Killed} ->
            _ = Reason,
            subject_send(Subject, {tagged, self(), {frames, [socket_closed]}});
        {gun_error, ConnPid, Reason} ->
            subject_send(
                Subject,
                {tagged, self(), {socket_error, reason_to_binary(Reason)}}
            );
        {gun_error, ConnPid, _Ref, Reason} ->
            subject_send(
                Subject,
                {tagged, self(), {socket_error, reason_to_binary(Reason)}}
            );
        {gun_response, ConnPid, _Ref, _Fin, _Status, _Headers} ->
            ws_loop(ConnPid, StreamRef, Subject, ParentRef);
        {ws_send, From, Tag, Text} ->
            Result = try gun:ws_send(ConnPid, StreamRef, {text, Text}) of
                ok -> ok
            catch
                Class:Reason -> {error, {Class, Reason}}
            end,
            From ! {Tag, Result},
            ws_loop(ConnPid, StreamRef, Subject, ParentRef);
        {ws_close, Code, Reason} ->
            catch gun:ws_send(ConnPid, StreamRef, {close, Code, Reason}),
            catch gun:close(ConnPid),
            ok;
        {'DOWN', ParentRef, process, _, _} ->
            catch gun:close(ConnPid),
            ok;
        _Other ->
            ws_loop(ConnPid, StreamRef, Subject, ParentRef)
    end.

is_close_gun(close) -> true;
is_close_gun({close, _, _}) -> true;
is_close_gun(_) -> false.

normalize_gun({text, Bin}) -> {text_frame, Bin};
normalize_gun({binary, Bin}) -> {binary_frame, Bin};
normalize_gun(close) -> socket_closed;
normalize_gun({close, Code, Reason}) -> {close_frame, Code, code_to_binary(Reason)};
normalize_gun(ping) -> ping;
normalize_gun({ping, _}) -> ping;
normalize_gun(pong) -> pong;
normalize_gun({pong, _}) -> pong;
normalize_gun(_Other) -> socket_closed.

code_to_binary(Reason) when is_binary(Reason) -> Reason;
code_to_binary(Reason) -> reason_to_binary(Reason).

subject_send({subject, Owner, Tag}, Message) ->
    Owner ! {Tag, Message},
    ok;
subject_send(_Other, _Message) ->
    ok.

subject_owner({subject, Owner, _Tag}, _Default) ->
    Owner;
subject_owner(_Other, Default) ->
    Default.

%% Sends one text frame through the socket's owner, so that every write goes
%% out from the process that owns the connection, in the order it was asked.
ws_send(Owner, Text) ->
    MRef = erlang:monitor(process, Owner),
    Tag = make_ref(),
    Owner ! {ws_send, self(), Tag, Text},
    receive
        {Tag, ok} ->
            erlang:demonitor(MRef, [flush]),
            {ok, nil};
        {Tag, {error, Reason}} ->
            erlang:demonitor(MRef, [flush]),
            {error, reason_to_binary(Reason)};
        {'DOWN', MRef, process, _, _} ->
            {error, <<"the socket closed">>}
    after 5000 ->
        erlang:demonitor(MRef, [flush]),
        {error, <<"timeout">>}
    end.

%% ws_close(Owner, Code, Reason) starts the closing handshake and closes the
%% connection at once, so the gateway sees it end (a gateway may never answer
%% the handshake, and a lingering socket would count as another).
ws_close(Owner, Code, Reason) ->
    Owner ! {ws_close, Code, Reason},
    nil.

%% -------------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------------

remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

default_port(<<"wss">>) -> 443;
default_port(<<"https">>) -> 443;
default_port(_) -> 80.

tls_options(Host) ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Host}
    ].

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> list_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> binary_to_list(Value).
