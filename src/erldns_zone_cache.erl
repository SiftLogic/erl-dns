%% Copyright (c) 2012-2014, Aetrion LLC
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% @doc A cache holding all of the zone data.
%%
%% Write operations occur through the cache process mailbox, whereas read
%% operations may occur either through the mailbox or directly through the
%% underlying data store, depending on performance requirements.
-module(erldns_zone_cache).

-behavior(gen_server).

-include_lib("dns/include/dns.hrl").
-include("erldns.hrl").

-export([start_link/0]).

% Read APIs
-export([
         find_zone/1,
         find_zone/2,
         get_zone/1,
         get_zone_with_records/1,
         get_authority/1,
         get_delegations/1,
         get_records_by_name/1,
         in_zone/1,
         zone_names_and_versions/0
        ]).

% Write APIs
-export([
         put_zone/1,
         put_zone/2,
         put_zone_async/1,
         put_zone_async/2,
         delete_zone/1,
         add_record/2,
         delete_record/2,
         update_record/3
        ]).

% Gen server hooks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-define(SERVER, ?MODULE).

-record(state, {parsers, tref = none}).

%% @doc Start the zone cache process.
-spec start_link() -> any().
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

% ----------------------------------------------------------------------------------------------------
% Read API

%% @doc Find a zone for a given qname.
-spec find_zone(dns:dname()) -> {ok, #zone{}} | {error, zone_not_found} | {error, not_authoritative}.
find_zone(Qname) ->
  find_zone(normalize_name(Qname), get_authority(Qname)).

%% @doc Find a zone for a given qname.
-spec find_zone(dns:dname(), {error, any()} | {ok, dns:rr()} | [dns:rr()] | dns:rr()) ->
  {ok, #zone{}} | {error, zone_not_found} | {error, not_authoritative}.
find_zone(Qname, {error, _}) ->
  find_zone(Qname, []);
find_zone(Qname, {ok, Authority}) ->
  find_zone(Qname, Authority);
find_zone(_Qname, []) ->
  {error, not_authoritative};
find_zone(Qname, Authorities) when is_list(Authorities) ->
  find_zone(Qname, lists:last(Authorities));
find_zone(Qname, Authority) when is_record(Authority, dns_rr) ->
  Name = normalize_name(Qname),
  case dns:dname_to_labels(Name) of
    [] -> {error, zone_not_found};
    [_] -> {error, zone_not_found};
    [_|Labels] ->
      case get_zone(Name) of
        {ok, Zone} -> Zone;
        {error, zone_not_found} ->
          case Name =:= Authority#dns_rr.name of
            true -> {error, zone_not_found};
            false -> find_zone(dns:labels_to_dname(Labels), Authority)
          end
      end
  end.

%% @doc Get a zone for the specific name. This function will not attempt to resolve
%% the dname in any way, it will simply look up the name in the underlying data store.
-spec get_zone(dns:dname()) -> {ok, #zone{}} | {error, zone_not_found}.
get_zone(Name) ->
  NormalizedName = normalize_name(Name),
  case erldns_storage:select(zones, NormalizedName) of
    [{NormalizedName, Zone}] ->
        {ok, Zone#zone{name = NormalizedName, records = [], records_by_name=trimmed}};
    _Res ->
        {error, zone_not_found}
  end.

%% @doc Get a zone for the specific name, including the records for the zone.
-spec get_zone_with_records(dns:dname()) -> {ok, #zone{}} | {error, zone_not_found}.
get_zone_with_records(Name) ->
  NormalizedName = normalize_name(Name),
  case erldns_storage:select(zones, NormalizedName) of
    [{NormalizedName, Zone}] -> {ok, Zone};
    _ -> {error, zone_not_found}
  end.

%% @doc Find the SOA record for the given DNS question.
-spec get_authority(dns:message() | dns:dname()) -> {error, no_question} | {error, no_authority} | {ok, dns:rr()}.
get_authority(Message) when is_record(Message, dns_message) ->
  case Message#dns_message.questions of
    [] -> {error, no_question};
    Questions -> 
      Question = lists:last(Questions),
      get_authority(Question#dns_query.name)
  end;
get_authority(Name) ->
  case find_zone_in_cache(normalize_name(Name)) of
    {ok, Zone} -> {ok, Zone#zone.authority};
    _ -> {error, authority_not_found}
  end.

%% @doc Get the list of NS and glue records for the given name. This function
%% will always return a list, even if it is empty.
-spec get_delegations(dns:dname()) -> [dns:rr()] | [].
get_delegations(Name) ->
  case find_zone_in_cache(Name) of
    {ok, Zone} ->
      lists:filter(fun(R) -> apply(erldns_records:match_type(?DNS_TYPE_NS), [R]) and apply(erldns_records:match_glue(Name), [R]) end, Zone#zone.records);
    _ ->
      []
  end.

%% @doc Return the record set for the given dname.
-spec get_records_by_name(dns:dname()) -> [dns:rr()].
get_records_by_name(Name) ->
    case find_zone_in_cache(Name) of
        {ok, Zone} ->
%%             erldns_log:info("~p-> found zone: ~p~n~n", [?MODULE, Zone]),
            case dict:find(normalize_name(Name), Zone#zone.records_by_name) of
                {ok, RecordSet} ->
%%                     erldns_log:info("~p-> Record Set: ~p", [?MODULE, RecordSet]),
                    RecordSet;
                _ -> []
            end;
        _ ->
            []
    end.

%% @doc Check if the name is in a zone.
-spec in_zone(binary()) -> boolean().
in_zone(Name) ->
  case find_zone_in_cache(Name) of
    {ok, Zone} ->
      is_name_in_zone(Name, Zone);
    _ ->
      false
  end.

%% @doc Return a list of tuples with each tuple as a name and the version SHA
%% for the zone.
-spec zone_names_and_versions() -> [{dns:dname(), binary()}].
zone_names_and_versions() ->
  erldns_storage:foldl(fun(#zone{name = Name, version = Version}, NamesAndShas) ->
                         [{Name, Version} | NamesAndShas]
                       end, [], zones).

% ----------------------------------------------------------------------------------------------------
% Write API

%% @doc Put a name and its records into the cache, along with a SHA which can be
%% used to determine if the zone requires updating.
%%
%% This function will build the necessary Zone record before interting.
-spec put_zone({binary(), binary(), [#dns_rr{}]}) -> ok | {error, Reason :: term()}.
put_zone({Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
    NotifySourceIP}) ->
  erldns_storage:insert(zones, {normalize_name(Name), build_zone(Name, Sha, Records, AllowNotifyList,
      AllowTransferList, AllowUpdateList, AlsoNotifyList, NotifySourceIP)}).

%% @doc Put a zone into the cache and wait for a response.
-spec put_zone(binary(), #zone{}) -> ok | {error, Reason :: term()}.
put_zone(Name, #zone{} = Zone) ->
  erldns_storage:insert(zones, {normalize_name(Name), Zone}).

%% @doc Put a zone into the cache without waiting for a response.
-spec put_zone_async({binary(), binary(), [#dns_rr{}]}) -> ok | {error, Reason :: term()}.
put_zone_async({Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
    NotifySourceIP}) ->
  erldns_storage:insert(zones, {normalize_name(Name), build_zone(Name, Sha, Records, AllowNotifyList,
      AllowTransferList, AllowUpdateList, AlsoNotifyList, NotifySourceIP)}).

%% @doc Put a zone into the cache without waiting for a response.
-spec put_zone_async(binary(), #zone{}) -> ok | {error, Reason :: term()}.
put_zone_async(Name, Zone) ->
  erldns_storage:insert(zones, {normalize_name(Name), Zone}).

%% @doc Remove a zone from the cache without waiting for a response.
-spec delete_zone(binary()) -> any().
delete_zone(Name) ->
  gen_server:cast(?SERVER, {delete, Name}).

%% @doc Add a record to a particular zone.
-spec add_record(binary(), #dns_rr{}) -> ok | {error, term()}.
add_record(ZoneName, #dns_rr{} = Record) ->
    {ok, Zone0} = get_zone_with_records(normalize_name(ZoneName)),
    Records0 = Zone0#zone.records,
    %% Ensure no exact duplicates are found
    [true = Record =/= X || X <- Records0],
    Records = [Record] ++ Records0,
    %% Update serial number
    Authorities0 = hd(Zone0#zone.authority),
    SOA0 = Authorities0#dns_rr.data,
    Serial = SOA0#dns_rrdata_soa.serial,
    SOA = SOA0#dns_rrdata_soa{serial = Serial + 1},
    Authorities = Authorities0#dns_rr{data = SOA},
    Zone = build_zone(ZoneName, Zone0#zone.version, Records ++ [Authorities], Zone0#zone.allow_notify,
    Zone0#zone.allow_transfer, Zone0#zone.allow_update, Zone0#zone.also_notify, Zone0#zone.notify_source),
    %% Put zone back into cache.
    put_zone(ZoneName, Zone),
    send_notify(ZoneName, Zone).

%% @doc Delete a record from a particular zone.
-spec delete_record(binary(), #dns_rr{}) -> ok | {error, term()}.
delete_record(ZoneName, #dns_rr{} = Record) ->
    {ok, Zone0} = get_zone_with_records(normalize_name(ZoneName)),
    Records0 = Zone0#zone.records,
    Records = lists:delete(Record, Records0),
    %% Update serial number
    Authorities0 = hd(Zone0#zone.authority),
    SOA0 = Authorities0#dns_rr.data,
    Serial = SOA0#dns_rrdata_soa.serial,
    SOA = SOA0#dns_rrdata_soa{serial = Serial + 1},
    Authorities = Authorities0#dns_rr{data = SOA},
    Zone = build_zone(ZoneName, Zone0#zone.version, Records ++ [Authorities], Zone0#zone.allow_notify,
    Zone0#zone.allow_transfer, Zone0#zone.allow_update, Zone0#zone.also_notify, Zone0#zone.notify_source),
    %% Put zone back into cache.
    put_zone(ZoneName, Zone),
    send_notify(ZoneName, Zone).

%% @doc Update a record in a zone.
-spec update_record(binary(), #dns_rr{}, #dns_rr{}) -> ok | {error, term()}.
update_record(ZoneName, #dns_rr{} = OldRecord, #dns_rr{} = UpdatedRecord) ->
    {ok, Zone0} = get_zone_with_records(normalize_name(ZoneName)),
    Records0 = Zone0#zone.records,
    Records1 = lists:delete(OldRecord, Records0),
    Records = [UpdatedRecord] ++ Records1,
    %% Update serial number
    Authorities0 = hd(Zone0#zone.authority),
    SOA0 = Authorities0#dns_rr.data,
    Serial = SOA0#dns_rrdata_soa.serial,
    SOA = SOA0#dns_rrdata_soa{serial = Serial + 1},
    Authorities = Authorities0#dns_rr{data = SOA},
    Zone = build_zone(ZoneName, Zone0#zone.version, Records ++ [Authorities], Zone0#zone.allow_notify,
    Zone0#zone.allow_transfer, Zone0#zone.allow_update, Zone0#zone.also_notify, Zone0#zone.notify_source),
    %% Put zone back into cache.
    put_zone(ZoneName, Zone),
    send_notify(ZoneName, Zone).
% ----------------------------------------------------------------------------------------------------
% Gen server init

%% @doc Initialize the zone cache.
-spec init([]) -> {ok, #state{}}.
init([]) ->
  case erldns_config:storage_type() of
    erldns_storage_mnesia ->
        erldns_storage:create(schema);
    _ ->
        ok
  end,
  erldns_storage:create(zones),
  erldns_storage:create(authorities),
  {ok, #state{parsers = []}}.

% ----------------------------------------------------------------------------------------------------
% gen_server callbacks

%% @doc Write the zone into the cache.
handle_call({put, Name, Zone}, _From, State) ->
  erldns_storage:insert(zones, {normalize_name(Name), Zone}),
  {reply, ok, State};

handle_call({put, Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
    NotifySourceIP}, _From, State) ->
  erldns_storage:insert(zones, {normalize_name(Name), build_zone(Name, Sha, Records, AllowNotifyList,
      AllowTransferList, AllowUpdateList, AlsoNotifyList, NotifySourceIP)}),
  {reply, ok, State}.

handle_cast({put, Name, Zone}, State) ->
  erldns_storage:insert(zones, {normalize_name(Name), Zone}),
  {noreply, State};

handle_cast({put, Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
    NotifySourceIP}, State) ->
  erldns_storage:insert(zones, {normalize_name(Name), build_zone(Name, Sha, Records, AllowNotifyList,
      AllowTransferList, AllowUpdateList, AlsoNotifyList, NotifySourceIP)}),
  {noreply, State};

handle_cast({delete, Name}, State) ->
  erldns_storage:delete(zones, normalize_name(Name)),
  {noreply, State};

handle_cast(Message, State) ->
  erldns_log:debug("Received unsupported message: ~p", [Message]),
  {noreply, State}.

handle_info(_Message, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_PreviousVersion, State, _Extra) ->
  {ok, State}.


% Internal API
is_name_in_zone(Name, Zone) ->
  case dict:is_key(normalize_name(Name), Zone#zone.records_by_name) of
    true -> true;
    false ->
      case dns:dname_to_labels(Name) of
        [] -> false;
        [_] -> false;
        [_|Labels] -> is_name_in_zone(dns:labels_to_dname(Labels), Zone)
      end
  end.

find_zone_in_cache(Qname) ->
  Name = normalize_name(Qname),
  case dns:dname_to_labels(Name) of
    [] -> {error, zone_not_found};
    [_] -> {error, zone_not_found};
    [_|Labels] ->
      case erldns_storage:select(zones, Name) of
        [{Name, Zone}] -> {ok, Zone};
        _ -> find_zone_in_cache(dns:labels_to_dname(Labels))
      end
  end.

build_zone(Qname, Version, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
    NotifySourceIP) ->
  RecordsByName = build_named_index(Records),
  Authorities = lists:filter(erldns_records:match_type(?DNS_TYPE_SOA), Records),
  #zone{name = Qname, allow_notify = AllowNotifyList, allow_transfer = AllowTransferList,
      allow_update = AllowUpdateList, also_notify = AlsoNotifyList, notify_source = NotifySourceIP,
      version = Version, record_count = length(Records), authority = Authorities, records = Records, records_by_name = RecordsByName}.

build_named_index(Records) -> build_named_index(Records, dict:new()).
build_named_index([], Idx) -> Idx;
build_named_index([R|Rest], Idx) ->
  case dict:find(R#dns_rr.name, Idx) of
    {ok, Records} ->
      build_named_index(Rest, dict:store(normalize_name(R#dns_rr.name), Records ++ [R], Idx));
    error ->
      build_named_index(Rest, dict:store(normalize_name(R#dns_rr.name), [R], Idx))
  end.

normalize_name(Name) when is_list(Name) -> string:to_lower(Name);
normalize_name(Name) when is_binary(Name) -> list_to_binary(string:to_lower(binary_to_list(Name))).

%% The primary master name server determines which servers are the slaves for the zone by looking at
%% the list of NS records in the zone and taking out the record that points to the name server listed
%% in the MNAME field of the zone's SOA record as well as the domain name of the local host.

%% RFC 1996
%% NOTIFY SET
%% set of servers to be notified of changes to some
%% zone.  Default is all servers named in the NS RRset,
%% except for any server also named in the SOA MNAME.
%% Some implementations will permit the name server
%% administrator to override this set or add elements to
%% it (such as, for example, stealth servers).
send_notify(ZoneName, Zone) ->
    Records = Zone#zone.records,
    erldns_log:info("Records ~p", [Records]),
    NotifySet = get_notify_set(Records),
    erldns_log:info("Notify set: ~p", [NotifySet]),
    %%Find the A record for this name server to get the ip(s)
    NotifySetIPs = get_ips_for_notify_set(Records, NotifySet),
    erldns_log:info("Notify IPs: ~p", [NotifySetIPs]),
    %% Now send the notify message out to the set of IPs
    BindIP = case Zone#zone.notify_source of
                 <<>> ->
                     {127, 0, 0, 1};
                 IP ->
                     IP
             end,
    lists:foldl(fun(IP, Acc) ->
        [gen_server:cast(erldns_manager, {send_notify, {BindIP, IP, ?DNS_LISTEN_PORT,
            ZoneName, ?DNS_CLASS_IN}}) | Acc]
        end, [], NotifySetIPs).

get_notify_set(Records) ->
    get_notify_set(Records, [], []).

get_notify_set([], SOA, NameServers) ->
    %% Remove mnames, and duplicates from final result
    exclude_mname_duplicates(SOA, NameServers);
get_notify_set([Head | Tail], SOA, NameServers) ->
    case Head#dns_rr.data of
        #dns_rrdata_soa{}  = Authority ->
            get_notify_set(Tail, Authority, NameServers);
        #dns_rrdata_ns{} = NS ->
            get_notify_set(Tail, SOA, [NS | NameServers]);
        _ ->
            get_notify_set(Tail, SOA, NameServers)
    end.

exclude_mname_duplicates(SOA, NameServers) ->
    MName = SOA#dns_rrdata_soa.mname,
    lists:foldl(fun(NameServer, Acc0) ->
        case NameServer#dns_rrdata_ns.dname =:= MName of
            true ->
                %% Found a NS record that is also a mname of an SOA, exclude it
                Acc0;
            false ->
                [NameServer | Acc0]
        end
    end, [], NameServers).

get_ips_for_notify_set(Records, NotifySet) ->
    get_ips_for_notify_set(Records, NotifySet, []).

get_ips_for_notify_set(_Records, [], IPs) ->
    IPs;
get_ips_for_notify_set(Records, [Head | Tail], IPs) ->
    DName = Head#dns_rrdata_ns.dname,
    ARecord0 = lists:keyfind(DName, 2, Records),
    ARecord = ARecord0#dns_rr.data,
    erldns_log:info("A record: ~p", [ARecord]),
    case ARecord of
        #dns_rrdata_a{} ->
            get_ips_for_notify_set(Records, Tail, [ARecord#dns_rrdata_a.ip | IPs]);
        #dns_rrdata_aaaa{} ->
            get_ips_for_notify_set(Records, Tail, [ARecord#dns_rrdata_aaaa.ip | IPs])
    end.

