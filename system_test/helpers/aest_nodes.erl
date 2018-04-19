-module(aest_nodes).

%=== EXPORTS ===================================================================

%% Common Test API exports
-export([ct_setup/1]).
-export([ct_cleanup/1]).

%% QuickCheck API exports
-export([eqc_setup/2]).
-export([eqc_cleanup/1]).

%% Generic API exports
-export([setup_nodes/2]).
-export([start_node/2]).
-export([stop_node/3]).
-export([kill_node/2]).
-export([extract_archive/4]).
-export([run_cmd_in_node_dir/3]).
-export([connect_node/3]).
-export([disconnect_node/3]).
-export([get_service_address/3]).
-export([http_get/5]).
-export([http_post/7]).

%% Helper function exports
-export([request/4]).
-export([get/5]).
-export([get_block/3]).
-export([get_top/2]).
-export([wait_for_value/4]).

%=== MACROS ====================================================================

-define(BACKENDS, [aest_docker]).
-define(CALL_TAG, ?MODULE).
-define(CT_CONF_KEY, node_manager).
-define(CALL_TIMEOUT, 60000).
-define(NODE_TEARDOWN_TIMEOUT, 0).
-define(DEFAULT_HTTP_TIMEOUT, 3000).

%=== TYPES ====================================================================

-type test_ctx() :: pid() | proplists:proplist().
-type node_service() :: ext_http | int_http | int_ws.
-type http_path() :: [atom() | binary() | number()] | binary().
-type http_query() :: #{atom() | binary() => atom() | binary()}.
-type http_headers() :: [{binary(), binary()}].
-type http_body() :: binary().
-type json_object() :: term().
-type milliseconds() :: non_neg_integer().
-type seconds() :: non_neg_integer().
-type path() :: binary() | string().
-type peer_spec() :: atom() | binary().

-type node_spec() :: #{
    % The unique name of the node
    name    := atom(),
    % If peer is given as an atom it is expected to be a node name,
    % if given as a binary it is expected to be the external URL of the peer.
    peers   := [peer_spec()],
    backend := aest_docker,

%% When `backend` is `aest_docker`:

    % The source of the docker image
    source  := {pull, binary() | string()},
    % Public/private peer key can be specified explicity for the node.
    % Both are required and will be saved, overriding any present keys.
    pubkey => binary(),
    privkey => binary()
}.

%=== COMMON TEST API FUNCTIONS =================================================

%% @doc Setups the the node manager for Common Test.
%% The CT config passed as argument is returned with extra values used
%% to contact with the node manager. This config must be passed to all
%% the the other functions as the `Ctx` parameter.
-spec ct_setup(proplists:proplist()) -> proplists:proplist().
ct_setup(Config) ->
    {data_dir, DataDir} = proplists:lookup(data_dir, Config),
    {priv_dir, PrivDir} = proplists:lookup(priv_dir, Config),
    ct:log("Node logs can be found here: ~n<a href=\"file://~s\">~s</a>",
        [PrivDir, PrivDir]
    ),
    LogFun = fun(Fmt, Args) -> ct:log(Fmt, Args) end,
    case aest_nodes_mgr:start([aest_docker], #{ test_id => uid(),
                                                log_fun => LogFun,
                                                data_dir => DataDir,
                                                temp_dir => PrivDir}) of
        {ok, Pid} -> [{?CT_CONF_KEY, Pid} | Config];
        {error, Reason} ->
            erlang:error({system_test_setup_failed, [{reason, Reason}]})
    end.

%% @doc Stops the node manager and all the nodes that were started.
-spec ct_cleanup(test_ctx()) -> ok.
ct_cleanup(Ctx) ->
    Pid = ctx2pid(Ctx),
    call(Pid, dump_logs),
    call(Pid, cleanup),
    call(Pid, stop),
    wait_for_exit(Pid, 120000),
    ok.

%=== QICKCHECK API FUNCTIONS ===================================================

%% @doc Setups the node manager for Quick Check tests.
-spec eqc_setup(path(), path()) -> test_ctx().
eqc_setup(DataDir, TempDir) ->
    case aest_nodes_mgr:start([aest_docker], #{data_dir => DataDir, temp_dir => TempDir}) of
        {ok, Pid} -> Pid;
        {error, Reason} ->
            erlang:error({system_test_setup_failed, [{reason, Reason}]})
    end.

%% @doc Stops the node manager for QuickCheck tests.
-spec eqc_cleanup(test_ctx()) -> ok.
eqc_cleanup(Ctx) ->
    Pid = ctx2pid(Ctx),
    call(Pid, cleanup),
    call(Pid, stop),
    wait_for_exit(Pid, 120000),
    ok.

%=== GENERIC API FUNCTIONS =====================================================

%% @doc Creates and setups a list of nodes.
%% The nodes are not started, use `start_node/2` for that.
-spec setup_nodes([node_spec()], test_ctx()) -> ok.
setup_nodes(NodeSpecs, Ctx) ->
    call(ctx2pid(Ctx), {setup_nodes, NodeSpecs}).

%% @doc Starts a node previously setup.
-spec start_node(atom(), test_ctx()) -> ok.
start_node(NodeName, Ctx) ->
    call(ctx2pid(Ctx), {start_node, NodeName}).

%% @doc Stops a node previously started with explicit timeout (in seconds)
%% after which the node will be killed.
-spec stop_node(atom(), seconds() | infinity, test_ctx()) -> ok.
stop_node(NodeName, Timeout, Ctx) ->
    call(ctx2pid(Ctx), {stop_node, NodeName, Timeout}).

%% @doc Kills a node.
-spec kill_node(atom(), test_ctx()) -> ok.
kill_node(NodeName, Ctx) ->
    call(ctx2pid(Ctx), {kill_node, NodeName}).

extract_archive(NodeName, Path, Archive, Ctx) ->
    call(ctx2pid(Ctx), {extract_archive, NodeName, Path, Archive}).

run_cmd_in_node_dir(NodeName, Cmd, Ctx) ->
    call(ctx2pid(Ctx), {run_cmd_in_node_dir, NodeName, Cmd}).

%% @doc Connect a node to a network.
-spec connect_node(atom(), atom(), test_ctx()) -> ok.
connect_node(NodeName, NetName, Ctx) ->
    call(ctx2pid(Ctx), {connect_node, NodeName, NetName}).

%% @doc Disconnect a node from a network.
-spec disconnect_node(atom(), atom(), test_ctx()) -> ok.
disconnect_node(NodeName, NetName, Ctx) ->
    call(ctx2pid(Ctx), {disconnect_node, NodeName, NetName}).

%% @doc Retrieves the address of a given node's service.
-spec get_service_address(atom(), node_service(), test_ctx()) -> binary().
get_service_address(NodeName, Service, Ctx) ->
    call(ctx2pid(Ctx), {get_service_address, NodeName, Service}).

%% @doc Performs and HTTP get on a node service (ext_http or int_http).
-spec http_get(atom(), ext_http | int_http, http_path(), http_query(), test_ctx()) ->
        {ok, pos_integer(), json_object()} | {error, term()}.
http_get(NodeName, Service, Path, Query, Ctx) ->
    Addr = get_service_address(NodeName, Service, Ctx),
    http_addr_get(Addr, Path, Query).

-spec http_post(atom(), ext_http | int_http, http_path(), http_query(), http_headers(), http_body(), test_ctx()) ->
        {ok, pos_integer(), json_object()} | {error, term()}.
http_post(NodeName, Service, Path, Query, Headers, Body, Ctx) ->
    Addr = get_service_address(NodeName, Service, Ctx),
    http_addr_post(Addr, Path, Query, Headers, Body).

%=== HELPER FUNCTIONS ==========================================================

%% @doc Performs an HTTP get request on the node external API.
%% Should preferably use `get/5` with service `ext_http`.
-spec request(atom(), http_path(), http_query(), test_ctx) -> json_object().
request(NodeName, Path, Query, Ctx) ->
    get(NodeName, ext_http, Path, Query, Ctx).

%% @doc Performs an HTTP get request on a node HTTP service.
-spec get(atom(), int_http | ext_http, http_path(), http_query(), test_ctx()) -> json_object().
get(NodeName, Service, Path, Query, Ctx) ->
    case http_get(NodeName, Service, Path, Query, Ctx) of
        {ok, 200, Response} -> Response;
        {ok, Status, _Response} -> error({unexpected_status, Status});
        {error, Reason} -> error({http_error, Reason})
    end.

%% @doc Retrieves a block at given height from the given node.
%% It will throw an excpetion if the block does not exists.
-spec get_block(atom(), non_neg_integer(), test_ctx()) -> json_object().
get_block(NodeName, Height, Ctx) ->
    case http_get(NodeName, ext_http, [v2, 'block-by-height'],
                  #{height => Height}, Ctx) of
        {ok, 200, Response} -> Response;
        {ok, Status, _Response} -> error({unexpected_status, Status});
        {error, Reason} -> error({http_error, Reason})
    end.

%% @doc Retrieves the top block from the given node.
-spec get_top(atom(), test_ctx()) -> json_object().
get_top(NodeName, Ctx) ->
    case http_get(NodeName, ext_http, [v2, 'top'], #{}, Ctx) of
        {ok, 200, Response} -> Response;
        {ok, Status, _Response} -> error({unexpected_status, Status});
        {error, Reason} -> error({http_error, Reason})
    end.

%% @doc Waits for each specified nodes to have a block at given heigth.
-spec wait_for_value({balance, binary(), non_neg_integer()}, [atom()], milliseconds(), test_ctx()) -> ok;
                    ({height, non_neg_integer()}, [atom()], milliseconds(), test_ctx()) -> ok.
wait_for_value({balance, PubKey, MinBalance}, NodeNames, Timeout, Ctx) ->
    Addrs = [get_service_address(N, ext_http, Ctx) || N <- NodeNames],
    Expiration = make_expiration(Timeout),
    CheckF =
        fun(Addr) ->
                case http_addr_get(Addr, [v2, account, balance, PubKey], #{}) of
                    {ok, 200, #{balance := Balance}} when Balance >= MinBalance -> done;
                    _ -> wait
                end
        end,
    wait_for_value(CheckF, Addrs, [], 500, Expiration);
wait_for_value({height, MinHeight}, NodeNames, Timeout, Ctx) ->
    Addrs = [get_service_address(N, ext_http, Ctx) || N <- NodeNames],
    Expiration = make_expiration(Timeout),
    CheckF =
        fun(Addr) ->
                case http_addr_get(Addr, [v2, 'block-by-height'], #{height => MinHeight}) of
                    {ok, 200, _} -> done;
                    _ -> wait
                end
        end,
    wait_for_value(CheckF, Addrs, [], 500, Expiration).


%=== INTERNAL FUNCTIONS ========================================================

log(#{log_fun := undefined}, _Fmt, _Args) -> ok;
log(#{log_fun := LogFun}, Fmt, Args) -> LogFun(Fmt, Args).

uid() ->
    iolist_to_binary([[io_lib:format("~2.16.0B",[X])
                       || <<X:8>> <= crypto:strong_rand_bytes(8) ]]).

ctx2pid(Pid) when is_pid(Pid) -> Pid;
ctx2pid(Props) when is_list(Props) ->
    case proplists:lookup(?CT_CONF_KEY, Props) of
        {?CT_CONF_KEY, Pid} when is_pid(Pid) -> Pid;
        _ ->
            erlang:error({system_test_not_setup, []})
    end.

call(Pid, Msg) ->
    case gen_server:call(Pid, Msg, ?CALL_TIMEOUT) of
        {'$error', Reason, Stacktrace} ->
            erlang:raise(throw, Reason, Stacktrace);
        Reply ->
            Reply
    end.

wait_for_exit(Pid, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok
    after Timeout -> error({process_not_stopped, Pid})
    end.

make_expiration(Timeout) ->
    {os:timestamp(), Timeout}.

assert_expiration({StartTime, Timeout}) ->
    Now = os:timestamp(),
    Delta = timer:now_diff(Now, StartTime),
    case Delta > (Timeout * 1000) of
        true -> error(timeout);
        false -> ok
    end.

wait_for_value(_CheckF, [], [], _Delay, _Expiration) -> ok;
wait_for_value(CheckF, [], Rem, Delay, Expiration) ->
    assert_expiration(Expiration),
    timer:sleep(Delay),
    wait_for_value(CheckF, lists:reverse(Rem), [], Delay, Expiration);
wait_for_value(CheckF, [Addr | Addrs], Rem, Delay, Expiration) ->
    case CheckF(Addr) of
        done -> wait_for_value(CheckF, Addrs, Rem, Delay, Expiration);
        wait -> wait_for_value(CheckF, Addrs, [Addr | Rem], Delay, Expiration)
    end.

http_addr_get(Addr, Path, Query) ->
    http_send(get, Addr, Path, Query, [], <<>>, #{}).

http_addr_post(Addr, Path, Query, Headers, Body) ->
    http_send(post, Addr, Path, Query, Headers, Body, #{}).

http_send(Method, Addr, Path, Query, Headers, Body, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_HTTP_TIMEOUT),
    HttpOpts = [{recv_timeout, Timeout}],
    case hackney:request(Method, url(Addr, Path, Query), Headers, Body, HttpOpts) of
        {error, _Reason} = Error -> Error;
        {ok, Status, _RespHeaders, ClientRef} ->
            case hackney_json_body(ClientRef) of
                {error, _Reason} = Error -> Error;
                {ok, Response} -> {ok, Status, Response}
            end
    end.

url(Base, Path, QS) when is_list(Path) ->
    hackney_url:make_url(Base, [to_binary(P) || P <- Path], maps:to_list(QS));
url(Base, Item, QS) ->
    url(Base, [Item], QS).

to_binary(Term) when is_atom(Term) -> atom_to_binary(Term, utf8);
to_binary(Term) when is_integer(Term) -> integer_to_binary(Term);
to_binary(Term)                    -> Term.

hackney_json_body(ClientRef) ->
    case hackney:body(ClientRef) of
        {error, _Reason} = Error -> Error;
        {ok, BodyJson} -> decode(BodyJson)
    end.

decode(<<>>) -> {ok, undefined};
decode(Data) -> decode_json(Data).

decode_json(Data) ->
    try jsx:decode(Data, [{labels, attempt_atom}, return_maps]) of
        JsonObj -> {ok, JsonObj}
    catch
        error:badarg -> {error, {bad_json, Data}}
    end.

