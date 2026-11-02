%% The only module in libduvet that touches hackney (and Erlang atoms).
%%
%% Gleam has no Atom type, so every hackney option, every hackney message tag
%% and every hackney error shape is translated here into the plain Erlang
%% terms that the Gleam types in this library compile to. Keep it that way:
%% no other module should need hackney.
%%
%% REST: request/6 performs a whole exchange with a streamed request body and
%% a streamed response, reporting progress to a Gleam fun. The caller must run
%% it in a process it can kill: killing that process closes the connection
%% (hackney monitors the process that started the request), which is how
%% libduvet aborts a request or times it out.
%%
%% WebSocket: ws_open/4 starts a socket owner process. The owner performs the
%% upgrade, then forwards each read's frames to a Gleam subject as one batch,
%% so the client sees the order the gateway wrote them in (frames from one
%% read together, the way dart:io hands them over). The owner stops, closing
%% the socket, when the process that opened it (or the subject's owner) exits.
-module(duvet_hackney_ffi).

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
%% bytes sent or received so far).
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
%% Gleam Subject(Event), compiled to {subject, OwnerPid, Tag}; the owner sends
%% it {opened} when the upgrade is done, {open_failed, Error} when it isn't,
%% {frames, [Frame]} for each read's frames, and {socket_error, Reason}.
%%
%% The owner stops, closing the socket, when the subject's owner (the process
%% that will use the socket) exits. The caller bounds the upgrade with its own
%% timer and kills the owner if it takes too long, which closes the connection
%% being opened.
%%
%% Frames, as the Gleam type in libduvet/gateway/socket.gleam spells them:
%% {text_frame, Binary} | {binary_frame, Binary} | {close_frame, Code, Reason}
%% | socket_closed | ping | pong.
ws_start(Url, Headers, Timeout, Subject) ->
    spawn(fun() -> ws_owner(Url, Headers, Timeout, Subject) end).

ws_owner(Url, Headers, Timeout, Subject) ->
    ParentRef = erlang:monitor(process, subject_owner(Subject, self())),
    Options = [
        {connect_timeout, Timeout},
        {recv_timeout, infinity},
        {headers, Headers}
    ],
    case hackney:ws_connect(Url, Options) of
        {ok, WsPid} ->
            case hackney:ws_setopts(WsPid, [{active, once}]) of
                ok ->
                    subject_send(Subject, opened),
                    ws_loop(WsPid, Subject, ParentRef);
                {error, Reason} ->
                    catch hackney:ws_close(WsPid),
                    subject_send(Subject, {open_failed, classify_ws(Reason)})
            end;
        {error, Reason} ->
            subject_send(Subject, {open_failed, classify_ws(Reason)})
    end.

ws_loop(WsPid, Subject, ParentRef) ->
    receive
        {hackney_ws, WsPid, Frame} ->
            %% Every frame of one read is already in the mailbox: hackney
            %% parses a read's frames and sends them without yielding, and
            %% only re-arms the socket when ws_setopts is called below.
            Frames = drain(WsPid, [Frame]),
            subject_send(Subject, {frames, [normalize(F) || F <- Frames]}),
            case lists:any(fun is_close/1, Frames) of
                true ->
                    ok;
                false ->
                    case hackney:ws_setopts(WsPid, [{active, once}]) of
                        ok -> ws_loop(WsPid, Subject, ParentRef);
                        {error, _} -> ok
                    end
            end;
        {ws_send, From, Tag, Text} ->
            Result = case hackney:ws_send(WsPid, {text, Text}) of
                ok -> ok;
                {error, Reason} -> {error, Reason}
            end,
            From ! {Tag, Result},
            ws_loop(WsPid, Subject, ParentRef);
        {ws_close, Code, Reason} ->
            catch hackney:ws_close(WsPid, {Code, Reason}),
            ws_loop(WsPid, Subject, ParentRef);
        {hackney_ws, WsPid, closed} ->
            subject_send(Subject, {frames, [socket_closed]});
        {hackney_ws_error, WsPid, Reason} ->
            subject_send(Subject, {socket_error, reason_to_binary(Reason)});
        {'DOWN', ParentRef, process, _, _} ->
            catch hackney:ws_close(WsPid),
            ok;
        {'EXIT', WsPid, _} ->
            subject_send(Subject, {frames, [socket_closed]});
        _Other ->
            ws_loop(WsPid, Subject, ParentRef)
    end.

drain(WsPid, Acc) ->
    receive
        {hackney_ws, WsPid, Frame} ->
            drain(WsPid, [Frame | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

is_close({close, _, _}) -> true;
is_close(closed) -> true;
is_close(_) -> false.

normalize({text, Bin}) -> {text_frame, Bin};
normalize({binary, Bin}) -> {binary_frame, Bin};
normalize({close, Code, Reason}) -> {close_frame, Code, code_to_binary(Reason)};
normalize(closed) -> socket_closed;
normalize(ping) -> ping;
normalize({ping, _}) -> ping;
normalize(pong) -> pong;
normalize({pong, _}) -> pong.

code_to_binary(Reason) when is_binary(Reason) -> Reason;
code_to_binary(Reason) -> reason_to_binary(Reason).

classify_ws({http_error, Status}) ->
    {http_error, Status};
classify_ws(timeout) ->
    timeout;
classify_ws({closed, _}) ->
    {network, <<"closed before the upgrade">>};
classify_ws(Reason) ->
    {network, reason_to_binary(Reason)}.

subject_send({subject, Owner, Tag}, Message) ->
    Owner ! {Tag, Message},
    ok;
subject_send(_Other, _Message) ->
    ok.

subject_owner({subject, Owner, _Tag}, _Default) ->
    Owner;
subject_owner(_Other, Default) ->
    Default.

%% ws_send(Pid, Text) sends one text frame.
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

%% ws_close(Pid, Code, Reason) starts the closing handshake.
ws_close(Owner, Code, Reason) ->
    Owner ! {ws_close, Code, Reason},
    nil.
