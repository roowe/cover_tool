-module(mod_cover).
-behaviour(gen_server).

%% API
-export([start_link/0,
         analyze/1, analyze/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).
-define(SERVER, ?MODULE).
-define(DEFAULT_ANALYZE_INTERVAL, 1200). %% 20min进行一次analyze
-define(DEFAULT_ANALYZE_APP, server). %% 要进行cover分析的默认app
-define(DEFAULT_GENERATE_DIR, "/tmp/cover_generate_dir").

-define(WARNING, error_logger:warning_msg).
-define(INFO, error_logger:info_msg).

-record(state, {
          coverage_info = [],
          analyze_app,
          analyze_interval,
          analyze_mods,
          generate_dir
         }).

%%%===================================================================
%%% API
%%%===================================================================
analyze() ->
    case application:get_env(cover_misc, app) of
        undefined ->
            analyze([]);
        {ok, App} ->
            {ok, Modules} = application:get_key(App, modules),
            gen_server:cast(?SERVER, {analyze, Modules})
    end.

analyze(Module) when is_atom(Module) ->
    analyze([Module]);
analyze(Modules) when is_list(Modules) ->
    gen_server:cast(?SERVER, {analyze, Modules}).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    AnalyzeInterval = get_app_env(analyze_interval, ?DEFAULT_ANALYZE_INTERVAL)*1000,
    App = get_app_env(analyze_app, ?DEFAULT_ANALYZE_APP),
    GenerateDir = get_app_env(generate_dir, ?DEFAULT_GENERATE_DIR),
    ensure_generate_dir(GenerateDir),
    case application:load(App) of
        ok ->
            ok;
        {error,{already_loaded,_}} ->
            ok
    end,
    Mods = get_analyze_modules(App),
    CompiledModules = do_compile(Mods),
    erlang:send_after(30000, self(), auto_run_cover),
    {ok, #state{
            analyze_app = App,
            analyze_interval = AnalyzeInterval,
            analyze_mods = CompiledModules,
            generate_dir = filename:join(GenerateDir, "current")
           }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(Request, _From, State) ->
    ?WARNING("unknown call msg ~p~n", [Request]),
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({analyze, Modules}, State) ->
    NewState = do_analyze(Modules, State),
    {noreply, NewState};
handle_cast(Msg, State) ->
    ?WARNING("unknown cast msg ~p~n", [Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(auto_run_cover, #state{
                               analyze_mods = Modules,
                               analyze_interval = AnalyzeInterval
                              } = State) ->
    %% sync run analyze
    {noreply, NewState} = handle_cast({analyze, Modules}, State#state{coverage_info=[]}), %% coverage=[]为了生成新的index
    erlang:send_after(AnalyzeInterval, self(), auto_run_cover),
    {noreply, NewState};
handle_info(_Info, State) ->
    ?WARNING("mod_cover receive ~p~n", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
do_compile(Modules) ->
    lists:foldl(fun(Module, Acc) ->
                        case cover:compile_beam(Module) of
                            {error, Reason} ->
                                ?WARNING("compile ~p error, reason ~p~n", [Module, Reason]),
                                Acc;
                            _ ->
                                [Module | Acc]
                        end
                end, [], Modules).


do_analyze(Modules, #state{
                       coverage_info = OldCoverageInfo,
                       analyze_mods = OldModules,
                       generate_dir = GenerateDir
                      } = State) ->
    {CoverageInfo, ReCompile} = 
         lists:foldl(fun(M, {AccCoverageInfo, AccReCompile}=Acc) ->
                                      case cover:analyze(M, coverage, module) of
                                          {ok, {M, {Coverage, NotCovered}}} ->
                                              {lists:keystore(M, 1, AccCoverageInfo, {M, Coverage, NotCovered}),
                                               AccReCompile};
                                          {error,{not_cover_compiled,_}} ->
                                              {AccCoverageInfo, [M|AccReCompile]};
                                          _ ->
                                              Acc
                                      end
                              end, {OldCoverageInfo, []}, Modules),

    cover_write_index(CoverageInfo, GenerateDir),
    lists:foreach(fun(Module)  ->
                          cover:analyze_to_file(Module,
                                                filename:join(GenerateDir, atom_to_list(Module) ++ ".COVER.html"),
                                                [html])
                      end, Modules),

    %%把生成文件.html 中的编码iso-8859-1换成utf-8编码 用来纠正编码
    os:cmd("find " ++ GenerateDir ++ " -iname \"*.html\" | xargs sed -i \"s/charset=iso-8859-1/charset=utf-8/g\""),
    ?INFO("analyze_to_file ok~n", []),

    %% fix not cover compile, compile again
    CompiledModules = do_compile(ReCompile),
    FailCompileModules = ReCompile -- CompiledModules,
    State#state{
      coverage_info = CoverageInfo,
      analyze_mods = OldModules -- FailCompileModules
     }.

cover_write_index(Coverage, FileDir) ->
    {ok, F} = file:open(filename:join([FileDir, "index.html"]), [write]),
    ok = file:write(F, "<html><head><title>Coverage Summary</title></head>\n"),
    cover_write_index_section(F, "Source", Coverage),
    ok = file:write(F, "</body></html>"),
    ok = file:close(F).

cover_write_index_section(_F, _SectionName, []) ->
    ok;
cover_write_index_section(F, SectionName, Coverage) ->
    %% Calculate total coverage
    {Covered, NotCovered} = lists:foldl(fun({_Mod, C, N}, {CAcc, NAcc}) ->
                                                {CAcc + C, NAcc + N}
                                        end, {0, 0}, Coverage),
    TotalCoverage = percentage(Covered, NotCovered),

    %% Write the report
    ok = file:write(F, ?FMT("<body><h1>~s Summary</h1>\n", [SectionName])),
    ok = file:write(F, ?FMT("<h3>Total: ~s</h3>\n", [TotalCoverage])),
    ok = file:write(F, "<table><tr><th>Module</th><th>Coverage %</th></tr>\n"),

    FmtLink =
        fun(Module, Cov, NotCov) ->
                ?FMT("<tr><td><a href='~s.COVER.html'>~s</a></td><td>~s</td>\n",
                     [Module, Module, percentage(Cov, NotCov)])
        end,
    lists:foreach(fun({Module, Cov, NotCov}) ->
                          ok = file:write(F, FmtLink(Module, Cov, NotCov))
                  end, Coverage),
    ok = file:write(F, "</table>\n").

percentage(0, 0) ->
    "not executed";
percentage(Cov, NotCov) ->
    integer_to_list(trunc((Cov / (Cov + NotCov)) * 100)) ++ "%".


get_app_env(Key, Default) ->
    case application:get_env(cover_tool, Key) of
        undefined ->
            Default;
        {ok, Val} ->
            Val
    end.

get_analyze_modules(App) ->
    {ok, Mods} = application:get_key(App, modules),
    Mods.

ensure_generate_dir(GenerateDir) ->
    rotate_file(GenerateDir),
    filelib:ensure_dir(filename:join([GenerateDir, "current", "file"])).
    

%% 文件夹重命名
%% N -> N+1
%% current -> 1
rotate_file(GenerateDir) ->
    case file:list_dir(GenerateDir) of
        {error, enoent} ->
            ok;
        {ok, DirList} ->
            Count = length(DirList),
            rotate_file(GenerateDir, Count)
    end.

rotate_file(_, 0) ->
    ok;
rotate_file(Dir, 1) ->
    file:rename(filename:join(Dir, "current"),
                filename:join(Dir, "1"));
rotate_file(Dir, Count) when Count > 1->
    _ = file:rename(filename:join(Dir, integer_to_list(Count - 1)), 
                    filename:join(Dir, integer_to_list(Count))),
    rotate_file(Dir, Count - 1).



