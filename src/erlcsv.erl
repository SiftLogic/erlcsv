%%% https://github.com/SiftLogic/erlcsv
%%%
%%% This code as been 'forked' from the website
%%% http://ppolv.wordpress.com/2008/02/25/parsing-csv-in-erlang/
%%%
%%% Original code by: pplov
%%% Additional code by Gerald Gutierrez and Luke Krasnoff
%%% 2011      - Gordon Guthrie
%%% 2011      - Ali Yakout, SiftLogic LLC
%%% 2011-2012 - Daniel Luna, SiftLogic LLC

%%% This code is 'public domain' (see original website)

%% -
%% Parse csv formated data (RFC-4180) in Erlang
%% -

%% Sez me by e-mail
%% ----------------

%% Gordon Guthrie to luke.krasnoff
%% 8 Mar
%% Hey Luke

%% I wonder if you could e-mail me a copy of your CVS parsing code:
%% http://ppolv.wordpress.com/2008/02/25/parsing-csv-in-erlang/

%% It is a useful bit of code. Have you thought of throwing up on
%% github/would you mind if we did?

%% Cheers

%% Gordon

%% Sez Luke back
%% -------------

%% Hi Gordon,

%% By all means put it on github.

%% Cheers,
%% Luke

-module(erlcsv).

%% API
-export([format_row/1]).
-export([new/1, new/2, next/1]).
-export([get_continuation_state/1]).

-record(line, {state = field_start, % field_start|normal|quoted|post_quoted
               current_field  = <<>>,
               current_record = [],
               bytes = 0,
               k_fun_used = false}).

-record(cont, {data,
               k_fun,
               k_state,
               separator,
               strict_quoting}).

-define(MAX_FIELD_SIZE, 5000).

new(Bin) ->
    new(Bin, []).

new(Bin, Opts) when is_binary(Bin) ->
    AcceptedSeparators = [$,, $;, $|, $\t],
    Separator =
        case lists:keyfind(separator, 1, Opts) of
            false -> $,;
            {separator, Sep} when is_integer(Sep) ->
                Sep;
            {separator, Sep} ->
                case lists:member(Sep, AcceptedSeparators) of
                    true -> Sep;
                    false -> $,
                end
        end,
    {KFun, KState} =
        case lists:keyfind(continuation_function, 1, Opts) of
            false ->
                {fun(_) -> {<<>>, dummy} end, dummy};
            {continuation_function, KFun0, KState0} ->
                {KFun0, KState0}
        end,
    #cont{data = Bin,
          k_fun = KFun,
          k_state = KState,
          separator = Separator,
          strict_quoting = proplists:get_value(strict_quoting, Opts, true)}.

%% @doc Parses the first CSV record in a file into a list of fields.
%% Returns the parsed record with the number of processed Bytes and a
%% continuation for getting the next record
-spec next(#cont{})  -> {ok, [binary()], non_neg_integer(), #cont{}}
                            | eof
                            | {error, atom(), non_neg_integer()}.
next(#cont{data = eof}) ->
    eof;
next(Cont = #cont{data = Data}) ->
    do_parse(Data,  #line{}, Cont).

get_continuation_state(#cont{k_state = KState}) ->
    KState.

%% Field too big
do_parse(_, #line{bytes = Bytes}, _Cont) when Bytes > ?MAX_FIELD_SIZE ->
    {error, field_too_long, Bytes};
%% No data; get more from file
do_parse(<<>> = Data, Line, Cont) ->
    {NewData, NewCont} = run_continuation(Data, Cont),
    do_parse(NewData, Line, NewCont);
%% BEGIN field_start STATE
%% whitespace, loop in field_start state
do_parse(<<$\s, Rest/binary>>,
         L = #line{state = field_start, current_field = Field},
         Cont)->
    do_parse(Rest,
             inc(L#line{current_field = <<Field/binary, $ >>}, 1),
             Cont);
%% It's a quoted field, discard previous whitespaces
do_parse(<<$", Rest/binary>>,
         L = #line{state = field_start},
         Cont = #cont{strict_quoting = true}) ->
    do_parse(Rest,
             inc(L#line{state = quoted, current_field = <<>>}, 1),
             Cont);
%% Anything else is a nonquoted field
do_parse(Bin, L = #line{state = field_start}, Cont) ->
    do_parse(Bin, L#line{state = normal}, Cont);
%% END field_start STATE
%% BEGIN quoted STATE
%% Single quote and end of data.  This could be either one of the two
%% following.  Need more data to know
do_parse(<<$">> = Data,
         L = #line{k_fun_used = false},
         Cont = #cont{strict_quoting = true}) ->
    {NewData, NewCont} = run_continuation(Data, Cont),
    do_parse(NewData, L#line{k_fun_used = true}, NewCont);
%% Escaped quote inside a quoted field
do_parse(<<$", $", Rest/binary>>,
         L = #line{state = quoted,
                   current_field = Field},
         Cont = #cont{strict_quoting = true}) ->
    do_parse(
      Rest,
      inc(L#line{current_field = <<Field/binary, $">>, k_fun_used = false}, 2),
      Cont);
%% End of quoted field
do_parse(<<$", Rest/binary>>,
         L = #line{state = quoted},
         Cont = #cont{strict_quoting = true}) ->
    do_parse(Rest,
             inc(L#line{state = post_quoted, k_fun_used = false}, 1),
             Cont);
%% Data inside a quoted field
do_parse(<<X, Rest/binary>>,
         L = #line{state = quoted, current_field = Field},
         Cont) ->
    do_parse(Rest,
             inc(L#line{current_field = <<Field/binary, X>>}, 1),
             Cont);
do_parse(eof, #line{state = quoted, bytes = Bytes}, _Cont)->
    {error, unmatched_quote, Bytes + 1};
%% END quoted STATE
%% BEGIN post_quoted STATE
%% consume whitespaces after a quoted field
do_parse(<<$ , Rest/binary>>,
         L = #line{state = post_quoted},
         Cont)->
    do_parse(Rest, inc(L#line{}, 1), Cont);
%% Comma and New line handling
%% BEGIN Common code for post_quoted and normal STATE
%% EOF in a new line, return the records
do_parse(eof, L, Cont)->
    return(eof, L, Cont);
%% EOL =:= new record
do_parse(<<$\r>> = Data, L = #line{k_fun_used = false}, Cont)->
    %% This could be the multibyte version below or the single.  Get
    %% more data to know.
    {NewData, NewCont} = run_continuation(Data, Cont),
    do_parse(NewData, L#line{k_fun_used = true}, NewCont);
do_parse(<<$\r, $\n, Rest/binary>>, L, Cont)->
    return(Rest, inc(L, 2), Cont);
do_parse(<<$\r, Rest/binary>>, L, Cont) ->
    return(Rest, inc(L, 1), Cont);
do_parse(<<$\n, Rest/binary>>, L, Cont) ->
    return(Rest, inc(L, 1), Cont);
%% Separator =:= new field
do_parse(<<Separator, Rest/binary>>,
         L = #line{current_field = Field, current_record = Record},
         Cont = #cont{separator = Separator})->
    do_parse(Rest,
             inc(L#line{state = field_start,
                        current_field = <<>>,
                        current_record = [Field | Record]}, 1),
             Cont);
%% A double quote in any other place than the already managed is an error
do_parse(<<$", _Rest/binary>>,
         #line{bytes = Bytes},
         _Cont = #cont{strict_quoting = true}) ->
    {error, bad_record, Bytes + 1};
%% Anything other than whitespace or line ends in post_quoted state is an error
do_parse(<<_, _Rest/binary>>,
         #line{state = post_quoted, bytes = Bytes},
         _Cont = #cont{strict_quoting = true}) ->
    {error, bad_record, Bytes + 1};
%% Accumulate Field value
do_parse(<<X, Rest/binary>>,
         L = #line{state = normal, current_field = Field},
         Cont)->
    do_parse(Rest, inc(L#line{current_field = <<Field/binary, X>>}, 1), Cont).

return(Rest,
       #line{current_field = Field, current_record = Record, bytes = Bytes},
       Cont) ->
    Return = lists:reverse([Field | Record]),
    case Rest =:= eof of
        true ->
            case Bytes =:= 0 of
                true -> eof;
                false -> {ok, Return, Bytes, Cont#cont{data = eof}}
            end;
        false -> {ok, Return, Bytes, Cont#cont{data = Rest}}
    end.

run_continuation(Data, Cont = #cont{k_fun = KFun, k_state = KState}) ->
    {NewData, NewKState} = KFun(KState),
    NewCont = Cont#cont{k_state = NewKState},
    case {Data, NewData} of
        {<<>>, <<>>} -> {eof, NewCont};
        {<<>>, eof} -> {eof, NewCont};
        {_, eof} -> {Data, NewCont};
        {_, _} -> {<<Data/binary, NewData/binary>>, NewCont}
    end.

inc(L = #line{bytes = Bytes}, MoreBytes) ->
    L#line{bytes = Bytes + MoreBytes}.

format_row(Row) when is_tuple(Row) ->
    format_row(tuple_to_list(Row));
format_row(Row) ->
    [string:join([case Field of
                      null -> "";
                      true -> "1";
                      false -> "0";
                      {A,B,C,D} = IpAddress
                        when is_integer(A),
                             is_integer(B),
                             is_integer(C),
                             is_integer(D) ->
                          inet_parse:ntoa(IpAddress);
                      {A,B,C,D,E,F,G,H} = IpAddress
                        when is_integer(A), is_integer(B),
                             is_integer(C), is_integer(D),
                             is_integer(E), is_integer(F),
                             is_integer(G), is_integer(H) ->
                          inet_parse:ntoa(IpAddress);
                      {{_,_,_},{_,_,_}} = DateTime ->
                          format_datetime(DateTime);
                      {Long, Lat} when is_number(Long), is_number(Lat) ->
                          "(" ++ to_list(Long) ++ ":" ++ to_list(Lat) ++ ")";
                      {_, _, _} = Date ->
                          format_date(Date);
                      _ when is_number(Field);
                             is_list(Field);
                             is_atom(Field);
                             is_binary(Field) ->
                          SField = to_list(Field),
                          StrField = string:strip(SField),
                          case lists:any(fun($,) -> true;
                                            ($\n) -> true;
                                            ($\r) -> true;
                                            ($") -> true;
                                            (_) -> false
                                         end, StrField) of
                              true ->
                                  [$", csv_escape_field(StrField), $"];
                              false ->
                                  StrField
                          end;
                      _Other ->
                          io:format("unhandled Field value discarded: ~p~n", [Field]),
                          ""
                  end || Field <- Row], ","), $\n].

csv_escape_field(Field) ->
    [case Ch of
         $" -> [$", $"];
         $\n -> $ ;
         _ -> Ch
     end || Ch <- Field].

format_datetime(Time) when is_binary(Time) ->
    Time;
format_datetime(Time) ->
    {{YYYY, MM, DD}, {H, M, S}} =
        case Time of
            {_,_,_} -> calendar:now_to_universal_time(Time);
            {{_,_,_},{_,_,_}} -> Time
        end,
    io_lib:format("~4..0b-~2..0b-~2..0b ~2..0b:~2..0b:~2..0b",
                  [YYYY, MM, DD, H, M, round(S)]).

format_date({Y, M, D}) ->
    io_lib:format("~4..0b-~2..0b-~2..0b", [Y, M, D]);
format_date({{Y, M, D}, {_, _, _}}) ->
    io_lib:format("~4..0b-~2..0b-~2..0b", [Y, M, D]).

to_list(V) ->
    case V of
        V when is_list(V) ->
            V;
        V when is_float(V) ->
            float_to_list(V);
        V when is_integer(V) ->
            integer_to_list(V);
        V when is_atom(V) ->
            atom_to_list(V);
        V when is_binary(V) ->
            binary_to_list(V);
        V when is_tuple(V) ->
            tuple_to_list(V);
        V when is_map(V) ->
            maps:to_list(V)
    end.
