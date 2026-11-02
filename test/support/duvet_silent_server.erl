%% Servers on 127.0.0.1 for the timeout tests.
%%
%% start(Reading) takes connections and never answers; while Reading is false
%% it doesn't read either, so what a client sends backs up, as on a stalled
%% network. resume/1 makes it read, which is when it sees the client drop.
%%
%% start_slow(Json) reads a request's body a piece at a time, 5ms apart, then
%% answers Json; received/1 counts the body bytes it read.
-module(duvet_silent_server).

-export([
    start/1,
    start_slow/1,
    port/1,
    dropped/1,
    resume/1,
    received/1,
    stop/1
]).

start(Reading) ->
    listen(fun(Socket, Server) -> silent(Socket, Server, Reading) end).

start_slow(Json) ->
    listen(fun(Socket, Server) -> slow(Socket, Server, Json) end).

listen(Handler) ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {reuseaddr, true},
        {packet, raw},
        {buffer, 262144},
        {recbuf, 262144},
        {ip, {127, 0, 0, 1}}
    ]),
    {ok, Port} = inet:port(Listen),
    Server = spawn(fun() -> init(Listen, Port, Handler) end),
    ok = gen_tcp:controlling_process(Listen, Server),
    Server ! go,
    Server.

port(Server) -> call(Server, port).
dropped(Server) -> call(Server, dropped).
resume(Server) -> call(Server, resume).
received(Server) -> call(Server, received).
stop(Server) -> call(Server, stop).

call(Server, Request) ->
    Ref = make_ref(),
    Server ! {call, self(), Ref, Request},
    receive
        {Ref, Reply} -> Reply
    after 10000 ->
        {error, timeout}
    end.

init(Listen, Port, Handler) ->
    receive go -> ok end,
    Server = self(),
    Acceptor = spawn_link(fun() -> accept_loop(Server, Listen, Handler) end),
    ok = gen_tcp:controlling_process(Listen, Acceptor),
    Acceptor ! go,
    loop(#{port => Port, handlers => [], dropped => 0, waiters => [], received => 0}).

accept_loop(Server, Listen, Handler) ->
    receive go -> ok end,
    accept_loop2(Server, Listen, Handler).

accept_loop2(Server, Listen, Handler) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            ok = inet:setopts(Socket, [{active, false}]),
            Pid = spawn_link(fun() -> Handler(Socket, Server) end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Pid ! go,
            accept_loop2(Server, Listen, Handler);
        {error, _} ->
            ok
    end.

loop(State) ->
    receive
        {call, From, Ref, port} ->
            From ! {Ref, maps:get(port, State)},
            loop(State);
        {call, From, Ref, dropped} ->
            case maps:get(dropped, State) > 0 of
                true ->
                    From ! {Ref, ok},
                    loop(State);
                false ->
                    Waiters = maps:get(waiters, State),
                    loop(State#{waiters => [{From, Ref} | Waiters]})
            end;
        {call, From, Ref, resume} ->
            lists:foreach(
                fun(Pid) -> Pid ! resume end,
                maps:get(handlers, State)
            ),
            From ! {Ref, ok},
            loop(State);
        {call, From, Ref, received} ->
            From ! {Ref, maps:get(received, State)},
            loop(State);
        {call, From, Ref, stop} ->
            From ! {Ref, ok},
            exit(shutdown);
        {handler, Pid, registered} ->
            Handlers = maps:get(handlers, State),
            loop(State#{handlers => [Pid | Handlers]});
        {handler, _Pid, closed} ->
            Dropped = maps:get(dropped, State) + 1,
            Waiters = maps:get(waiters, State),
            lists:foreach(fun({From, Ref}) -> From ! {Ref, ok} end, Waiters),
            loop(State#{dropped => Dropped, waiters => []});
        {handler, _Pid, received, Bytes} ->
            loop(State#{received => Bytes})
    end.

%% A silent server: never answers, and only reads when Reading.
silent(Socket, Server, Reading) ->
    receive go -> ok end,
    Server ! {handler, self(), registered},
    case Reading of
        true -> read_and_ignore(Socket, Server);
        false ->
            receive
                resume -> read_and_ignore(Socket, Server);
                stop -> catch gen_tcp:close(Socket)
            end
    end.

read_and_ignore(Socket, Server) ->
    case gen_tcp:recv(Socket, 0, infinity) of
        {ok, _} -> read_and_ignore(Socket, Server);
        {error, _} ->
            catch gen_tcp:close(Socket),
            Server ! {handler, self(), closed}
    end.

%% Reads one request's body slowly, then answers it.
slow(Socket, Server, Json) ->
    receive go -> ok end,
    Server ! {handler, self(), registered},
    case read_headers(Socket, <<>>) of
        {ok, Rest, ContentLength} ->
            Received = read_body(Socket, Rest, ContentLength, 0),
            Server ! {handler, self(), received, Received},
            Response = [
                <<"HTTP/1.1 200 OK\r\n">>,
                <<"Content-Type: application/json\r\n">>,
                <<"Content-Length: ">>,
                integer_to_binary(byte_size(Json)),
                <<"\r\n\r\n">>,
                Json
            ],
            catch gen_tcp:send(Socket, Response),
            catch gen_tcp:close(Socket);
        {error, _} ->
            catch gen_tcp:close(Socket),
            Server ! {handler, self(), closed}
    end.

read_headers(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        {At, 4} ->
            <<Head:At/binary, _:4/binary, Rest/binary>> = Buffer,
            Lines = binary:split(Head, <<"\r\n">>, [global]),
            {ok, Rest, content_length(Lines)};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 10000) of
                {ok, Data} -> read_headers(Socket, <<Buffer/binary, Data/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

content_length([Line | Rest]) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            case string:lowercase(string:trim(Name)) of
                <<"content-length">> -> binary_to_integer(string:trim(Value));
                _ -> content_length(Rest)
            end;
        _ ->
            content_length(Rest)
    end;
content_length([]) ->
    0.

read_body(_Socket, _Buffer, 0, Received) ->
    Received;
read_body(Socket, Buffer, Remaining, Received) when byte_size(Buffer) >= Remaining ->
    timer:sleep(5),
    Received + Remaining;
read_body(Socket, Buffer, Remaining, Received) ->
    timer:sleep(5),
    Received2 = Received + byte_size(Buffer),
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Data} -> read_body(Socket, Data, Remaining - byte_size(Buffer), Received2);
        {error, _} -> Received2
    end.
