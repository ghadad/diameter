%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2010-2013. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

-module(diameter_codec).

-export([encode/2,
         decode/2,
         decode/3,
         collect_avps/1,
         decode_header/1,
         sequence_numbers/1,
         hop_by_hop_id/2,
         msg_name/2,
         msg_id/1]).

%% Towards generated encoders (from diameter_gen.hrl).
-export([pack_avp/1,
         pack_avp/2]).

-include_lib("diameter/include/diameter.hrl").
-include("diameter_internal.hrl").

-define(MASK(N,I), ((I) band (1 bsl (N)))).

%%     0                   1                   2                   3
%%     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |    Version    |                 Message Length                |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    | command flags |                  Command-Code                 |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |                         Application-ID                        |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |                      Hop-by-Hop Identifier                    |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |                      End-to-End Identifier                    |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |  AVPs ...
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-

%%% ---------------------------------------------------------------------------
%%% # encode/[2-4]
%%% ---------------------------------------------------------------------------

encode(Mod, #diameter_packet{} = Pkt) ->
    try
        e(Mod, Pkt)
    catch
        error: Reason ->
            %% Be verbose since a crash report may be truncated and
            %% encode errors are self-inflicted.
            X = {?MODULE, encode, {Reason, ?STACK}},
            diameter_lib:error_report(X, {?MODULE, encode, [Mod, Pkt]}),
            exit(X)
    end;

encode(Mod, Msg) ->
    Seq = diameter_session:sequence(),
    Hdr = #diameter_header{version = ?DIAMETER_VERSION,
                           end_to_end_id = Seq,
                           hop_by_hop_id = Seq},
    encode(Mod,  #diameter_packet{header = Hdr,
                                  msg = Msg}).

e(_, #diameter_packet{msg = [#diameter_header{} = Hdr | As]} = Pkt) ->
    Avps = encode_avps(As),
    Length = size(Avps) + 20,

    #diameter_header{version = Vsn,
                     cmd_code = Code,
                     application_id = Aid,
                     hop_by_hop_id  = Hid,
                     end_to_end_id  = Eid}
        = Hdr,

    Flags = make_flags(0, Hdr),

    Pkt#diameter_packet{header = Hdr,
                        bin = <<Vsn:8, Length:24,
                                Flags:8, Code:24,
                                Aid:32,
                                Hid:32,
                                Eid:32,
                                Avps/binary>>};

e(Mod, #diameter_packet{header = Hdr, msg = Msg} = Pkt) ->
    #diameter_header{version = Vsn,
                     hop_by_hop_id = Hid,
                     end_to_end_id = Eid}
        = Hdr,

    MsgName = rec2msg(Mod, Msg),
    {Code, Flags0, Aid} = msg_header(Mod, MsgName, Hdr),
    Flags = make_flags(Flags0, Hdr),

    Avps = encode_avps(Mod, MsgName, values(Msg)),
    Length = size(Avps) + 20,

    Pkt#diameter_packet{header = Hdr#diameter_header
                                    {length = Length,
                                     cmd_code = Code,
                                     application_id = Aid,
                                     is_request       = 0 /= ?MASK(7, Flags),
                                     is_proxiable     = 0 /= ?MASK(6, Flags),
                                     is_error         = 0 /= ?MASK(5, Flags),
                                     is_retransmitted = 0 /= ?MASK(4, Flags)},
                        bin = <<Vsn:8, Length:24,
                                Flags:8, Code:24,
                                Aid:32,
                                Hid:32,
                                Eid:32,
                                Avps/binary>>}.

%% make_flags/2

make_flags(Flags0, #diameter_header{is_request       = R,
                                    is_proxiable     = P,
                                    is_error         = E,
                                    is_retransmitted = T}) ->
    {Flags, 3} = lists:foldl(fun(B,{F,N}) -> {mf(B,F,N), N-1} end,
                             {Flags0, 7},
                             [R,P,E,T]),
    Flags.

mf(undefined, F, _) ->
    F;
mf(B, F, N) ->  %% reset the affected bit
    (F bxor (F band (1 bsl N))) bor bit(B, N).

bit(true, N)  -> 1 bsl N;
bit(false, _) -> 0.

%% values/1

values([H|T])
  when is_atom(H) ->
    T;
values(Avps) ->
    Avps.

%% encode_avps/3

%% Specifying values as a #diameter_avp list bypasses arity and other
%% checks: the values are expected to be already encoded and the AVP's
%% presented are simply sent. This is needed for relay agents, since
%% these have to be able to resend whatever comes.

%% Message as a list of #diameter_avp{} ...
encode_avps(_, _, [#diameter_avp{} | _] = Avps) ->
    encode_avps(reorder(Avps, [], Avps));

%% ... or as a tuple list or record.
encode_avps(Mod, MsgName, Values) ->
    Mod:encode_avps(MsgName, Values).

%% reorder/1

reorder([#diameter_avp{index = 0} | _] = Avps, Acc, _) ->
    Avps ++ Acc;

reorder([#diameter_avp{index = N} = A | Avps], Acc, _)
  when is_integer(N) ->
    lists:reverse(Avps, [A | Acc]);

reorder([H | T], Acc, Avps) ->
    reorder(T, [H | Acc], Avps);

reorder([], Acc, _) ->
    Acc.

%% encode_avps/1

encode_avps(Avps) ->
    list_to_binary(lists:map(fun pack_avp/1, Avps)).

%% msg_header/3

msg_header(Mod, 'answer-message' = MsgName, Header) ->
    0 = Mod:id(),  %% assert
    #diameter_header{application_id = Aid,
                     cmd_code = Code}
        = Header,
    {-1, Flags, ?DIAMETER_APP_ID_COMMON} = Mod:msg_header(MsgName),
    {Code, Flags, Aid};

msg_header(Mod, MsgName, _) ->
    Mod:msg_header(MsgName).

%% rec2msg/2

rec2msg(_, [Name|_])
  when is_atom(Name) ->
    Name;

rec2msg(Mod, Rec) ->
    Mod:rec2msg(element(1, Rec)).

%%% ---------------------------------------------------------------------------
%%% # decode/2
%%% ---------------------------------------------------------------------------

%% Unsuccessfully decoded AVPs will be placed in #diameter_packet.errors.

decode(Mod, Pkt) ->
    decode(Mod:id(), Mod, Pkt).

%% If we're a relay application then just extract the avp's without
%% any decoding of their data since we don't know the application in
%% question.
decode(?APP_ID_RELAY, _, #diameter_packet{} = Pkt) ->
    case collect_avps(Pkt) of
        {Bs, As} ->
            Pkt#diameter_packet{avps = As,
                                errors = [Bs]};
        As ->
            Pkt#diameter_packet{avps = As}
    end;

%% Otherwise decode using the dictionary.
decode(_, Mod, #diameter_packet{header = Hdr} = Pkt) ->
    #diameter_header{cmd_code = CmdCode,
                     is_request = IsRequest,
                     is_error = IsError}
        = Hdr,

    MsgName = if IsError andalso not IsRequest ->
                      'answer-message';
                 true ->
                      Mod:msg_name(CmdCode, IsRequest)
              end,

    decode_avps(MsgName, Mod, Pkt, collect_avps(Pkt));

decode(Id, Mod, Bin)
  when is_bitstring(Bin) ->
    decode(Id, Mod, #diameter_packet{header = decode_header(Bin), bin = Bin}).

decode_avps(MsgName, Mod, Pkt, {Bs, Avps}) ->  %% invalid avp bits ...
    ?LOG(invalid, Pkt#diameter_packet.bin),
    #diameter_packet{errors = Failed}
        = P
        = decode_avps(MsgName, Mod, Pkt, Avps),
    P#diameter_packet{errors = [Bs | Failed]};

decode_avps('', Mod, Pkt, Avps) ->  %% unknown message ...
    ?LOG(unknown, {Mod, Pkt#diameter_packet.header}),
    Pkt#diameter_packet{avps = lists:reverse(Avps),
                        errors = [3001]};   %% DIAMETER_COMMAND_UNSUPPORTED
%% msg = undefined identifies this case.

decode_avps(MsgName, Mod, Pkt, Avps) ->  %% ... or not
    {Rec, As, Failed} = Mod:decode_avps(MsgName, Avps),
    ?LOGC([] /= Failed, failed, {Mod, Failed}),
    Pkt#diameter_packet{msg = Rec,
                        errors = Failed,
                        avps = As}.

%%% ---------------------------------------------------------------------------
%%% # decode_header/1
%%% ---------------------------------------------------------------------------

decode_header(<<Version:8,
                MsgLength:24,
                CmdFlags:1/binary,
                CmdCode:24,
                ApplicationId:32,
                HopByHopId:32,
                EndToEndId:32,
                _/bitstring>>) ->
    <<R:1, P:1, E:1, T:1, _:4>>
        = CmdFlags,
    %% 3588 (ch 3) says that reserved bits MUST be set to 0 and ignored
    %% by the receiver.

    %% The RFC is quite unclear about the order of the bits in this
    %% case. It writes
    %%
    %%    0 1 2 3 4 5 6 7
    %%   +-+-+-+-+-+-+-+-+
    %%   |R P E T r r r r|
    %%   +-+-+-+-+-+-+-+-+
    %%
    %% in defining these but the scale refers to the (big endian)
    %% transmission order, first to last, not the bit order. That is,
    %% R is the high order bit. It's odd that a standard reserves
    %% low-order bit rather than high-order ones.

    #diameter_header{version = Version,
                     length = MsgLength,
                     cmd_code = CmdCode,
                     application_id = ApplicationId,
                     hop_by_hop_id = HopByHopId,
                     end_to_end_id = EndToEndId,
                     is_request       = 1 == R,
                     is_proxiable     = 1 == P,
                     is_error         = 1 == E,
                     is_retransmitted = 1 == T};

decode_header(_) ->
    false.

%%% ---------------------------------------------------------------------------
%%% # sequence_numbers/1
%%% ---------------------------------------------------------------------------

%% The End-To-End identifier must be unique for at least 4 minutes. We
%% maintain a 24-bit wraparound counter, and add an 8-bit persistent
%% wraparound counter. The 8-bit counter is incremented each time the
%% system is restarted.

sequence_numbers({_,_} = T) ->
    T;

sequence_numbers(#diameter_packet{bin = Bin})
  when is_binary(Bin) ->
    sequence_numbers(Bin);

sequence_numbers(#diameter_packet{header = #diameter_header{} = H}) ->
    sequence_numbers(H);

sequence_numbers(#diameter_header{hop_by_hop_id = H,
                                  end_to_end_id = E}) ->
    {H,E};

sequence_numbers(<<_:12/binary, H:32, E:32, _/binary>>) ->
    {H,E}.

%%% ---------------------------------------------------------------------------
%%% # hop_by_hop_id/2
%%% ---------------------------------------------------------------------------

hop_by_hop_id(Id, <<H:12/binary, _:32, T/binary>>) ->
    <<H/binary, Id:32, T/binary>>.

%%% ---------------------------------------------------------------------------
%%% # msg_name/2
%%% ---------------------------------------------------------------------------

msg_name(Dict0, #diameter_header{application_id = ?APP_ID_COMMON,
                                 cmd_code = C,
                                 is_request = R}) ->
    Dict0:msg_name(C,R);

msg_name(_, Hdr) ->
    msg_id(Hdr).

%% Note that messages in different applications could have the same
%% name.

%%% ---------------------------------------------------------------------------
%%% # msg_id/1
%%% ---------------------------------------------------------------------------

msg_id(#diameter_packet{msg = [#diameter_header{} = Hdr | _]}) ->
    msg_id(Hdr);

msg_id(#diameter_packet{header = #diameter_header{} = Hdr}) ->
    msg_id(Hdr);

msg_id(#diameter_header{application_id = A,
                        cmd_code = C,
                        is_request = R}) ->
    {A, C, if R -> 1; true -> 0 end};

msg_id(<<_:32, Rbit:1, _:7, CmdCode:24, ApplId:32, _/bitstring>>) ->
    {ApplId, CmdCode, Rbit}.

%%% ---------------------------------------------------------------------------
%%% # collect_avps/1
%%% ---------------------------------------------------------------------------

%% Note that the returned list of AVP's is reversed relative to their
%% order in the binary. Note also that grouped avp's aren't unraveled,
%% only those at the top level.

collect_avps(#diameter_packet{bin = Bin}) ->
    <<_:20/binary, Avps/bitstring>> = Bin,
    collect_avps(Avps);

collect_avps(Bin) ->
    collect_avps(Bin, 0, []).

collect_avps(<<>>, _, Acc) ->
    Acc;
collect_avps(Bin, N, Acc) ->
    try split_avp(Bin) of
        {Rest, AVP} ->
            collect_avps(Rest, N+1, [AVP#diameter_avp{index = N} | Acc])
    catch
        ?FAILURE(_) ->
            {Bin, Acc}
    end.

%%     0                   1                   2                   3
%%     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |                           AVP Code                            |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |V M P r r r r r|                  AVP Length                   |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |                        Vendor-ID (opt)                        |
%%    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%    |    Data ...
%%    +-+-+-+-+-+-+-+-+

%% split_avp/1

split_avp(Bin) ->
    8 =< size(Bin) orelse ?THROW(truncated_header),

    <<Code:32, Flags:1/binary, Length:24, Rest/bitstring>>
        = Bin,

    8 =< Length orelse ?THROW(invalid_avp_length),

    DataSize = Length - 8,        % size(Code+Flags+Length) = 8 octets
    PadSize = (4 - (DataSize rem 4)) rem 4,

    DataSize + PadSize =< size(Rest)
        orelse ?THROW(truncated_data),

    <<Data:DataSize/binary, _:PadSize/binary, R/bitstring>>
        = Rest,
    <<Vbit:1, Mbit:1, Pbit:1, _Reserved:5>>
        = Flags,

    0 == Vbit orelse 4 =< size(Data)
        orelse ?THROW(truncated_vendor_id),

    {Vid, D} = vid(Vbit, Data),
    {R, #diameter_avp{code = Code,
                      vendor_id = Vid,
                      is_mandatory = 1 == Mbit,
                      need_encryption = 1 == Pbit,
                      data = D}}.

%% The RFC is a little misleading when stating that OctetString is
%% padded to a 32-bit boundary while other types align naturally. All
%% other types are already multiples of 32 bits so there's no need to
%% distinguish between types here. Any invalid lengths will result in
%% decode error in diameter_types.

vid(1, <<Vid:32, Data/bitstring>>) ->
    {Vid, Data};
vid(0, Data) ->
    {undefined, Data}.

%%% ---------------------------------------------------------------------------
%%% # pack_avp/1
%%% ---------------------------------------------------------------------------

%% The normal case here is data as an #diameter_avp{} list or an
%% iolist, which are the cases that generated codec modules use. The
%% other case is as a convenience in the relay case in which the
%% dictionary doesn't know about specific AVP's.

%% Grouped AVP whose components need packing ...
pack_avp(#diameter_avp{data = [#diameter_avp{} | _] = Avps} = A) ->
    pack_avp(A#diameter_avp{data = encode_avps(Avps)});

%% ... data as a type/value tuple, possibly with header data, ...
pack_avp(#diameter_avp{data = {Type, Value}} = A)
  when is_atom(Type) ->
    pack_avp(A#diameter_avp{data = diameter_types:Type(encode, Value)});
pack_avp(#diameter_avp{data = {{_,_,_} = T, {Type, Value}}}) ->
    pack_avp(T, iolist_to_binary(diameter_types:Type(encode, Value)));
pack_avp(#diameter_avp{data = {{_,_,_} = T, Bin}})
  when is_binary(Bin) ->
    pack_avp(T, Bin);
pack_avp(#diameter_avp{data = {Dict, Name, Value}} = A) ->
    {Code, _Flags, Vid} = Hdr = Dict:avp_header(Name),
    {Name, Type} = Dict:avp_name(Code, Vid),
    pack_avp(A#diameter_avp{data = {Hdr, {Type, Value}}});

%% ... or as an iolist.
pack_avp(#diameter_avp{code = Code,
                       vendor_id = V,
                       is_mandatory = M,
                       need_encryption = P,
                       data = Data}) ->
    Flags = lists:foldl(fun flag_avp/2, 0, [{V /= undefined, 2#10000000},
                                            {M, 2#01000000},
                                            {P, 2#00100000}]),
    pack_avp({Code, Flags, V}, iolist_to_binary(Data)).

flag_avp({true, B}, F) ->
    F bor B;
flag_avp({false, _}, F) ->
    F.

%%% ---------------------------------------------------------------------------
%%% # pack_avp/2
%%% ---------------------------------------------------------------------------

pack_avp({Code, Flags, VendorId}, Bin)
  when is_binary(Bin) ->
    Sz = size(Bin),
    pack_avp(Code, Flags, VendorId, Sz, pad(Sz rem 4, Bin)).

pad(0, Bin) ->
    Bin;
pad(N, Bin) ->
    P = 8*(4-N),
    <<Bin/binary, 0:P>>.
%% Note that padding is not included in the length field as mandated by
%% the RFC.

%% pack_avp/5
%%
%% Prepend the vendor id as required.

pack_avp(Code, Flags, Vid, Sz, Bin)
  when 0 == Flags band 2#10000000 ->
    undefined = Vid,  %% sanity check
    pack_avp(Code, Flags, Sz, Bin);

pack_avp(Code, Flags, Vid, Sz, Bin) ->
    pack_avp(Code, Flags, Sz+4, <<Vid:32, Bin/binary>>).

%% pack_avp/4

pack_avp(Code, Flags, Sz, Bin) ->
    Length = Sz + 8,
    <<Code:32, Flags:8, Length:24, Bin/binary>>.
