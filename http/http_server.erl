-module(http_server).
-export([start/0, start/1, stop/1, get_views/1]).

-record(request, {
    method  = undef,
    path    = undef,
    version = undef,
    headers = #{}
}).

parse_request(Sock) -> parse_request(Sock, #request{}).

parse_request(Sock, Req) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, {http_request, Method, {abs_path, Path}, Ver}} ->
            Req1 = Req#request{method = Method,
                path = Path, 
                version = Ver},
            parse_request(Sock, Req1);
        {ok, {http_request, _, Name, _, Value}} ->
            Headers = Req#request.headers,
            Headers1 = Headers#{Name => Value},
            Req1 = Req#request{headers = Headers1},
            parse_request(Sock, Req1);
        {ok, http_eoh} -> {ok, Req};
        {ok, {http_error, Error}} -> {error, Error};
        {error, closed} -> ignore;
        {error, Error} -> {error, Error};
        Data -> {error, Data}
    end.

random_phrase() ->
    Number = rand:uniform(21),
    if
        Number < 8 -> "Greetings from Erlang!";
        Number < 14 -> "Yep.. That's Erlang!";
        Number < 21 -> "Erlang is cool!";
        true -> "Whaaaat"
    end.

handle_request(Sock, Views) ->
    case parse_request(Sock) of
        ignore -> close;
        {ok, Req = #request{}} ->
            {Resp, KA} = get_response(Req, Views),
            gen_tcp:send(Sock, Resp),
            case KA of
                true -> loop;
                false -> close
            end;
        {error, Error} ->
            io:format("Error: ~p~n", [Error]),
            gen_tcp:send(Sock, [
                <<"HTTP/1.0 500 Internal Error\r\n">>,
                <<"Access-Control-Allow-Origin: *\r\n">>,
                <<"\r\n\r\n">>,
                Error
            ]),
            close
    end.

format_views(1) -> ["There is 1 view already!"];
format_views(N) -> ["There are ", integer_to_list(N), " views already!"].

get_body(#request{path = Path}, Views) ->
    ViewCnt = get_views(Path, Views),
    Body = ["The page '", Path,
            "' is cool, isn't it?\r\n",
            format_views(ViewCnt)],
    {Body, iolist_size(Body)}.

is_keep_alive(#request{headers = #{'Connection' := Conn}}) ->
    string:to_lower(Conn) =:= "keep-alive";
is_keep_alive(_) -> false.

get_headers(KA, CLen) ->
    Conn = case KA of
        true -> {"Connection", "keep-alive"};
        false -> {"Connection", "close"}
    end,
    ContLen = {"Connection-Length",
                integer_to_list(CLen)},
    Headers = [Conn, ContLen],
    [ [Name, ": ", Value, "\r\n"]
        || {Name, Value} <- Headers].

get_views(Path, Views) ->
    ets:update_counter(Views, Path, 1, {Path, 0}).

get_response(Req, Views) ->
    {Body, CLen} = get_body(Req, Views),
    IsKA  = is_keep_alive(Req),
    Headers = get_headers(IsKA, CLen),
    Resp = iolist_to_binary([<<"HTTP/1.0 200 OK\r\n">>,
            <<"Access-Control-Allow-Origin: *\r\n">>,
            <<Headers/binary>>,
            <<"\r\n\r\n">>,
            <<Body/binary>>]),
    {Resp, IsKA}.

accept_loop(LSock, Views) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            spawn(fun() -> handle_loop(Sock, Views) end),
            accept_loop(LSock, Views);
        _ -> ok
    end.

handle_loop(Sock, Views) ->
    case handle_request(Sock, Views) of
        loop -> handle_loop(Sock, Views);
        close -> gen_tcp:close(Sock)
    end.

start() -> start(8080).
start(Port) ->
    spawn(fun() ->
        Views = ets:new(request_count, [set, public]),

        Opts = [{packet, http},
                {active, false},
                {backlog, 1024}],
        {ok, LSock} = gen_tcp:listen(Port, Opts),
        spawn(fun() -> accept_loop(LSock, Views) end),
        command_loop(LSock, Views)
    end).

command_loop(LSock, Views) ->
    receive
        stop ->
            gen_tcp:close(LSock);
        {get_views, Caller} ->
            Data = ets:tab2list(Views),
            Caller ! {views, Data},
            command_loop(LSock, Views)
    end.

stop(Pid) ->
    Pid ! stop.

get_views(Pid) ->
    Pid ! {get_views, self()},
    receive
        {views, Views} -> Views
    end.