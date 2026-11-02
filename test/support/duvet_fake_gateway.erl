%% A gateway on 127.0.0.1 for the tests: a raw HTTP + WebSocket server that
%% keeps sessions as the real gateway does (services/user.go's
%% OnIdentifyMessage, connection/session.go's Resume and SendCloseReason).
%%
%% It answers each upgrade request as the plan says (upgrade, refuse with a
%% status, or never answer), reads the client's masked frames, and answers an
%% identify with READY for a new session or with the events it missed for one
%% it resumes, and a heartbeat with heartbeat_ack.
%%
%% Frames it writes go out one write each (push/3), or several in one write
%% (write_batch/2), which on loopback the client reads at once.
%%
%% All state lives in one process; the test drives it through call/2.
-module(duvet_fake_gateway).

-export([
    start/0,
    port/1,
    stop/1,
    set_plan/2,
    tokens/1,
    token_times/1,
    identified/1,
    wait_identifies/2,
    open_count/1,
    most_open/1,
    connection_count/1,
    push/3,
    push_bare/3,
    drop/1,
    close_with_reason/3,
    write_batch/2,
    set_resumes/2,
    set_answers_resumes/2,
    heartbeats/1,
    wait_heartbeats/2
]).

-define(CALL_TIMEOUT, 10000).

call(Server, Request) ->
    Ref = make_ref(),
    Server ! {call, self(), Ref, Request},
    receive
        {Ref, Reply} -> Reply
    after ?CALL_TIMEOUT ->
        {error, timeout}
    end.

start() ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {reuseaddr, true},
        {packet, raw},
        {ip, {127, 0, 0, 1}}
    ]),
    {ok, Port} = inet:port(Listen),
    Server = spawn(fun() -> init(Listen, Port) end),
    ok = gen_tcp:controlling_process(Listen, Server),
    Server ! go,
    Server.

port(Server) -> call(Server, port).
stop(Server) -> call(Server, stop), nil.

%% The plan, consumed one answer per upgrade request; past its end, upgrade.
%% Answers: upgrade | {refuse, Status} | hold.
set_plan(Server, Plan) -> call(Server, {set_plan, Plan}), nil.

tokens(Server) ->
    [case T of undefined -> <<>>; _ -> T end || T <- call(Server, tokens)].

%% Milliseconds of each upgrade request, in order.
token_times(Server) -> call(Server, token_times).

%% The identify payloads, in order, as JSON binaries.
identified(Server) -> call(Server, identified).

wait_identifies(Server, Count) -> call(Server, {wait, identifies, Count}), nil.

open_count(Server) -> call(Server, open_count).
most_open(Server) -> call(Server, most_open).
connection_count(Server) -> call(Server, connection_count).

%% Pushes an event into the current session, with its next sequence number.
%% With no socket open it is only kept, for a resume.
push(Server, Type, DataJson) -> call(Server, {push, Type, DataJson}), nil.

%% Sends an event with no sequence number, on the open socket only.
push_bare(Server, Type, DataJson) -> call(Server, {push_bare, Type, DataJson}), nil.

%% Closes the socket with no close frame, as a network failure does.
drop(Server) -> call(Server, drop), nil.

%% Says why, then closes the socket, as SendCloseReason does.
close_with_reason(Server, Code, Reason) ->
    call(Server, {close_with_reason, Code, unicode:characters_to_binary(Reason)}), nil.

%% Writes the frames in one write: [{raw_text, Json}] | [{raw_close, Code}].
write_batch(Server, Frames) -> call(Server, {write_batch, Frames}), nil.

set_resumes(Server, Resumes) -> call(Server, {set_resumes, Resumes}), nil.

set_answers_resumes(Server, Answers) ->
    call(Server, {set_answers_resumes, Answers}), nil.

heartbeats(Server) -> call(Server, heartbeats).

wait_heartbeats(Server, Count) -> call(Server, {wait, heartbeats, Count}), nil.

%% -------------------------------------------------------------------------
%% Server
%% -------------------------------------------------------------------------

-record(state, {
    listen,
    port,
    plan = [],
    tokens = [],
    identified = [],
    socks = #{},
    held = [],
    most_open = 0,
    total = 0,
    sessions = #{},
    current = undefined,
    current_token = undefined,
    socket = undefined,
    resumes = true,
    answers_resumes = true,
    heartbeats = 0,
    waiters = []
}).

init(Listen, Port) ->
    receive go -> ok end,
    Server = self(),
    Acceptor = spawn_link(fun() -> accept_loop(Server, Listen) end),
    ok = gen_tcp:controlling_process(Listen, Acceptor),
    Acceptor ! go,
    loop(#state{listen = Listen, port = Port}).

%% Accepts one connection at a time, handing each to a handler of its own, so
%% the server process stays free to answer the test's calls.
accept_loop(Server, Listen) ->
    receive go -> ok end,
    accept_loop2(Server, Listen).

accept_loop2(Server, Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            ok = inet:setopts(Socket, [{active, false}]),
            Handler = spawn(fun() -> handle(Server, Socket) end),
            ok = gen_tcp:controlling_process(Socket, Handler),
            Handler ! go,
            accept_loop2(Server, Listen);
        {error, closed} ->
            ok;
        {error, Reason} ->
            Server ! {from_handler, {accept_error, Reason}},
            accept_loop2(Server, Listen)
    end.

loop(State) ->
    receive
        {call, From, Ref, Request} ->
            loop(reply(Request, From, Ref, State));
        {from_handler, Request} ->
            loop(handler_message(Request, State))
    end.

reply(port, From, Ref, State = #state{port = Port}) ->
    From ! {Ref, Port},
    State;
reply({set_plan, Plan}, From, Ref, State) ->
    From ! {Ref, ok},
    State#state{plan = Plan};
reply(tokens, From, Ref, State = #state{tokens = Tokens}) ->
    From ! {Ref, [T || {T, _Ms} <- lists:reverse(Tokens)]},
    State;
reply(token_times, From, Ref, State = #state{tokens = Tokens}) ->
    From ! {Ref, [Ms || {_, Ms} <- lists:reverse(Tokens)]},
    State;
reply(identified, From, Ref, State = #state{identified = Ids}) ->
    From ! {Ref, lists:reverse(Ids)},
    State;
reply(open_count, From, Ref, State = #state{socks = Socks}) ->
    From ! {Ref, maps:size(Socks)},
    State;
reply(most_open, From, Ref, State = #state{most_open = Most}) ->
    From ! {Ref, Most},
    State;
reply(connection_count, From, Ref, State = #state{total = Total}) ->
    From ! {Ref, Total},
    State;
reply(heartbeats, From, Ref, State = #state{heartbeats = N}) ->
    From ! {Ref, N},
    State;
reply({set_resumes, Resumes}, From, Ref, State) ->
    From ! {Ref, ok},
    State#state{resumes = Resumes};
reply({set_answers_resumes, Answers}, From, Ref, State) ->
    From ! {Ref, ok},
    State#state{answers_resumes = Answers};
reply({wait, Kind, Count}, From, Ref, State) ->
    case reached(Kind, Count, State) of
        true ->
            From ! {Ref, ok},
            State;
        false ->
            State#state{waiters = [{Kind, Count, From, Ref} | State#state.waiters]}
    end;
reply({next_plan, Token}, From, Ref, State = #state{plan = Plan, tokens = Tokens, total = Total}) ->
    {Answer, Plan2} = case Plan of
        [] -> {upgrade, []};
        [First | Rest] -> {First, Rest}
    end,
    From ! {Ref, Answer},
    State#state{
        plan = Plan2,
        tokens = [{Token, now_ms()} | Tokens],
        total = Total + 1
    };
reply(stop, From, Ref, State) ->
    From ! {Ref, ok},
    stop_all(State),
    exit(normal);
reply({push, Type, DataJson}, From, Ref, State) ->
    State2 = push_event(Type, decode_data(DataJson), State),
    From ! {Ref, ok},
    State2;
reply({push_bare, Type, DataJson}, From, Ref, State) ->
    Frame = #{
        <<"event">> => <<"payload">>,
        <<"op">> => 1,
        <<"d">> => #{<<"type">> => Type, <<"data">> => decode_data(DataJson)}
    },
    send_current(encode_text(enc(Frame)), State),
    From ! {Ref, ok},
    State;
reply(drop, From, Ref, State) ->
    State2 = close_current(State),
    From ! {Ref, ok},
    State2;
reply({close_with_reason, Code, Reason}, From, Ref, State) ->
    Close = #{
        <<"event">> => <<"close-with-reason">>,
        <<"code">> => Code,
        <<"reason">> => Reason
    },
    send_current(encode_text(enc(Close)), State),
    State2 = case State of
        #state{socket = undefined} -> State;
        #state{socket = Pid, socks = Socks} ->
            case maps:get(Pid, Socks, undefined) of
                undefined -> State;
                #{socket := Tcp} ->
                    catch gen_tcp:send(Tcp, encode_close(1000, Reason)),
                    catch gen_tcp:close(Tcp),
                    State#state{
                        socks = maps:remove(Pid, Socks),
                        socket = undefined,
                        current = undefined
                    }
            end
    end,
    From ! {Ref, ok},
    State2;
reply({write_batch, Frames}, From, Ref, State) ->
    Bytes = iolist_to_binary([encode_raw(F) || F <- Frames]),
    send_current(Bytes, State),
    From ! {Ref, ok},
    State;
reply(Request, From, Ref, State) ->
    From ! {Ref, {error, {unknown_request, Request}}},
    State.

stop_all(#state{listen = Listen, socks = Socks, held = Held}) ->
    catch gen_tcp:close(Listen),
    maps:foreach(fun(_, #{socket := Socket}) -> catch gen_tcp:close(Socket) end, Socks),
    lists:foreach(fun(Socket) -> catch gen_tcp:close(Socket) end, Held),
    ok.

%% -------------------------------------------------------------------------
%% Handler: one per TCP socket
%% -------------------------------------------------------------------------

handle(Server, Socket) ->
    receive go -> ok end,
    case read_request(Socket, <<>>) of
        {ok, PathQuery} ->
            Token = token_of(PathQuery),
            case call(Server, {next_plan, Token}) of
                upgrade ->
                    upgrade(Socket, Server);
                {refuse, Status} ->
                    refuse(Socket, Status);
                hold ->
                    hold(Socket, Server);
                _ ->
                    refuse(Socket, 500)
            end;
        {error, _} ->
            catch gen_tcp:close(Socket)
    end.

read_request(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        {At, 4} ->
            <<Head:At/binary, _:4/binary, _/binary>> = Buffer,
            [RequestLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
            [_Method, PathAndQuery | _] = binary:split(RequestLine, <<" ">>, [global]),
            put(request_headers, [parse_header(Line) || Line <- HeaderLines, Line =/= <<>>]),
            {ok, PathAndQuery};
        nomatch ->
            case gen_tcp:recv(Socket, 0, ?CALL_TIMEOUT) of
                {ok, Data} -> read_request(Socket, <<Buffer/binary, Data/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

parse_header(Line) ->
    [Name, Value] = binary:split(Line, <<": ">>),
    {string:lowercase(Name), Value}.

token_of(PathQuery) ->
    case binary:split(PathQuery, <<"?">>) of
        [_Path, Query] -> query_value(Query, <<"token">>);
        _ -> undefined
    end.

query_value(<<>>, _Key) -> undefined;
query_value(Query, Key) ->
    Pairs = binary:split(Query, <<"&">>, [global]),
    case [V || P <- Pairs, {K, V} <- [pair(P)], K =:= Key] of
        [Value | _] -> urldecode(Value);
        [] -> undefined
    end.

pair(P) ->
    case binary:split(P, <<"=">>) of
        [K, V] -> {K, V};
        [K] -> {K, <<>>}
    end.

urldecode(Bin) -> urldecode(Bin, <<>>).

urldecode(<<>>, Acc) -> Acc;
urldecode(<<"%", A:8, B:8, Rest/binary>>, Acc) ->
    urldecode(Rest, <<Acc/binary, (binary_to_integer(<<A, B>>, 16))>>);
urldecode(<<"+", Rest/binary>>, Acc) -> urldecode(Rest, <<Acc/binary, $\s>>);
urldecode(<<C, Rest/binary>>, Acc) -> urldecode(Rest, <<Acc/binary, C>>).

refuse(Socket, Status) ->
    Response = case Status of
        503 ->
            <<"HTTP/1.1 503 Service Unavailable\r\nRetry-After: 5\r\nContent-Length: 0\r\n\r\n">>;
        401 ->
            <<"HTTP/1.1 401 Unauthorized\r\nContent-Length: 27\r\n\r\n{\"error\":\"invalid token\"}">>;
        _ ->
            <<"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n">>
    end,
    catch gen_tcp:send(Socket, Response),
    catch gen_tcp:close(Socket).

hold(Socket, Server) ->
    Server ! {from_handler, {held, Socket}},
    hold_loop(Socket).

hold_loop(Socket) ->
    case gen_tcp:recv(Socket, 0, infinity) of
        {ok, _} -> hold_loop(Socket);
        {error, _} -> catch gen_tcp:close(Socket)
    end.

upgrade(Socket, Server) ->
    Headers = get(request_headers),
    Key = proplists:get_value(<<"sec-websocket-key">>, Headers, <<>>),
    Accept = base64:encode(crypto:hash(sha, <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
    Response = [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Accept: ">>,
        Accept,
        <<"\r\n\r\n">>
    ],
    ok = gen_tcp:send(Socket, Response),
    Server ! {from_handler, {opened, self(), Socket}},
    read_frames(Socket, Server, <<>>).

read_frames(Socket, Server, Buffer) ->
    case gen_tcp:recv(Socket, 0, infinity) of
        {ok, Data} ->
            case parse_frames(<<Buffer/binary, Data/binary>>, []) of
                {ok, Rest, Payloads} ->
                    lists:foreach(
                        fun(Payload) ->
                            Server ! {from_handler, {client_text, self(), Payload}}
                        end,
                        Payloads
                    ),
                    read_frames(Socket, Server, Rest);
                {error, _} ->
                    Server ! {from_handler, {closed, self()}},
                    catch gen_tcp:close(Socket)
            end;
        {error, _} ->
            Server ! {from_handler, {closed, self()}},
            catch gen_tcp:close(Socket)
    end.

%% Client frames are masked, unfragmented text in these tests.
parse_frames(Buffer, Acc) ->
    case parse_one(Buffer) of
        {ok, Payload, Rest} -> parse_frames(Rest, [Payload | Acc]);
        close -> {ok, <<>>, lists:reverse(Acc)};
        more -> {ok, Buffer, lists:reverse(Acc)}
    end.

parse_one(<<FinOp:8, MaskLen:8, Rest/binary>>) ->
    Opcode = FinOp band 16#0f,
    Masked = (MaskLen band 16#80) =/= 0,
    case payload_length(MaskLen band 16#7f, Rest) of
        {ok, Len, Rest2} ->
            case {Masked, Rest2} of
                {true, <<Mask:4/binary, Payload:Len/binary, Left/binary>>} ->
                    Data = unmask(Payload, Mask),
                    case Opcode of
                        1 -> {ok, Data, Left};
                        8 -> close;
                        _ -> {ok, <<>>, Left}
                    end;
                _ ->
                    more
            end;
        more ->
            more
    end;
parse_one(_) ->
    more.

payload_length(Len, Rest) when Len < 126 -> {ok, Len, Rest};
payload_length(126, <<Len:16, Rest/binary>>) -> {ok, Len, Rest};
payload_length(126, _) -> more;
payload_length(127, <<Len:64, Rest/binary>>) -> {ok, Len, Rest};
payload_length(127, _) -> more.

unmask(Payload, <<A, B, C, D>>) ->
    Mask = {A, B, C, D},
    unmask(Payload, 0, Mask, <<>>).

unmask(<<>>, _I, _Mask, Acc) -> Acc;
unmask(<<Byte, Rest/binary>>, I, Mask, Acc) ->
    M = element((I rem 4) + 1, Mask),
    unmask(Rest, I + 1, Mask, <<Acc/binary, (Byte bxor M)>>).

%% -------------------------------------------------------------------------
%% Handler messages, in the server
%% -------------------------------------------------------------------------

handler_message({held, Socket}, State = #state{held = Held}) ->
    State#state{held = [Socket | Held]};
handler_message({opened, Pid, Socket}, State = #state{
    socks = Socks,
    most_open = Most
}) ->
    Socks2 = Socks#{Pid => #{socket => Socket, silent => false}},
    State#state{
        socks = Socks2,
        current = Pid,
        socket = Pid,
        most_open = max(Most, maps:size(Socks2))
    };
handler_message({closed, Pid}, State = #state{socks = Socks, current = Current, socket = Socket}) ->
    State#state{
        socks = maps:remove(Pid, Socks),
        current = case Current of Pid -> undefined; _ -> Current end,
        socket = case Socket of Pid -> undefined; _ -> Socket end
    };
handler_message({client_text, Pid, Payload}, State) ->
    case decode(Payload) of
        {ok, Message} ->
            case maps:get(<<"type">>, Message, undefined) of
                <<"identify">> ->
                    identify(Pid, maps:get(<<"data">>, Message, #{}), State);
                <<"heartbeat">> ->
                    heartbeat(Pid, State);
                _ ->
                    State
            end;
        error ->
            State
    end;
handler_message(_, State) ->
    State.

decode(Payload) ->
    try
        {ok, json:decode(Payload)}
    catch
        _:_ -> error
    end.

identify(Pid, Data, State = #state{identified = Ids, sessions = Sessions, answers_resumes = Answers, resumes = Resumes}) ->
    State1 = State#state{identified = [enc(Data) | Ids]},
    State2 = notify(identifies, State1),
    SessionToken = maps:get(<<"session_token">>, Data, undefined),
    LastSeq = maps:get(<<"last_seq">>, Data, undefined),
    case {SessionToken, Answers} of
        {Token, false} when Token =/= undefined ->
            set_silent(Pid, true, State2);
        _ ->
            Old = case SessionToken of
                undefined -> undefined;
                _ -> maps:get(SessionToken, Sessions, undefined)
            end,
            case {Old, LastSeq, Resumes} of
                {undefined, _, _} -> new_session(State2);
                {_, undefined, _} -> new_session(State2);
                {_, _, false} -> new_session(State2);
                {OldSession, From, true} -> resume(OldSession, From, State2)
            end
    end.

new_session(State = #state{sessions = Sessions}) ->
    N = maps:size(Sessions) + 1,
    Token = <<"session-", (integer_to_binary(N))/binary>>,
    State1 = State#state{
        sessions = Sessions#{Token => #{seq => 0, frames => []}},
        current_token = Token
    },
    Ready = #{
        <<"user">> => #{
            <<"id">> => <<"u1">>,
            <<"username">> => <<"gaby">>,
            <<"created_at">> => <<"2026-10-23T09:00:00Z">>,
            <<"updated_at">> => <<"2026-10-23T09:00:00Z">>
        },
        <<"sessionToken">> => Token
    },
    push_event(<<"READY">>, Ready, State1).

resume(Session, From, State = #state{sessions = Sessions}) ->
    Frames = maps:get(frames, Session),
    lists:foreach(
        fun(Frame) ->
            case maps:get(<<"s">>, Frame) > From of
                true -> send_current(encode_text(enc(Frame)), State);
                false -> ok
            end
        end,
        Frames
    ),
    Token = hd([T || {T, S} <- maps:to_list(Sessions), S =:= Session]),
    State#state{current_token = Token}.

set_silent(Pid, Silent, State = #state{socks = Socks}) ->
    case Socks of
        #{Pid := Entry} -> State#state{socks = Socks#{Pid => Entry#{silent => Silent}}};
        _ -> State
    end.

heartbeat(Pid, State = #state{heartbeats = N}) ->
    State1 = State#state{heartbeats = N + 1},
    State2 = notify(heartbeats, State1),
    case silent(Pid, State2) of
        true ->
            State2;
        false ->
            send_to(Pid, encode_text(enc(#{<<"event">> => <<"heartbeat_ack">>})), State2),
            State2
    end.

silent(Pid, #state{socks = Socks}) ->
    case Socks of
        #{Pid := Entry} -> maps:get(silent, Entry, false);
        _ -> false
    end.

notify(Kind, State = #state{waiters = Waiters}) ->
    case lists:partition(fun({K, Count, _From, _Ref}) ->
            K =:= Kind andalso reached(K, Count, State)
        end, Waiters) of
        {[], _} ->
            State;
        {Reached, Remaining} ->
            lists:foreach(fun({_, _, From, Ref}) -> From ! {Ref, ok} end, Reached),
            State#state{waiters = Remaining}
    end.

reached(identifies, Count, #state{identified = Ids}) -> length(Ids) >= Count;
reached(heartbeats, Count, #state{heartbeats = N}) -> N >= Count.

%% -------------------------------------------------------------------------
%% Sending
%% -------------------------------------------------------------------------

push_event(Type, Data, State = #state{current_token = Token, sessions = Sessions}) ->
    case Token of
        undefined ->
            State;
        _ ->
            Session = maps:get(Token, Sessions),
            Seq = maps:get(seq, Session) + 1,
            Frame = #{
                <<"event">> => <<"payload">>,
                <<"op">> => 1,
                <<"s">> => Seq,
                <<"d">> => #{<<"type">> => Type, <<"data">> => Data}
            },
            Session2 = Session#{seq => Seq, frames => maps:get(frames, Session) ++ [Frame]},
            send_current(encode_text(enc(Frame)), State),
            State#state{sessions = Sessions#{Token => Session2}}
    end.

close_current(State = #state{socket = Socket, socks = Socks}) ->
    case Socket of
        undefined ->
            State;
        _ ->
            case maps:get(Socket, Socks, undefined) of
                undefined ->
                    State;
                #{socket := Tcp} ->
                    catch gen_tcp:close(Tcp),
                    State#state{
                        socks = maps:remove(Socket, Socks),
                        socket = undefined,
                        current = undefined
                    }
            end
    end.

send_current(Bytes, #state{socket = Socket, socks = Socks}) ->
    case Socket of
        undefined -> ok;
        _ ->
            case maps:get(Socket, Socks, undefined) of
                undefined -> ok;
                #{socket := Tcp} -> catch gen_tcp:send(Tcp, Bytes), ok
            end
    end.

send_to(Pid, Bytes, #state{socks = Socks}) ->
    case maps:get(Pid, Socks, undefined) of
        undefined -> ok;
        #{socket := Tcp} -> catch gen_tcp:send(Tcp, Bytes), ok
    end.

decode_data(Json) when is_binary(Json) ->
    case decode(Json) of
        {ok, Value} -> Value;
        error -> #{}
    end;
decode_data(Value) -> Value.

encode_raw({raw_text, Json}) -> encode_text(Json);
encode_raw({raw_close, Code}) -> encode_close(Code, <<>>).

encode_text(Bin) ->
    encode_frame(1, Bin).

encode_close(Code, Reason) ->
    encode_frame(8, <<Code:16, Reason/binary>>).

encode_frame(Opcode, Payload) ->
    Len = byte_size(Payload),
    Header = case Len of
        N when N < 126 -> <<(16#80 bor Opcode), N>>;
        N when N < 65536 -> <<(16#80 bor Opcode), 126, N:16>>;
        N -> <<(16#80 bor Opcode), 127, N:64>>
    end,
    <<Header/binary, Payload/binary>>.

enc(Term) ->
    iolist_to_binary(json:encode(Term)).

now_ms() ->
    erlang:system_time(millisecond).
