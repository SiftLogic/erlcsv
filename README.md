erlcsv
======

`erlcsv` is a csv parser in Erlang.  Its main advantage is that it
allows for working on a stream and as such doesn't need to keep the
whole file in memory.

Each row will be returned as a list of binaries, together with
continuation data needed to get the next row.

Supports UTF-8 as well as all Latin-X character sets.


A simple usage of erlcsv that accumulates the whole file in memory
while reading chunks from an input file.  If you do chunkwise reading
you probably want to write the data as it comes in instead of
accumulating it.  This is left as an exercise to the reader.

```erlang
to_csv(Filename) ->
    {ok, Fd} = file:open(Filename, [read]),
    State = erlcsv:new(
              <<>>,
              [{continuation_function,
                fun(_) ->
                        {case file:read(Fd, 64*1024) of
                             eof -> eof;
                             {ok, Data} -> Data
                         end, dummy}
                end, dummy}]),
    loop(State, []).

loop(State, Acc) ->
    case erlcsv:next(State) of
        {ok, Row, NumberOfBytes, NewState} ->
            %% Add your chunkwise handling here and don't
            %% accumulate the data if you want to keep
            %% the memory footprint low.
            loop(NewState, [Row | Acc]);
        eof ->
            {ok, lists:reverse(Acc)};
        {error, Error, ByteOffset} ->
            {error, {Error, ByteOffset}}
    end.
```

Since the continuation function is optional, a simpler version of
`to_csv/1` would be

```erlang
to_csv(Filename) ->
    {ok, Bin} = file:read_file(Filename),
    loop(erlcsv:new(Bin), []).
```

This version would obviously keep the whole file in memory.

## Functions

`new(Bin) -> state()`

> Same as `new(Bin, [])`

`new(Bin, Options) -> state()`

> Creates an erlcsv State containing enough information to loop over
> the remainder of the file or stream specified.

>Types:
>
>>     Bin = binary()
>>     Options = [option()]
>>     option() = {separator, char()}
>>              | {continuation_function, function(), function_state()}
>>              | strict_quoting
>>     function() = fun(function_state()) -> {eof | binary(), function_state()}
>>     function_state() = any()
>>     state() = opaque()

`next(State) -> eof | {ok, [binary()], non_neg_integer(), state()} | {error, atom(), non_neg_integer()}`

> Get the next row.  The integer returned is the number of bytes in
> the line (inluding line feed characters), or byte at which parsing
> failed respectively.

>Types:
>
>>     State = state()
>>     state() = opaque()

`get_continuation_state(State) -> function_state()`

> This function returns the last continuation state.  For example,
> when the continuation state is a
> [cowboy](https://github.com/extend/cowboy) Req, the latest version
> of the Req is needed for sending a response back to the requestor.

>Types:
>
>>     State = state()
>>     state() = opaque()
>>     function_state() = any()
