%%% Module imported from
%%% https://github.com/ferd/simhash
-module(lager_simhash).
-export([hash/1, hash/3, closest/2, distance/2]).

-ifdef(TEST).
-export([test/0, testlog/0, teststruct/0]).
-endif.

%% The shingle size determines how large the sliding
%% window goes over binary data. A size of two is slower
%% but is likely the most accurate we can have.
-define(SHINGLE_SIZE, 2).
%% Each time the same shingle is met more than once in
%% a given bit of text, its weight is increased in the final
%% simhash.
-define(DUP_WEIGHT_ADD,1).

%% Default random hash used by simhash is MD5
-ifndef(PHASH). -ifndef(MD5). -ifndef(SHA).
-define(MD5, true).
-endif. -endif. -endif.

%% erlang:phash2 is the fastest, but sadly
%% only uses 32 bits, which is not very accurate on
%% larger binary sizes ot hash.
-ifdef(PHASH).
-define(SIZE, 32). % bits
-define(HASH(X), <<(erlang:phash2(X,4294967296)):32>>).
-endif.
%% MD5 is faster and less precise than SHA in tests ran
%% by the author, but it's slower and more precise than
%% PHASH.
-ifdef(MD5).
-define(SIZE, 128). % bits
-define(HASH(X), erlang:md5(X)).
-endif.
%% SHA-160 seemed to give the best result in terms of
%% accuracy. In a few contrived tests, it was
%% the slowest mode.
-ifdef(SHA).
-define(SIZE, 160).
-define(HASH(X), crypto:sha(X)).
-endif.

%%%%%%%%%%%%%%
%%% PUBLIC %%%
%%%%%%%%%%%%%%
-type simhash()  :: binary().
-type feature()  :: {Weight::pos_integer(), binary()}.
-type features() :: [feature()].
-type hashfun()  :: fun((binary()) -> binary()).
-type hashsize() :: pos_integer().
-export_type([simhash/0, feature/0, features/0,
              hashfun/0, hashsize/0]).

%% Takes any binary and returns a simhash for that data.
-spec hash(binary()) -> simhash()
      ;   (features()) -> simhash().
hash(Bin = <<_/binary>>) ->
    hashed_shingles(Bin, ?SHINGLE_SIZE);
hash(Features = [_|_]) ->
    simhash_features(Features).

%% Takes any binary and returns a simhash for that data, based
%% on whatever hash and size is given by the user.
-spec hash(binary(), hashfun(), hashsize()) -> simhash()
      ;   (features(), hashfun(), hashsize()) -> simhash().
hash(Bin = <<_/binary>>, HashFun, Size) ->
    hashed_shingles(Bin, ?SHINGLE_SIZE, HashFun, Size);
hash(Features = [_|_], HashFun, Size) ->
    simhash_features(Features, HashFun, Size).

%% Takes a given simhash and returns the closest simhash
%% in a second list, based on their Hamming distance.
-spec closest(simhash(), [simhash(),...]) -> {non_neg_integer(), simhash()}.
closest(Hash, [H|T]) ->
    closest(Hash, hamming(Hash,H), H, T).

%% Takes two simhashes and returns their distance.
-spec distance(simhash(), simhash()) -> non_neg_integer().
distance(X,Y) -> hamming(X,Y).

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

%% Takes a given set of features and hashes them according
%% to the algorithm used when compiling the module.
simhash_features(Features) ->
    Hashes = [{W, ?HASH(Feature)} || {W,Feature} <- Features],
    to_sim(reduce(Hashes, ?SIZE-1)).

simhash_features(Features, Hash, Size) ->
    Hashes = [{W, Hash(Feature)} || {W,Feature} <- Features],
    to_sim(reduce(Hashes, Size-1)).

%% Returns a set of shingles, hashed according to the algorithm
%% used when compiling the module.
hashed_shingles(Bin, Size) ->
    simhash_features(shingles(Bin, Size)).

hashed_shingles(Bin, Size, HashFun, HashSize) ->
    simhash_features(shingles(Bin, Size), HashFun, HashSize).

%% The vector returned from reduce/2 is taken and flattened
%% by its content -- values greater or equal to 0 end up being 1,
%% and those smaller than 0 end up being 0.
to_sim(HashL) ->
    << <<(case Val >= 0 of
              true -> 1;
              false -> 0
          end):1>> || Val <- HashL >>.

%% Takes individually hashed shingles and flattens them
%% as the numeric simhash.
%% Each N bit hash is treated as an N-vector, which is
%% added bit-per-bit over an empty N-vector. The resulting
%% N-vector can be used to create the sim hash.
reduce(_, -1) -> [];
reduce(L, Size) -> [add(L, Size, 0) | reduce(L, Size-1)].

%% we add it left-to-right through shingles,
%% rather than shingle-by-shingle first.
add([], _, Acc) -> Acc;
add([{W,Bin}|T], Pos, Acc) ->
    <<_:Pos, Bit:1, _Rest/bitstring>> = Bin,
    add(T, Pos,
        case Bit of
            1 -> Acc+W;
            0 -> Acc-W
        end).

%% shingles are built using a sliding window of ?SIZE bytes,
%% moving 1 byte at a time over the data. It might be interesting
%% to move to a bit size instead.
shingles(Bin, Size) ->
    build(shingles(Bin, Size, (byte_size(Bin)-1)-Size, [])).

shingles(Bin, Size, Pos, Acc) when Pos > 0 ->
    <<_:Pos/binary, X:Size/binary, _/binary>> = Bin,
    shingles(Bin, Size, Pos-1, [X|Acc]);
shingles(_, _, _, Acc) -> Acc.

build(Pieces) ->
    build(lists:sort(Pieces), []).

build([], Acc) -> Acc;
build([H|T], [{N,H}|Acc]) -> build(T, [{N+?DUP_WEIGHT_ADD,H}|Acc]);
build([H|T], Acc) -> build(T,[{1,H}|Acc]).

%% Runs over the list of simhashes and returns the best
%% match available.
closest(_, D, Match, []) ->
    {D, Match};
closest(Hash, D, Old, [H|T]) ->
    case hamming(Hash, H) of
        Dist when Dist > D -> closest(Hash, D, Old, T);
        Dist -> closest(Hash, Dist, H, T)
    end.

%% Finds the hamming distance between two different
%% binaries.
hamming(X,Y) ->
    true = bit_size(X) == bit_size(Y),
    hamming(X,Y,bit_size(X)-1,0).

%% Hammign distance between two strings can be calculated
%% by checking each of the characters and incrementing the
%% counter by 1 each time the two values are different.
%% In this case, we do it over individual bits of a binary.
hamming(_,_,-1,Sum) -> Sum;
hamming(X,Y,Pos,Sum) ->
    case {X,Y} of
        {<<_:Pos, Bit:1, _/bitstring>>,
         <<_:Pos, Bit:1, _/bitstring>>} ->
            hamming(X,Y,Pos-1,Sum);
        {_,_} ->
            hamming(X,Y,Pos-1,Sum+1)
    end.

-ifdef(TEST).
%%% ad-hoc demos/benches, useful when fiddling with new features
%%% that can require manual validation, without actually impacting
%%% tests in test/simhash_SUITE.erl.

test() ->
    L = [<<"the cat sat on the mat">>,<<"the cat sat on a mat">>,
          <<"my car is grey">>,<<"we all scream for ice cream">>,
          <<"my heart will go on">>,
          <<"bless this mess with all the might you have">>,
          <<"the fat cat is a rat">>,
          <<"a scream for the supreme cream">>,<<"my car is great">>],
    DB = [{simhash:hash(Str), Str} || Str <- L],
    F = fun(Str) -> {Dist, Hash} = simhash:closest(simhash:hash(Str), [Hash || {Hash, _} <- DB]),
            {Dist, Str, proplists:get_value(Hash, DB)}
    end,
    [F(<<"my fat hat is a rat">>),
      F(<<"unrelated text, entirely!!!">>),
      F(<<"my cart will go long">>),
      F(<<"the crop and top of the cream">>),
      F(<<"I dream of ice cream">>)].

testlog() ->
    L = [[{0,<<"2012-09-11 14:56:15.959">>},{5,<<"[info]">>}, {0,<<"<0.7.0>">>}, {1,<<"Application">>}, {10,<<"eredis">>}, {1,<<"started on node">>}, {1, <<"'gateway@host.com'">>}],
         [{0,<<"2012-09-11 14:56:15.972">>},{5,<<"[info]">>}, {0,<<"<0.7.0>">>}, {1,<<"Application">>}, {10,<<"omething">>}, {1,<<"started on node">>}, {1, <<"'gateway@host.com'">>}],
         [{0,<<"2012-09-11 14:56:16.054">>},{5,<<"[info]">>}, {0,<<"<0.7.0>">>}, {1,<<"Application">>}, {10,<<"gateway">>},{1,<<"started on node">>}, {1, <<"'gateway@host.com'">>}],
         [{0,<<"2012-09-11 15:15:49.374">>},{5,<<"[warning]">>},{0,<<"<0.15224.441>">>}, {5,<<"@gateway:valid_timestamp:167">>},{1,<<"Replay">>}, {1,<<"detected">>}, {1,<<"(G_TS):">>}, {1,<<"<<\"T428\">>">>}, {1, <<"41">>}, {1, <<"<<\"market\">>">>}],
         [{0,<<"2012-09-11 15:16:10.074">>},{5,<<"[warning]">>},{0,<<"<0.4186.452>">>}, {5,<<"@gateway:valid_timestamp:167">>},{1,<<"Replay">>}, {1,<<"detected">>}, {1,<<"(G_TS):">>}, {1,<<"<<\"T43l\">>">>}, {1, <<"21">>}, {1, <<"<<\"market\">>">>}],
         [{0,<<"2012-09-11 15:16:10.091">>},{5,<<"[warning]">>},{0,<<"<0.4455.452>">>}, {5,<<"@gateway:valid_timestamp:167">>},{1,<<"Replay">>}, {1,<<"detected">>}, {1,<<"(G_TS):">>}, {1,<<"<<\"T43U\">>">>}, {1, <<"38">>}, {1, <<"<<\"market\">>">>}],
         [{0,<<"2012-09-11 15:16:11.486">>},{5,<<"[warning]">>},{0,<<"<0.6040.441>">>}, {5,<<"@gateway:valid_timestamp:167">>},{1,<<"Replay">>}, {1,<<"detected">>}, {1,<<"(G_TS):">>}, {1,<<"<<\"T43i\">>">>}, {1, <<"25">>}, {1, <<"<<\"market\">>">>}],
         [{0,<<"2012-09-11 15:18:05.026">>}, {5,<<"[error]">>}, {0,<<"<0.19153.510>">>}, {5,<<"@market:generate_response:109">>}, {3,<<"invalid_json:">>}]
          ++ [{1, X} || X <- re:split(<<"\"lexical error: invalid bytes in UTF8 string.\n\" at 1273 (...<<97,105,115,101,115,45,72,101,114,45,84,101,97,109,146,115,45,82,97,119,45,84,97,108,101,110,116,44,53,54>>...)">>, "\s|,|\\."), X =/= <<>>],
         [{0,<<"2012-09-11 15:39:45.113">>}, {5,<<"[error]">>}, {0,<<"<0.32341.1177>">>}, {5,<<"@market:generate_response:109">>}, {3,<<"invalid_json">>}]
          ++ [{1, X} || X <- re:split(<<"\"lexical error: invalid bytes in UTF8 string.\n\" at 1129 (...<<32,49,46,54,59,32,102,114,45,99,97,59,32,110,252,118,105,102,111,110,101,32,65,53,48,32,66,117,105,108>>...)">>, "\s|,|\\."), X =/= <<>>],
         [{0,<<"2012-09-11 15:39:45.113">>},{5,<<"[warning]">>},{0,<<"<0.4506.1185>">>}, {5,<<"@market:valid_timestamp:167">>},
          {1,<<"replay">>}, {1,<<"detected">>}, {1,<<"(g_ts):">>}, {1,<<"<<\"T5N1\">>">>}, {1, <<"24">>}, {1, <<"<<\"market\">>">>}],
         [{0,<<"2012-09-11 15:40:01.456">>},{5,<<"[warning]">>},{0,<<"<0.10828.1178>">>}, {5,<<"@gateway:valid_timestamp:167">>},
          {1,<<"replay">>}, {1,<<"detected">>}, {1,<<"(g_ts):">>}, {1,<<"<<\"T5N6\">>">>}, {1, <<"23">>}, {1, <<"<<\"market\">>">>}],
         [{0,<<"2012-09-11 15:40:19.782">>}, {5,<<"[error]">>}, {0,<<"<0.23906.1197>">>}, {5,<<"@market:generate_response:109">>}]
          ++ [{1, X} || X <- re:split(<<"\"lexical error: invalid bytes in UTF8 string.\n\" at 1241 (...<<46,104,116,109,197,166,202,177,45,202,178,195,180,200,195,214,208,185,250,200,203,212,218,201,238,210,185,215,248,193>>...)">>, "\s|,|\\."), X =/= <<>>],
         [{0,<<"2012-09-11 16:44:24.472">>}, {5,<<"[error]">>}, {3,<<"emulator Error in process">>}, {0,<<"<0.2754.3785>">>},{0,<<"on node 'gateway@host.com'">>}]
          ++ [{1, X} || X <- re:split(<<"with exit value: {{case_clause,{match,[[<<20 bytes>>],[<<15 bytes>>]]}},[{filters,is_blacklisted,1,[{file,\"src/filters.erl\"},{line,49}]},{other_market,generate_response,2,[{file,\"src/other_market.erl\"},{line,25}]}]}">>, "\s|,|\\."), X =/= <<>>],
         [{0,<<"2012-09-11 15:57:42.827">>}, {5,<<"[error]">>}, {3,<<"emulator Error in process">>}, {0,<<"<0.15429.1866>">>},{0,<<"on node 'gateway@host.com'">>}]
          ++ [{1, X} || X <- re:split(<<"with exit value: {{case_clause,{match,[[<<20 bytes>>],[<<5 bytes>>]]}},[{filters,is_blacklisted,1,[{file,\"src/filters.erl\"},{line,49}]},{other_market,generate_response,2,[{file,\"src/other_market.erl\"},{line,25}]}]}">>, "\s|,|\\."), X =/= <<>>]],
    DB = [{simhash:hash(Features), Features} || Features <- L],
    F = fun(Features) ->
            {Dist, Hash} = simhash:closest(simhash:hash(Features),
                                           [Hash || {Hash, _} <- DB]),
            {Dist, Features, proplists:get_value(Hash, DB)}
    end,
    [F([{0,<<"2012-09-11 16:44:28.359">>}, {5,<<"[error]">>}, {3,<<"emulator Error in process">>}, {0,<<"<0.23466.3787>">>}, {0,<<"on node 'gateway@host.com'">>}]
         ++ [{1, X} || X <- re:split(<<"{{case_clause,{match,[[<<20 bytes>>],[<<15 bytes>>]]}},[{filters,is_blacklisted,1,[{file,\"src/filters.erl\"},{line,49}]},{other_market,generate_response,2,[{file,\"src/other_market.erl\"},{line,25}]}]}">>, "\s|,|\\."), X =/= <<>>])
    ,F([{0,<<"2012-09-11 16:52:08.593">>}, {5,<<"[error]">>}, {0,<<"<0.4986.4117>">>}, {5,<<"@market:generate_response:109">>}, {3,<<"invalid_json:">>}]
        ++ [{1, X} || X <- re:split(<<"\"lexical error: invalid bytes in UTF8 string.\n\" at 1575 (...<<45,82,104,121,115,45,74,111,105,110,115,45,70,88,146,115,45,80,105,108,111,116,45,145,84,104,101,45,65,109>>...)">>, "\s|,|\\."), X =/= <<>>])
    ,F([{0,<<"2012-09-11 16:52:18.036">>},{5,<<"[warning]">>},{0,<<"<0.28015.4123>">>}, {5,<<"@gateway:valid_timestamp:167">>},{1,<<"Replay">>}, {1,<<"detected">>}, {1,<<"(G_TS):">>}, {1,<<"<<\"T6Rf\">>">>}, {1, <<"35">>}, {1, <<"<<\"market\">>">>}])
    ,F([{0,<<"2012-09-11 17:51:11.254">>}, {5,<<"[error]">>}, {3,<<"emulator Error in process">>}, {0,<<"<0.10101.6540>">>}, {0,<<"on node 'gateway@host.com'">>}]
         ++ [{1, X} || X <- re:split(<<"{{case_clause,{match,[[<<20 bytes>>],[<<13 bytes>>]]}},[{filters,is_blacklisted,1,[{file,\"src/filters.erl\"},{line,49}]},{other_market,generate_response,2,[{file,\"src/other_market.erl\"},{line,25}]}]}">>, "\s|,|\\."), X =/= <<>>])
    ,F([{0,<<"2012-09-11 19:01:35.403">>}, {5,<<"[error]">>}, {0,<<"<0.31990.1161>">>}, {2, <<"Unknown request for">>}, {1,<<"market">>},{2,<<"method: 'GET'">>}]
         ++ [{1, X} || X <- re:split(<<"path: [<<\"win\">>,<<\"file:\">>,<<>>,<<>>,<<>>,<<\"data\">>,<<\"webkitrel\">>,<<\"miscdata\">>,<<\"html\">>,<<\"file:\">>,<<>>,<<>>,<<>>,<<\"data\">>,<<\"webkitrel\">>,<<\"miscdata\">>,<<\"html\">>,<<\"error.html\">>]">>, "\s|,|\\."), X =/= <<>>])
    ].


teststruct() ->
    L = [
            [a,b,c,d,e,f]
             ,{{case_clause,{match,[[<<1:20>>],[<<0:3>>]]}},[{filters,is_blacklisted,1,[{file,"src/filters.erl"},{line,49}]},{other_market,generate_response,2,[{file,"src/other_market.erl"},{line,25}]}]}
             ,{cowboy_http_protocol,request,[{http_response,{1,1},200,<<79,75>>},{state,"<0.945.0>","#Port<0.28861495>",cowboy_tcp_transport,[{'_',[{'_',rtb_handler,{config,cassanderl_dispatch,800,ets,61473,65570}}]}],{rtb_handler,{config,cassanderl_dispatch,800,ets,61473,65570}},0,5,10000,keepalive,<<67,97,99,104,101,45,67,111,110,116,114,111,108,58,32,110,111,45,99,97,99,104,101,44,32,110,111,45,115,116,111,114,101,44,32,109,117,115,116,45,114,101,118,97,108,105,100,97,116,101,44,32,112,114,111,120,121,45,114,101,118,97,108,105,100,97,116,101,13,10,67,111,110,110,101,99,116,105,111,110,58,32,107,101,101,112,45,97,108,105,118,101,13,10,67,111,110,116,101,110,116,45,76,101,110,103,116,104,58,32,57,50,53,13,10,67,111,110,116,101,110,116,45,84,121,112,101,58,32,97,112,112,108,105,99,97,116,105,111,110,47,106,97,118,97,115,99,114,105,112,116,13,10,68,97,116,101,58,32,70,114,105,44,32,49,52,32,83,101,112,32,50,48,49,50,32,48,49,58,48,53,58,48,57,32,71,77,84,13,10,80,51,80,58,32,67,80,61,34,78,79,73,32,79,84,67,32,79,84,80,32,79,85,82,32,78,79,82,34,13,10,80,114,97,103,109,97,58,32,110,111,45,99,97,99,104,101,13,10,83,101,114,118,101,114,58,32,67,111,119,98,111,121,13,10,88,45,83,101,114,118,101,114,58,32,104,48,49,49,13,10,88,45,65,110,116,105,118,105,114,117,115,58,32,97,118,97,115,116,33,32,52,13,10,88,45,65,110,116,105,118,105,114,117,115,45,83,116,97,116,117,115,58,32,67,108,101,97,110,13,10,13,10>>,2}],[{file,[115,114,99,47,99,111,119,98,111,121,95,104,116,116,112,95,112,114,111,116,111,99,111,108,46,101,114,108]},{line,97}]}
             ,{a,
               {b,[],[]},
               {c,{d,{e,[],[]}},
                  {f,[],[]}}}
             ,<<"a b c d">>
             ,self()
        ],
    Format = fun erlang:term_to_binary/1,
    DB = [{simhash:hash(Format(Str)), Str} || Str <- L],
    F = fun(Str) ->
            {Dist, Hash} = simhash:closest(simhash:hash(Format(Str)),
                                           [Hash || {Hash, _} <- DB]),
            {Dist, Str, proplists:get_value(Hash, DB)}
    end,
    [F([e,f,g,h])
    ,F("a b c d e f")
    ,F({'EXIT',{badarith,[{erlang,'/',[1,0],[]},
                          {erl_eval,do_apply,6,[{file,"erl_eval.erl"},{line,576}]},
                          {erl_eval,expr,5,[{file,"erl_eval.erl"},{line,360}]},
                          {shell,exprs,7,[{file,"shell.erl"},{line,668}]},
                          {shell,eval_exprs,7,[{file,"shell.erl"},{line,623}]},
                          {shell,eval_loop,3,[{file,"shell.erl"},{line,608}]}]}})
    ,F({a,
        {b,[],[]},
        {c,{g,{e,[],[]}},
         {f,[],[]}}})
    ,F(spawn(fun() -> ok end))
    ].
-endif.
