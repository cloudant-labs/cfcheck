-module(cfcheck).

-mode(compile).

-include_lib("kernel/include/file.hrl").

-export([main/1]).

-define(SIZE_BLOCK, 4096).
-define(SNAPPY_PREFIX, 1).
-define(TERM_PREFIX, 131).
-record(db_header, {
    disk_version,
    update_seq,
    unused,
    id_tree_state,
    seq_tree_state,
    local_tree_state,
    purge_seq,
    purged_docs,
    security_ptr,
    revs_limit,
    uuid,
    epochs,
    compacted_seq
}).
-record(index_header, {
    seq,
    purge_seq,
    id_btree_state,
    view_states
}).
-record(mrheader, {
    seq,
    purge_seq,
    id_btree_state,
    log_btree_state,
    view_states
}).

-record(cs, {
    queue = [],
    map = [],
    acc = [],
    ok = 0,
    fail = 0,
    pb
}).
-record(db_acc, {
    files_count = 0,
    files_size = 0,
    active_size = 0,
    external_size = 0,
    doc_count = 0,
    del_doc_count = 0,
    doc_info_count = 0,
    purged_doc_count = 0,
    conflicts = 0,
    disk_version = dict:new(),
    tree_stats = {[
        {id_tree, {[
            {depth, 0},
            {kp_nodes, {[{min, 0}, {max, 0}]}},
            {kv_nodes, {[{min, 0}, {max, 0}]}}
        ]}},
        {seq_tree, {[
            {depth, 0},
            {kp_nodes, {[{min, 0}, {max, 0}]}},
            {kv_nodes, {[{min, 0}, {max, 0}]}}
        ]}},
        {local_tree, {[
            {depth, 0},
            {kp_nodes, {[{min, 0}, {max, 0}]}},
            {kv_nodes, {[{min, 0}, {max, 0}]}}
        ]}}
    ]}
}).
-record(view_acc, {
    files_count = 0,
    files_size = 0,
    active_size = 0,
    external_size = 0,
    tree_stats = {[
        {id_tree, {[
            {depth, 0},
            {kp_nodes, {[{min, 0}, {max, 0}]}},
            {kv_nodes, {[{min, 0}, {max, 0}]}}
        ]}}
    ]}
}).
-record(err_acc, {
    files_count = 0,
    files_size = 0
}).
-record(tree_acc, {
    depth = 0,
    kp_nodes = 0,
    kp_nodes_min = nil,
    kp_nodes_max = 0,
    kv_nodes = 0,
    kv_nodes_min = nil,
    kv_nodes_max = 0
}).

-define(TIMEOUT, 30000).
-define(OPTS, [
    {path, undefined, undefined, string, "Path to CouchDB data directory"},
    {details, $d, "details", boolean, "Output the details for each file"},
    {cache, $c, "cache", {boolean, false}, "Read the results from a cache"},
    {cache_file, undefined, "cache_file", string, "Path to the cache file"},
    {regex, undefined, "regex", string,
        "Filter-in the files to parse with a given regex"},
    {conflicts, undefined, "conflicts", {boolean, false}, "Count conflicts"},
    {with_tree, undefined, "with_tree", {boolean, false}, "Analyze b-trees"},
    {with_sec_object, undefined, "with_sec_object", {boolean, false},
        "Read and report security object from each shard"},
    {quiet, $q, "quiet", {boolean, false}, "Output nothing"},
    {verbose, $v, "verbose", {boolean, false}, "Verbose output"},
    {help, $?, "help", {boolean, false}, "Print help message"}
]).
-define(r2l(Type, Rec), lists:zip(record_info(fields, Type),
    tl(tuple_to_list(Rec)))).

main([]) ->
    getopt:usage(?OPTS, "cfcheck");
main(Args) ->
    case getopt:parse(?OPTS, Args) of
        {ok, {Opts, _}} ->
            case lists:keyfind(help, 1, Opts) of
                {help, true} ->
                    main([]);
                {help, false} ->
                    opts = ets:new(opts, [set, named_table]),
                    [ets:insert(opts, V) || V <- Opts],
                    Path = proplists:get_value(path, Opts, false),
                    FromCache = proplists:get_value(cache, Opts),
                    main(Path, FromCache)
            end;
        {error, {invalid_option, O}} ->
            stderr("Error: Invalid parameter ~s", [O]),
            getopt:usage(?OPTS, "cfcheck")
    end.

main(false, _) ->
    stderr("Error: Missing required parameter 'path'"),
    getopt:usage(?OPTS, "cfcheck");
main(_, true) ->
    case read_cache() of
        {ok, Result} ->
            process_result(Result);
        {error, Error} ->
            stderr("Error: Can't read cache: ~w", [Error])
    end;
main(Path, false) ->
    {ok, Files0} = get_files(Path),
    debug("Found ~b files at ~s", [length(Files0), Path]),
    Files = case ets:lookup(opts, regex) of
        [{regex, Re}] ->
            {ok, MP} = re:compile(Re),
            [{T, F} || {T, F} <- Files0, re:run(F, MP) /= nomatch];
        [] ->
            Files0
        end,
    Self = self(),
    Len = length(Files),
    debug("Kept ~b files after regex filter", [Len]),
    process_flag(trap_exit, true),
    CollectorPid = spawn_link(fun() ->
        start_collector(Self, Files)
    end),
    receive
    {result, Result} ->
        clear_progress_bar(),
        ok = write_cache(Result),
        process_result(Result);
    {'EXIT', CollectorPid, normal} ->
        % shouldn't happen, but async world is so out of sync
        throw(runcon);
    {'EXIT', CollectorPid, Error} ->
        throw(Error)
    after Len * ?TIMEOUT ->
        case Len of
            0 ->
                stderr("Error: No db or view files found at ~s", [Path]);
            _ ->
                throw(timeout)
        end
    end.

start_collector(PPid, Files) ->
    Self = self(),
    process_flag(trap_exit, true),
    ProcMap = lists:foldl(fun(File, Acc) ->
        Pid = spawn_link(fun() -> process_file(Self, File) end),
        [{Pid, File}|Acc]
    end, [], Files),
    ProgressBar = build_progress_bar(),
    ProgressBar(0, 0, 0, length(ProcMap)),
    CollectorState = #cs{queue = ProcMap, map = ProcMap, pb = ProgressBar},
    collector(PPid, CollectorState).

collector(PPid, #cs{map = Map, acc = Acc}) when length(Acc) =:= length(Map) ->
    PPid ! {result, Acc},
    erlang:yield();
collector(PPid, #cs{queue = Q, map = Map, acc = Acc, pb = PB} = CS) ->
    TotalCount = length(Map),
    receive
        {result, Result} ->
            NewAcc = [{Result}|Acc],
            Len = length(NewAcc),
            OkCount = CS#cs.ok + 1,
            ErrCount = CS#cs.fail,
            PB(Len, OkCount, ErrCount, TotalCount),
            collector(PPid, CS#cs{acc = NewAcc, ok = OkCount});
        {'EXIT', _, normal} ->
            collector(PPid, CS);
        {'EXIT', Pid, Err} ->
            {ok, Result} = parse_error(lists:keyfind(Pid, 1, Map), Err),
            NewAcc = [{Result}|Acc],
            Len = length(NewAcc),
            OkCount = CS#cs.ok,
            ErrCount = CS#cs.fail + 1,
            PB(Len, OkCount, ErrCount, TotalCount),
            collector(PPid, CS#cs{acc = NewAcc, fail = ErrCount})
    after
        100 ->
            Throttle = erlang:round(TotalCount / 10),
            case Throttle > 0 andalso length(Q) > Throttle of
                true ->
                    {H, T} = lists:split(Throttle, Q),
                    [Pid ! proceed || {Pid,_} <- H],
                    collector(PPid, CS#cs{queue = T});
                false ->
                    [Pid ! proceed || {Pid,_} <- Q],
                    collector(PPid, CS#cs{queue = []})
            end
    end.

process_file(CollectorPid, FD) ->
    receive
        proceed ->
            {ok, Result} = case FD of
                {db, File} -> parse_db_file(File);
                {view, File} -> parse_view_file(File)
            end,
            CollectorPid ! {result, Result};
        _ ->
            process_file(CollectorPid, FD)
    after
        infinity -> ok
    end.

process_result(Result) ->
    case ets:lookup(opts, details) of
        [{details, true}] ->
            io:format("~s~n", [jiffy:encode(Result)]);
        _ ->
            {DRec, VRec, ERec} = lists:foldl(fun reduce_result/2,
                {#db_acc{}, #view_acc{}, #err_acc{}}, Result),
            debug("~b DB files; ~b view files; ~b errors",
                [DRec#db_acc.files_count,
                VRec#view_acc.files_count,
                ERec#err_acc.files_count]),
            DiskVersion = dict:fold(fun(K, V, Acc) ->
                [{[{disk_version, K}, {files_count, V}]}|Acc]
            end, [], DRec#db_acc.disk_version),
            Db = ?r2l(db_acc, DRec#db_acc{disk_version = DiskVersion}),
            Db2 = case ets:lookup(opts, conflicts) of
                [{conflicts, true}] -> Db;
                [{conflicts, false}] -> lists:keydelete(conflicts, 1, Db)
            end,
            View = ?r2l(view_acc, VRec),
            Err = ?r2l(err_acc, ERec),
            Stats = case ets:lookup(opts, with_tree) of
                [{with_tree, true}] ->
                    {[
                        {db, {Db2}},
                        {view, {View}},
                        {error, {Err}}
                    ]};
                [{with_tree, false}] ->
                    {[
                        {db, {lists:keydelete(tree_stats, 1, Db2)}},
                        {view, {lists:keydelete(tree_stats, 1, View)}},
                        {error, {Err}}
                    ]}
            end,
            io:format("~s~n", [jiffy:encode(Stats)])
    end.

reduce_result({R}, {DbAcc, ViewAcc, ErrAcc}) ->
    case lists:keyfind(file_type, 1, R) of
        {file_type, <<"db">>} ->
            {reduce_db_result(R, DbAcc), ViewAcc, ErrAcc};
        {file_type, <<"view">>} ->
            {DbAcc, reduce_view_result(R, ViewAcc), ErrAcc};
        {file_type, <<"error">>} ->
            {DbAcc, ViewAcc, reduce_error_result(R, ErrAcc)}
    end.

reduce_db_result(R, Acc) ->
    {file_size, FileSize} = lists:keyfind(file_size, 1, R),
    {active_size, ActiveSize} = lists:keyfind(active_size, 1, R),
    {external_size, ExternalSize} = lists:keyfind(external_size, 1, R),
    {doc_count, DocCount} = lists:keyfind(doc_count, 1, R),
    {del_doc_count, DelDocCount} = lists:keyfind(del_doc_count, 1, R),
    {doc_info_count, DocInfoCount} = lists:keyfind(doc_info_count, 1, R),
    {purged_doc_count, PurgeDocCount} = lists:keyfind(purged_doc_count, 1, R),
    {conflicts, Conflicts} = lists:keyfind(conflicts, 1, R),
    {disk_version, DVer} = lists:keyfind(disk_version, 1, R),
    TreeStats = case ets:lookup(opts, with_tree) of
        [{with_tree, true}] ->
            {TreeAcc} = Acc#db_acc.tree_stats,
            {[
                {id_tree, reduce_tree_result(id_tree, R, TreeAcc)},
                {seq_tree, reduce_tree_result(seq_tree, R, TreeAcc)},
                {local_tree, reduce_tree_result(local_tree, R, TreeAcc)}
            ]};
        [{with_tree, false}] ->
            DefAcc = #db_acc{},
            DefAcc#db_acc.tree_stats
    end,
    #db_acc{
        files_count = Acc#db_acc.files_count + 1,
        files_size = Acc#db_acc.files_size + FileSize,
        active_size = Acc#db_acc.active_size + ActiveSize,
        external_size = Acc#db_acc.external_size + ExternalSize,
        doc_count = Acc#db_acc.doc_count + DocCount,
        del_doc_count = Acc#db_acc.del_doc_count + DelDocCount,
        doc_info_count = Acc#db_acc.doc_info_count + DocInfoCount,
        purged_doc_count = Acc#db_acc.purged_doc_count + PurgeDocCount,
        conflicts = Acc#db_acc.conflicts + Conflicts,
        disk_version = dict:update_counter(DVer, 1, Acc#db_acc.disk_version),
        tree_stats = TreeStats
    }.

reduce_view_result(R, Acc) ->
    {file_size, FileSize} = lists:keyfind(file_size, 1, R),
    {active_size, ActiveSize} = lists:keyfind(active_size, 1, R),
    {external_size, ExternalSize} = lists:keyfind(external_size, 1, R),
    TreeStats = case ets:lookup(opts, with_tree) of
        [{with_tree, true}] ->
            {TreeAcc} = Acc#view_acc.tree_stats,
            {[{id_tree, reduce_tree_result(id_tree, R, TreeAcc)}]};
        [{with_tree, false}] ->
            DefAcc = #view_acc{},
            DefAcc#view_acc.tree_stats
    end,
    #view_acc{
        files_count = Acc#view_acc.files_count + 1,
        files_size = Acc#view_acc.files_size + FileSize,
        active_size = Acc#view_acc.active_size + ActiveSize,
        external_size = Acc#view_acc.external_size + ExternalSize,
        tree_stats = TreeStats
    }.

reduce_error_result(R, Acc) ->
    case lists:keyfind(file_size, 1, R) of
        {file_size, FileSize} ->
            #err_acc{
                files_count = Acc#err_acc.files_count + 1,
                files_size = Acc#err_acc.files_size + FileSize
            };
        false ->
            #err_acc{files_count = Acc#err_acc.files_count + 1}
    end.

reduce_tree_result(Tree, R, Acc) ->
    {Tree, {TreeInfo1}} = lists:keyfind(Tree, 1, Acc),
    {Tree, {TreeInfo2}} = lists:keyfind(Tree, 1, R),
    {depth, D1} = lists:keyfind(depth, 1, TreeInfo1),
    {kp_nodes, {KP1}} = lists:keyfind(kp_nodes, 1, TreeInfo1),
    {min, KPMin1} = lists:keyfind(min, 1, KP1),
    {max, KPMax1} = lists:keyfind(max, 1, KP1),
    {kv_nodes, {KV1}} = lists:keyfind(kv_nodes, 1, TreeInfo1),
    {min, KVMin1} = lists:keyfind(min, 1, KV1),
    {max, KVMax1} = lists:keyfind(max, 1, KV1),
    {depth, D2} = lists:keyfind(depth, 1, TreeInfo2),
    {kp_nodes, {KP2}} = lists:keyfind(kp_nodes, 1, TreeInfo2),
    {min, KPMin2} = lists:keyfind(min, 1, KP2),
    {max, KPMax2} = lists:keyfind(max, 1, KP2),
    {kv_nodes, {KV2}} = lists:keyfind(kv_nodes, 1, TreeInfo2),
    {min, KVMin2} = lists:keyfind(min, 1, KV2),
    {max, KVMax2} = lists:keyfind(max, 1, KV2),
    {[
        {depth, erlang:max(D1, D2)},
        {kp_nodes, {[
            {min, erlang:min(KPMin1, KPMin2)},
            {max, erlang:max(KPMax1, KPMax2)}
        ]}},
        {kv_nodes, {[
            {min, erlang:min(KVMin1, KVMin2)},
            {max, erlang:max(KVMax1, KVMax2)}
        ]}}
    ]}.

read_cache() ->
    {ok, File} = get_cache_file(),
    case file:read_file_info(File) of
        {ok, _} ->
            {ok, Bin} = file:read_file(File),
            Result = jiffy:decode(Bin),
            {ok, [{keys_to_atom(E)} || {E} <- Result]};
        {error, Reason} ->
            {error, Reason}
    end.

write_cache(Result) ->
    {ok, File} = get_cache_file(),
    Json = jiffy:encode(Result),
    file:write_file(File, Json).

get_cache_file() ->
    case ets:lookup(opts, cache_file) of
        [] ->
            User = os:getenv("USER"),
            {ok, "/tmp/cfcheck." ++ User ++ ".json"};
        [{cache_file, File}] ->
            {ok, File}
    end.

parse_db_file(File) ->
    FileSize = filelib:file_size(File),
    {ok, Fd} = file:open(File, [read, binary]),
    Pos = (FileSize div ?SIZE_BLOCK) * ?SIZE_BLOCK,
    {ok, Header} = read_header(Fd, Pos),
    debug_record(Header),
    {ok, SecObj} = case ets:lookup(opts, with_sec_object) of
        [{with_sec_object, true}] ->
            read_sec_object(Fd, Header#db_header.security_ptr);
        _ ->
            {ok, []}
    end,
    {ok, TreesInfo} = case ets:lookup(opts, with_tree) of
        [{with_tree, true}] ->
            analyze_trees(Fd, [
                {id_tree, Header#db_header.id_tree_state},
                {seq_tree, Header#db_header.seq_tree_state},
                {local_tree, Header#db_header.local_tree_state}
            ]);
        [{with_tree, false}] ->
            {ok, []}
    end,
    {ok, Conflicts} = case ets:lookup(opts, conflicts) of
        [{conflicts, true}] ->
            count_conflicts(Fd, Header#db_header.id_tree_state);
        [{conflicts, false}] ->
            {ok, 0}
    end,
    file:close(Fd),
    {ok, IdTree} = read_tree(Header#db_header.id_tree_state),
    {ok, SeqTree} = read_tree(Header#db_header.seq_tree_state),
    {ok, LocTree} = read_tree(Header#db_header.local_tree_state),
    ActiveSize = proplists:get_value(active_size, IdTree, 0)
        + proplists:get_value(size, IdTree) 
        + proplists:get_value(size, SeqTree) 
        + proplists:get_value(size, LocTree),
    Fragmentation = list_to_binary(io_lib:format("~.2f%",
        [(FileSize - ActiveSize) / FileSize * 100])),
    FileInfo = [
        {file_name, File},
        {file_size, FileSize},
        {file_type, <<"db">>},
        {active_size, ActiveSize},
        {external_size, proplists:get_value(external_size, IdTree, 0)},
        {fragmentation, Fragmentation},
        {disk_version, Header#db_header.disk_version},
        {update_seq, as_int(Header#db_header.update_seq)},
        {purge_seq, as_int(Header#db_header.purge_seq)},
        {compacted_seq, as_int(Header#db_header.compacted_seq)},
        {doc_count, proplists:get_value(doc_count, IdTree, 0)},
        {del_doc_count, proplists:get_value(del_doc_count, IdTree, 0)},
        {doc_info_count, proplists:get_value(doc_info_count, SeqTree, 0)},
        {purged_doc_count, as_int(Header#db_header.purged_docs)},
        {conflicts, Conflicts}
    ] ++ SecObj ++ TreesInfo,
    {ok, FileInfo}.

parse_view_file(File) ->
    FileSize = filelib:file_size(File),
    {ok, Fd} = file:open(File, [read, binary]),
    Pos = (FileSize div ?SIZE_BLOCK) * ?SIZE_BLOCK,
    {ok, {Sig, HeaderRec}} = read_header(Fd, Pos),
    debug_record(HeaderRec),
    {ok, Header} = parse_view_header(HeaderRec),
    {ok, TreesInfo} = case ets:lookup(opts, with_tree) of
        [{with_tree, true}] ->
            analyze_trees(Fd, [{id_tree, dict:fetch(id_tree, Header)}]);
        [{with_tree, false}] ->
            {ok, []}
    end,
    file:close(Fd),
    {ok, IdTree} = read_tree(dict:fetch(id_tree, Header)),
    {size, IdTreeSize} = lists:keyfind(size, 1, IdTree),
    {ASize, ExternalSize} = lists:foldl(fun
        ({nil,_,_,_,_}, {A, E}) -> {A, E};
        ({{_,_,S},_,_,_,_}, {nil, E}) -> {nil, E + S};
        ({{_,_,S},_,_,_,_}, {A, E}) -> {A + S, E + S};
        ({_,_,S}, {nil,E}) -> {nil, E + S};
        ({_,_,S}, {A, E}) -> {A + S, E + S};
        (_, {_,E}) -> {nil, E}
    end, {0, 0}, dict:fetch(views, Header)),
    ActiveSize = case ASize of
        nil -> 0;
        _ -> IdTreeSize + ASize
    end,
    Fragmentation = list_to_binary(io_lib:format("~.2f%",
        [(FileSize - ExternalSize) / FileSize * 100])),
    FileInfo = [
        {file_name, File},
        {file_size, FileSize},
        {file_type, <<"view">>},
        {view_signature, iolist_to_binary(to_hex(Sig))},
        {update_seq, as_int(dict:fetch(update_seq, Header))},
        {purge_seq, as_int(dict:fetch(purge_seq, Header))},
        {active_size, ActiveSize},
        {external_size, ExternalSize},
        {fragmentation, Fragmentation}] ++ TreesInfo,
    {ok, FileInfo}.

parse_error(false, Err) ->
    ErrInfo = [
        {file_name, <<"unknown">>},
        {file_size, 0},
        {file_type, <<"error">>},
        {error, list_to_binary(io_lib:format("~p", [Err]))}
    ],
    {ok, ErrInfo};
parse_error({_, {_, File}}, Err) ->
    case file:read_file_info(File) of
        {ok, FileInfo} ->
            ErrInfo = [
                {file_name, File},
                {file_size, FileInfo#file_info.size},
                {file_type, <<"error">>},
                {error, list_to_binary(io_lib:format("~p", [Err]))}
            ],
            {ok, ErrInfo};
        {error, Reason} ->
            parse_error(false, Reason)
    end.

parse_view_header(Head) when is_record(Head, index_header) ->
    Info = dict:from_list([
        {update_seq, Head#index_header.seq},
        {purge_seq, Head#index_header.purge_seq},
        {id_tree, Head#index_header.id_btree_state},
        {views, Head#index_header.view_states}
    ]),
    {ok, Info};
parse_view_header(Head) when is_record(Head, mrheader) ->
    Info = dict:from_list([
        {update_seq, Head#mrheader.seq},
        {purge_seq, Head#mrheader.purge_seq},
        {id_tree, Head#mrheader.id_btree_state},
        {views, Head#mrheader.view_states}
    ]),
    {ok, Info};
parse_view_header(nil) ->
    %% just compacted
    Info = dict:from_list([
        {update_seq, 0},
        {purge_seq, 0},
        {id_tree, nil},
        {views, []}
    ]),
    {ok, Info};
parse_view_header(Head) ->
    throw({unknown_header_format, Head}).

%% readers

read_header(_Fd, -1) ->
    no_valid_header;
read_header(Fd, Pos) ->
    case (catch load_header(Fd, Pos)) of
        {ok, Term} ->
            {ok, Term};
        _Error ->
            read_header(Fd, Pos - 1)
    end.

read_sec_object(_, nil) ->
    {ok, []};
read_sec_object(Fd, Pos) ->
    SecObj = read_term(Fd, Pos),
    {ok, [{security_object, {SecObj}}]}.

read_tree(nil) ->
    {ok, [{size, 0}]};
read_tree({Pos, {Count, DelCount, {size_info, AS, ES}}, Size}) ->
    read_tree({Pos, {Count, DelCount, {AS, ES}}, Size});
read_tree({_Pos, {Count, DelCount, {ActiveSize, ExternalSize}}, Size}) ->
    {ok, [
        {doc_count, Count},
        {del_doc_count, DelCount},
        {active_size, ActiveSize},
        {external_size, ExternalSize},
        {size, Size}
    ]};
read_tree({_Pos, Reductions, Size}) when is_integer(Reductions) ->
    {ok, [{size, Size}, {doc_info_count, Reductions}]};
read_tree({_Pos, [], Size}) ->
    {ok, [{size, Size}]}.

analyze_trees(Fd, Trees) ->
    Info = lists:map(fun({Key, Tree}) ->
        {ok, Info} = analyze_tree(Fd, Tree),
        {Key, {Info}}
    end, Trees),
    {ok, Info}.

analyze_tree(_,nil) ->
    {ok, convert_tree_acc(#tree_acc{})};
analyze_tree(Fd, {Pos, _, _}) ->
    Acc = analyze_tree(Fd, read_term(Fd, Pos), #tree_acc{}),
    {ok, convert_tree_acc(Acc)}.

analyze_tree(Fd, {kp_node, Nodes}, Acc) ->
    L = length(Nodes),
    Accs = lists:map(fun({_, {P,_,_}}) ->
        analyze_tree(Fd, read_term(Fd, P), Acc)
    end,
    Nodes),
    #tree_acc{
        depth = 1 + lists:max([A#tree_acc.depth || A <- Accs]),
        kp_nodes = 1 + lists:sum([A#tree_acc.kp_nodes || A <- Accs]),
        kp_nodes_min = lists:min([L|[A#tree_acc.kp_nodes_min || A <- Accs]]),
        kp_nodes_max = lists:max([L|[A#tree_acc.kp_nodes_max || A <- Accs]]),
        kv_nodes = lists:sum([A#tree_acc.kv_nodes || A <- Accs]),
        kv_nodes_min = lists:min([L|[A#tree_acc.kv_nodes_min || A <- Accs]]),
        kv_nodes_max = lists:max([L|[A#tree_acc.kv_nodes_max || A <- Accs]])
    };
analyze_tree(_, {kv_node, Nodes}, Acc) ->
    NodesLength = length(Nodes),
    #tree_acc{depth=D, kv_nodes=C, kv_nodes_min=Min, kv_nodes_max=Max} = Acc,
    Acc#tree_acc{
        depth = D + 1 ,
        kv_nodes = C + 1,
        kv_nodes_min = erlang:min(Min, NodesLength),
        kv_nodes_max = erlang:max(Max, NodesLength)
    }.

convert_tree_acc(Acc) ->
    KpMin = find_min(Acc#tree_acc.kp_nodes_min, Acc#tree_acc.kp_nodes_max),
    KvMin = find_min(Acc#tree_acc.kv_nodes_min, Acc#tree_acc.kv_nodes_max),
    [
        {depth, Acc#tree_acc.depth},
        {kp_nodes, {[
            {count, Acc#tree_acc.kp_nodes},
            {min, KpMin},
            {max, Acc#tree_acc.kp_nodes_max}
        ]}},
        {kv_nodes, {[
            {count, Acc#tree_acc.kv_nodes},
            {min, KvMin},
            {max, Acc#tree_acc.kv_nodes_max}
        ]}}
    ].

count_conflicts(_, nil) ->
    {ok, 0};
count_conflicts(Fd, {Pos, _, _}) ->
    Count = count_conflicts(Fd, read_term(Fd, Pos), 0),
    {ok, Count}.

count_conflicts(Fd, {kp_node, Nodes}, Acc) ->
    Fold = fun({_,{P,_,_}}, A) ->
        count_conflicts(Fd, read_term(Fd, P), A)
    end,
    lists:foldl(Fold, Acc, Nodes);
count_conflicts(_, {kv_node, Nodes}, Acc) ->
    Fold = fun
        ({_Key, {_, _, _, Revs}}, A) ->
            A + length(Revs) - 1;
        (_, A) ->
            A
    end,
    lists:foldl(Fold, Acc, Nodes).

%% refactor me

load_header(Fd, Pos) ->
    {ok, <<1>>} = file:pread(Fd, Pos, 1),
    {ok, <<HeaderLen:32/integer>>} = file:pread(Fd, Pos + 1, 4),
    TotalBytes = real_len(1, HeaderLen),
    {ok, <<RawBin:TotalBytes/binary>>} = file:pread(Fd, Pos + 5, TotalBytes),
    <<Md5:16/binary, HeaderBin/binary>> =
        iolist_to_binary(remove_prefixes(5, RawBin)),
    %% make it to jump header back if md5 not match
    Md5 = md5(HeaderBin),
    {ok, bin_to_term(HeaderBin)}.

read_term(Fd, Pos) ->
    case read_bin(Fd, Pos, 4) of
        {<<1:1/integer, Len:31/integer>>, Next} ->
            {<<_Md5:16/integer, Bin/binary>>, _}
                = read_bin(Fd, Next, Len + 16),
            bin_to_term(Bin);
        {<<0:1/integer, Len:31/integer>>, Next} ->
            {Bin, _} = read_bin(Fd, Next, Len),
            bin_to_term(Bin)
    end.

read_bin(Fd, Pos, Len) ->
    Offset = Pos rem ?SIZE_BLOCK,
    RealLen = real_len(Offset, Len),
    {ok, <<RawBin:RealLen/binary>>} = file:pread(Fd, Pos, RealLen),
    {iolist_to_binary(remove_prefixes(Offset, RawBin)), Pos + RealLen}.

real_len(0, FinalLen) ->
    real_len(1, FinalLen) + 1;
real_len(Offset, Len) ->
    case ?SIZE_BLOCK - Offset of
        Left when Left >= Len ->
            Len;
        Left when ((Len - Left) rem (?SIZE_BLOCK - 1)) =:= 0 ->
            Len + ((Len - Left) div (?SIZE_BLOCK - 1));
        Left ->
            Len + ((Len - Left) div (?SIZE_BLOCK - 1)) + 1
    end.

remove_prefixes(_Offset, <<>>) ->
    [];
remove_prefixes(0, <<_Prefix, Rest/binary>>) ->
    remove_prefixes(1, Rest);
remove_prefixes(Offset, Bin) ->
    BlockBytes = ?SIZE_BLOCK - Offset,
    case size(Bin) of
        Size when Size > BlockBytes ->
            <<Block:BlockBytes/binary, Rest/binary>> = Bin,
            [Block | remove_prefixes(0, Rest)];
        _Size ->
            [Bin]
    end.

%% utils

bin_to_term(<<?SNAPPY_PREFIX, Rest/binary>>) ->
    {ok, TermBin} = snappy:decompress(Rest),
    binary_to_term(TermBin);
bin_to_term(<<?TERM_PREFIX, _/binary>> = Bin) ->
    binary_to_term(Bin).

as_int(nil) -> 0;
as_int(Count) when is_integer(Count) -> Count;
as_int(Count) -> term_to_binary(Count).

find_min(nil, Max) -> Max;
find_min(Min, _) -> Min.

to_hex([]) ->
    [];
to_hex(Bin) when is_binary(Bin) ->
    to_hex(binary_to_list(Bin));
to_hex([H|T]) ->
    [to_digit(H div 16), to_digit(H rem 16) | to_hex(T)].

to_digit(N) when N < 10 -> $0 + N;
to_digit(N) -> $a + N-10.

keys_to_atom(List) ->
    keys_to_atom(List, []).

md5(Data) ->
    case erlang:function_exported(crypto, hash, 2) of
        true -> crypto:hash(md5, Data);
        false -> crypto:md5(Data)
    end.

%% I know it's a bad thing to do in general,
%% but shouldn't be deadly sin in a script. I hope.
keys_to_atom([], Acc) ->
    Acc;
keys_to_atom([{K, {V}}|Rest], Acc) ->
    E = {binary_to_atom(K, latin1), {keys_to_atom(V)}},
    keys_to_atom(Rest, [E|Acc]);
keys_to_atom([{K, V}|Rest], Acc) ->
    E = {binary_to_atom(K, latin1), V},
    keys_to_atom(Rest, [E|Acc]).

get_files(Path) ->
    case filelib:is_file(Path) of
        true ->
            get_files([Path], []);
        false ->
            {error, enoent}
    end.

get_files([], Acc) ->
    {ok, Acc};
get_files([Path|Rest], Acc) ->
    case filelib:is_dir(Path) of
        true ->
            {ok, List} = file:list_dir(Path),
            Ins = [filename:join(Path, F) || F <- List],
            get_files(lists:append(Rest, Ins), Acc);
        false ->
            case lists:reverse(string:tokens(Path, ".")) of
            ["couch", "deleted"|_] ->
                get_files(Rest, Acc);
            ["couch"|_] ->
                get_files(Rest, [{db, list_to_binary(Path)}|Acc]);
            ["view"|_] ->
                get_files(Rest, [{view, list_to_binary(Path)}|Acc]);
            _ ->
                get_files(Rest, Acc)
            end
    end.

stderr(Msg) ->
    stderr(Msg, []).

stderr(Fmt, Args) ->
    io:format(standard_error, Fmt ++ "~n", Args).

debug(Fmt, Args) ->
    case ets:info(opts, size) /= undefined andalso ets:lookup(opts, verbose) of
        [{verbose, true}] -> stderr(" * " ++ Fmt, Args);
        _ -> ok
    end.

debug_record(Rec) ->
    RecType = element(1, Rec),
    FieldsFun = fun
        (db_header) -> record_info(fields, db_header);
        (index_header) -> record_info(fields, index_header);
        (mrheader) -> record_info(fields, mrheader)
    end,
    Fields = FieldsFun(RecType),
    Elements = lists:zipwith(fun(Key, Value) ->
        io_lib:format("     ~s = ~w~n", [Key, Value])
    end, Fields, tl(tuple_to_list(Rec))),
    debug("#~s {~n~s   }", [RecType, Elements]).

build_progress_bar() ->
    case ets:lookup(opts, quiet) of
        [{quiet, true}] ->
            fun(_,_,_,_) -> ok end;
        [{quiet, false}] ->
            fun(Current, OkCount, ErrCount, TotalCount) ->
                io:format(standard_error,
                    "  ~.2f% [ok: ~b; error: ~b; total: ~b]\r",
                    [100 * Current / TotalCount,
                    OkCount, ErrCount, TotalCount])
            end
    end.

clear_progress_bar() ->
    case ets:lookup(opts, quiet) of
        [{quiet, true}] -> ok;
        [{quiet, false}] -> io:format(standard_error, "~80s\r", [" "])
    end.
