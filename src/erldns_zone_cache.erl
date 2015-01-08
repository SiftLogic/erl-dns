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
-include_lib("egeoip/include/egeoip.hrl").
-include("erldns.hrl").

-export([start_link/0]).

%% Read APIs
-export([
         find_zone/1,
         find_zone/2,
         get_zone/1,
         get_zones_for_slave/1,
         get_zone_with_records/1,
         get_authority/1,
         get_delegations/1,
         get_records_by_name/1,
         get_records_by_name/3,
         in_zone/1,
         zone_names/0,
         zone_names_and_versions/0,
         update_records/2,
         match_georecords/3,
         get_zone_allow_notify/1,
         get_zone_allow_transfer/1,
         get_zone_allow_update/1,
         get_zone_also_notify/1,
         get_zone_notify_source/1
        ]).

%% Write APIs
-export([
         build_zone/1,
         build_zone/8,
         build_zone/9,
         add_new_zone/2,
         put_zone/1,
         put_zone/2,
         put_zone_async/1,
         put_zone_async/2,
         delete_zone/1,
         delete_zone_permanently/1,
         add_record/3,
         delete_record/3,
         update_record/4,
         increment_soa/1
        ]).

-export([get_ips_for_notify_set/1]).

%% Gen server hooks
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

%% -----------------------------------------------------------------------------------------------
%% Read API

%% @doc Find a zone for a given qname.
-spec find_zone(dns:dname()) -> {ok, #zone{}} | {error, {zone_not_found, binary()}}
                                    | {error, not_authoritative}.
find_zone(Qname) ->
    find_zone(normalize_name(Qname), get_authority(Qname)).

%% @doc Find a zone for a given qname.
-spec find_zone(dns:dname(), {error, any()} | {ok, dns:rr()} | [dns:rr()] | dns:rr()) ->
                       #zone{} | {error, {zone_not_found, binary()}} | {error, not_authoritative}.
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
        [] -> {error, {zone_not_found, Name}};
        [_] -> {error, {zone_not_found, Name}};
        [_|Labels] ->
            case get_zone(Name) of
                {ok, Zone} -> Zone;
                {error, {zone_not_found, Name}} ->
                    case Name =:= Authority#dns_rr.name of
                        true -> {error, {zone_not_found, Name}};
                        false -> find_zone(dns:labels_to_dname(Labels), Authority)
                    end
            end
    end.

%% @doc Get a zone for the specific name. This function will not attempt to resolve
%% the dname in any way, it will simply look up the name in the underlying data store.
-spec get_zone(dns:dname()) -> {ok, #zone{}} | {error, {zone_not_found, binary()}}.
get_zone(Name) ->
    NormalizedName = normalize_name(Name),
    case erldns_storage:select(zones, NormalizedName) of
        [{NormalizedName, Zone}] ->
            {ok, Zone#zone{name = NormalizedName, records = [], records_by_name=trimmed}};
        _Res ->
            {error, {zone_not_found, NormalizedName}}
    end.

%% @doc This function takes an IP address. Finds the zones that the IP should be holding and returns
%% the zone names.
%% @end
-spec get_zones_for_slave(inet:ip_address()) -> [binary()].
get_zones_for_slave(Addr) ->
    lists:foldl(fun(ZoneName, Acc) ->
                        {ok, #zone{records = Records} = Zone} = get_zone_with_records(ZoneName),
                        case lists:member(Addr, get_ips_for_notify_set(Records)) of
                            true ->
                                [Zone#zone{records = [], authority = [], records_by_name = [], records_by_type = []} | Acc];
                            false ->
                                erldns_log:info("IP ~p is not part of notifyset in ~p", [Addr, get_ips_for_notify_set(Records)]),
                                Acc
                        end
                end, [], zone_names()).


%% @doc Get a zone for the specific name, including the records for the zone.
-spec get_zone_with_records(dns:dname()) -> {ok, #zone{}} | {error, {zone_not_found, binary()}}.
get_zone_with_records(Name) ->
    NormalizedName = normalize_name(Name),
    case erldns_storage:select(zones, NormalizedName) of
        [{NormalizedName, Zone}] -> {ok, Zone};
        _Error ->
            erldns_log:error("Error getting zone ~p: ~p", [NormalizedName, _Error]),
            {error, {zone_not_found, NormalizedName}}
    end.

%% @doc Retrieve the allow_notify option from zone.
-spec get_zone_allow_notify(binary()) -> [inet:ip_address()] | {error, {zone_not_found, binary()}}.
get_zone_allow_notify(ZoneName) ->
    NormalizedName = normalize_name(ZoneName),
    case erldns_storage:select(zones, NormalizedName) of
        [{NormalizedName, Zone}] ->
            Zone#zone.allow_notify;
        _ ->
            {error, {zone_not_found, NormalizedName}}
    end.

%% @doc Retrieve the allow_transfer option from zone.
-spec get_zone_allow_transfer(binary()) -> [inet:ip_address()] | {error, {zone_not_found, binary()}}.
get_zone_allow_transfer(ZoneName) ->
    NormalizedName = normalize_name(ZoneName),
    case erldns_storage:select(zones, NormalizedName) of
        [{NormalizedName, Zone}] ->
            Zone#zone.allow_transfer;
        _ ->
            {error, {zone_not_found, NormalizedName}}
    end.

%% @doc Retrieve the allow_update option from zone.
-spec get_zone_allow_update(binary()) -> [inet:ip_address()] | {error, {zone_not_found, binary()}}.
get_zone_allow_update(ZoneName) ->
    NormalizedName = normalize_name(ZoneName),
    case erldns_storage:select(zones, NormalizedName) of
        [{NormalizedName, Zone}] ->
            Zone#zone.allow_update;
        _ ->
            {error, {zone_not_found, NormalizedName}}
    end.

%% @doc Retrieve the also_notify option from zone.
-spec get_zone_also_notify(binary()) -> [inet:ip_address()] | {error, {zone_not_found, binary()}}.
get_zone_also_notify(ZoneName) ->
    NormalizedName = normalize_name(ZoneName),
    case erldns_storage:select(zones, NormalizedName) of
        [{NormalizedName, Zone}] ->
            Zone#zone.also_notify;
        _ ->
            {error, {zone_not_found, NormalizedName}}
    end.

%% @doc Retrieve the notify-source option from zone.
-spec get_zone_notify_source(binary()) -> inet:ip_address() | {error, {zone_not_found, binary()}}.
get_zone_notify_source(ZoneName) ->
    NormalizedName = normalize_name(ZoneName),
    case erldns_storage:select(zones, NormalizedName) of
        [{NormalizedName, Zone}] ->
            Zone#zone.notify_source;
        _ ->
            {error, {zone_not_found, NormalizedName}}
    end.

%% @doc Find the SOA record for the given DNS question.
-spec get_authority(dns:message() | dns:dname()) -> {error, no_question}
                                                        | {error, authority_not_found} | {ok, dns:rr()}.
get_authority(Message) when is_record(Message, dns_message) ->
    case Message#dns_message.questions of
        [] -> {error, no_question};
        Questions ->
            Question = lists:last(Questions),
            get_authority(Question#dns_query.name)
    end;
get_authority(Name) ->
    case find_zone_in_cache(normalize_name(Name)) of
        {ok, Zone} ->
            {ok, Zone#zone.authority};
        _ -> {error, authority_not_found}
    end.

%% @doc Get the list of NS and glue records for the given name. This function
%% will always return a list, even if it is empty.
-spec get_delegations(dns:dname()) -> [dns:rr()] | [].
get_delegations(Name) ->
    case find_zone_in_cache(Name) of
        {ok, Zone} ->
            lists:filter(fun(R)
                            -> apply(erldns_records:match_type(?DNS_TYPE_NS), [R]) and
                                   apply(erldns_records:match_glue(Name), [R]) end, Zone#zone.records);
        _ ->
            []
    end.

%% @doc Return the record set for the given dname.
-spec get_records_by_name(dns:dname()) -> [dns:rr()].
get_records_by_name(Name) ->
    case find_zone_in_cache(Name) of
        {ok, Zone} ->
            case dict:find(normalize_name(Name), Zone#zone.records_by_name) of
                {ok, RecordSet} ->
                    remove_expiry(RecordSet);
                _ -> []
            end;
        _ ->
            []
    end.

%% @doc This function takes the query type and client IP to match georecords.
get_records_by_name(Name, Qtype, ClientIP) ->
    case match_georecords(ClientIP, Name, Qtype) of
        [] ->
            get_records_by_name(Name);
        MatchedRecords ->
            MatchedRecords
    end.

%% @doc This function updates all records in the zone for the slave.
-spec update_records(inet:ip_address(), dns:dname()) -> ok.
update_records(ServerIP, Qname) ->
    Name = normalize_name(Qname),
    case get_zone_notify_source(Name) of
        {error, _} ->
            ok;
        NotifySource ->
            case ServerIP =:= NotifySource of
                true ->
                    ok;
                false ->
                    %% We are slave, get the zone in the cache and the records from the dict with expirys.
                    case find_zone_in_cache(Name) of
                        {ok, Zone} ->
                            case dict:find(Name, Zone#zone.records_by_name) of
                                {ok, RecordSet} ->
                                    update_records(Name, Zone#zone.notify_source, ServerIP, RecordSet, []),
                                    ok;
                                _ -> ok
                            end;
                        _ ->
                            ok
                    end
            end
    end.

update_records(ZoneName, MasterIP, ServerIP, [], QueryAcc) ->
    %% Query server for records that needed to be updated, and merge them with records that didn't.
    NewRecords = query_master_for_records(MasterIP, ServerIP, QueryAcc),
    [delete_record(ZoneName, OldRecord, false) || OldRecord <- QueryAcc],
    [add_record(ZoneName, R, false) || R <- NewRecords];
update_records(ZoneName, MasterIP, ServerIP, [{Expiry, Record} | Tail], QueryAcc) ->
    %% Get the timestamp of the record
    case timestamp() < Expiry of
        true ->
            update_records(ZoneName, MasterIP, ServerIP, Tail, QueryAcc);
        false ->
            update_records(ZoneName, MasterIP, ServerIP, Tail, [Record | QueryAcc])
    end.

%% @doc This function takes a list of records, builds a query and sends it to master for updated
%% records
%% @end
-spec query_master_for_records(inet:ip_address(), inet:ip_address(), [] | [dns:rr()]) -> [] | [dns:rr()].
query_master_for_records(_MasterIP, _ServerIP, []) ->
    [];
query_master_for_records(MasterIP, ServerIP, QueryList) ->
    erldns_zone_transfer_worker:query_for_records(MasterIP, ServerIP, QueryList).

%% @doc This functin recieves a list of dns_rr records and does all the magic as far as geolocation.
%% It will remove geolocation records, and match geolocation data with the record. It will remove duplicates
-spec match_georecords(inet:ip_address(),  dns:dname(), dns:type()) -> [dns:rr()].
%% TEST FUNCTIONS ----------------------------------
match_georecords({127,0,0,1}, Qname, Qtype) ->
    get_region(<<"NA">>, <<"US">>, <<"FL">>, Qname, Qtype);
match_georecords({10,1,10,51}, Qname, Qtype) ->
    get_region(<<"NA">>, <<"US">>, <<"FL">>, Qname, Qtype);
%% TEST FUNCTIONS ----------------------------------
match_georecords(ClientIP, Qname, Qtype) ->
    {ok, #geoip{country_code = Country, region = SubRegion}} = egeoip:lookup(ClientIP),
    case erldns_config:keyget(Country, ?COUNTRY_CODES) of
        <<"EU">> ->
            get_region(<<"EU">>, <<"EU">>, <<"EU">>, Qname, Qtype);
        Continent ->
            get_region(Continent, Country, SubRegion, Qname, Qtype)
    end.

%% @doc This function takes arguements to get the region from the lookup table
-spec get_region(binary(), binary(), binary(), dns:dname(), dns:type()) -> [binary()].
get_region(Continent, Country, SubRegion, Qname, Qtype) ->
    case erldns_storage:select(lookup_table, {Continent, Country, SubRegion}) of
        [{{_Continent, _Country, _SubRegion}, RegionName}] ->
            filter_georecords(RegionName, Qname, Qtype);
        _ ->
            []
    end.

%% @doc This function takes all the records in the zone, and filters out them by looking for
%% those of the same type and region in the name _geo.[REGION].example.com
-spec filter_georecords(binary(), dns:dname(), dns:type()) -> [dns:rr()].
filter_georecords(RegionName, QName, QType) ->
    case get_zone_with_records(QName) of
        {ok, Zone} ->
            filter_georecords(RegionName, QName, QType, Zone#zone.records, []);
        _ ->
            []
    end.

filter_georecords(_RegionName, _QName, _QType,  [], Acc) ->
    Acc;
filter_georecords(RegionName, QName, QType, [H | T], Acc) ->
    RegionSize = byte_size(RegionName),
    case H of
        #dns_rr{name = <<"_geo.", RegionName:RegionSize/binary, ".", QName/binary>>, type = QType} ->
            filter_georecords(RegionName, QName, QType, T, [H | Acc]);
        _ ->
            filter_georecords(RegionName, QName, QType, T, Acc)
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

%% @doc Return a list of zone names that are currently stored.
-spec zone_names() -> [{dns:dname()}].
zone_names() ->
    erldns_storage:foldl(fun(#zone{name = Name}, Names) ->
                                 [Name | Names]
                         end, [], zones).

%% -----------------------------------------------------------------------------------------------
%% Write API

%% @doc Add a new zone and send it to the slaves. Assumes that the zone was built using build_zone/1
-spec add_new_zone(binary(), #zone{}) -> ok | [ok].
add_new_zone(ZoneName, #zone{} = Zone) ->
    ok  = put_zone(ZoneName, Zone),
    gen_server:cast(erldns_admin_server, {add_zone, Zone#zone{records = [],
                                                              records_by_name = [], records_by_type = []},
                                          get_ips_for_notify_set(ZoneName)}).

%% @doc Put a name and its records into the cache, along with a SHA which can be
%% used to determine if the zone requires updating.
%%
%% This function will build the necessary Zone record before inserting.
-spec put_zone({binary(), binary(), [#dns_rr{}]}) -> ok | {error, Reason :: term()}.
put_zone({Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
          NotifySourceIP}) ->
    NormalizedName = normalize_name(Name),
    erldns_storage:insert(zones,
                          {NormalizedName, build_zone(NormalizedName, AllowNotifyList, AllowTransferList,
                                                      AllowUpdateList, AlsoNotifyList,
                                                      NotifySourceIP, Sha, normalize_records(Records))}).

%% @doc Put a zone into the cache and wait for a response.
-spec put_zone(binary(), #zone{}) -> ok | {error, Reason :: term()}.
put_zone(Name, #zone{records = Records, authority = [#dns_rr{name = AuthName} = Auth]} = Zone) ->
    NormalizedName = normalize_name(Name),
    erldns_storage:insert(zones, {NormalizedName,
                                  Zone#zone{name = NormalizedName,records = normalize_records(Records),
                                            authority = [Auth#dns_rr{name = normalize_name(AuthName)}]}}).

%% @doc Put a zone into the cache without waiting for a response.
-spec put_zone_async({binary(), binary(), [#dns_rr{}]}) -> ok | {error, Reason :: term()}.
put_zone_async({Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
                NotifySourceIP}) ->
    NormalizedName = normalize_name(Name),
    erldns_storage:insert(zones,
                          {NormalizedName, build_zone(NormalizedName, AllowNotifyList,AllowTransferList,
                                                      AllowUpdateList, AlsoNotifyList,
                                                      NotifySourceIP, Sha, normalize_records(Records))}).

%% @doc Put a zone into the cache without waiting for a response.
-spec put_zone_async(binary(), #zone{}) -> ok | {error, Reason :: term()}.
put_zone_async(Name, #zone{records = Records, authority = [#dns_rr{name = AuthName} = Auth]} = Zone) ->
    NormalizedName = normalize_name(Name),
    erldns_storage:insert(zones,
                          {NormalizedName, Zone#zone{name = NormalizedName,
                                                     authority = [Auth#dns_rr{name = normalize_name(AuthName)}],
                                                     records = normalize_records(Records)}}).

increment_soa(ZoneName) ->
    {ok, #zone{records = Records, authority =
                   [#dns_rr{data = #dns_rrdata_soa{serial = Serial} = SOA}] = [Authority]} = Zone0}
        = get_zone_with_records(normalize_name(ZoneName)),
    NewAuth = Authority#dns_rr{data = SOA#dns_rrdata_soa{serial = Serial + 1}},
    Zone = build_zone(Zone0#zone{records = remove_old_soa_add_new(Records, NewAuth),
                                 authority = [NewAuth]}),
    ok = put_zone(ZoneName, Zone),
    send_notify(ZoneName, Zone).

%% @doc Remove a zone from the cache.
-spec delete_zone(binary()) -> ok | {error, term()}.
delete_zone(Name) ->
    erldns_storage:delete(zones, normalize_name(Name)).

%% @doc Remove a zone from the cache permanently and notify slaves to remove the zone from their
%% storage as well.
%% @end
-spec delete_zone_permanently(binary()) -> ok | {error, term()}.
delete_zone_permanently(Name0) ->
    Name = normalize_name(Name0),
    gen_server:cast(erldns_admin_server, {delete_zone, Name, get_ips_for_notify_set(Name)}),
    erldns_storage:delete(zones, Name).

%% @doc Add a record to a particular zone.
-spec add_record(binary(), #dns_rr{}, boolean()) -> ok | {error, term()}.
add_record(ZoneName, #dns_rr{} = Record, SendNotify) ->
    {ok, #zone{allow_notify = AllowNotify, allow_transfer = AllowTransfer, allow_update = AllowUpdate,
               also_notify = AlsoNotify, notify_source = NotifySource, version = Version, records = Records0,
               authority = [#dns_rr{data = #dns_rrdata_soa{serial = Serial} = SOA0}] = [Authority]}}
        = get_zone_with_records(normalize_name(ZoneName)),
    %% Ensure no exact duplicates are found
    [true = Record =/= X || X <- Records0],
    %% Update serial number
    NewAuth = Authority#dns_rr{data = SOA0#dns_rrdata_soa{serial = Serial + 1}},
    Zone = build_zone(ZoneName, AllowNotify, AllowTransfer, AllowUpdate, AlsoNotify, NotifySource,
                      Version, [NewAuth], remove_old_soa_add_new([Record | Records0], NewAuth)),
    %% Put zone back into cache. And send notify if needed.
    ok = delete_zone(ZoneName),
    case SendNotify of
        false ->
            ok = put_zone(ZoneName, Zone);
        true ->
            ok = put_zone(ZoneName, Zone),
            send_notify(ZoneName, Zone)
    end.

%% @doc Delete a record from a particular zone.
-spec delete_record(binary(), #dns_rr{}, boolean()) -> ok | {error, term()}.
delete_record(ZoneName, #dns_rr{} = Record, SendNotify) ->
    {ok, #zone{allow_notify = AllowNotify, allow_transfer = AllowTransfer, allow_update = AllowUpdate,
               also_notify = AlsoNotify, notify_source = NotifySource, version = Version, records = Records0,
               authority = [#dns_rr{data = #dns_rrdata_soa{serial = Serial} = SOA0}] = [Authority]}}
        = get_zone_with_records(normalize_name(ZoneName)),
    Records = lists:delete(Record, Records0),
    %% Update serial number
    NewAuth = Authority#dns_rr{data = SOA0#dns_rrdata_soa{serial = Serial + 1}},
    Zone = build_zone(ZoneName, AllowNotify, AllowTransfer, AllowUpdate, AlsoNotify, NotifySource,
                      Version, [NewAuth], remove_old_soa_add_new(Records, NewAuth)),
    %% Put zone back into cache.
    ok = delete_zone(ZoneName),
    case SendNotify of
        false ->
            ok = put_zone(ZoneName, Zone);
        true ->
            ok = put_zone(ZoneName, Zone),
            send_notify(ZoneName, Zone)
    end.

%% @doc Update a record in a zone.
-spec update_record(binary(), #dns_rr{}, #dns_rr{}, boolean()) -> ok | {error, term()}.
update_record(ZoneName, #dns_rr{} = OldRecord, #dns_rr{} = UpdatedRecord, SendNotify) ->
    {ok, #zone{allow_notify = AllowNotify, allow_transfer = AllowTransfer, allow_update = AllowUpdate,
               also_notify = AlsoNotify, notify_source = NotifySource, version = Version, records = Records0,
               authority = [#dns_rr{data = #dns_rrdata_soa{serial = Serial} = SOA0}] = [Authority]}}
        = get_zone_with_records(normalize_name(ZoneName)),
    Records = [UpdatedRecord | lists:delete(OldRecord, Records0)],
    %% Update serial number
    NewAuth = Authority#dns_rr{data = SOA0#dns_rrdata_soa{serial = Serial + 1}},
    Zone = build_zone(ZoneName, AllowNotify, AllowTransfer,AllowUpdate, AlsoNotify, NotifySource,
                      Version, [NewAuth], remove_old_soa_add_new(Records, NewAuth)),
    %% Put zone back into cache.
    ok = delete_zone(ZoneName),
    case SendNotify of
        false ->
            ok = put_zone(ZoneName, Zone);
        true ->
            ok = put_zone(ZoneName, Zone),
            send_notify(ZoneName, Zone)
    end.

%% -----------------------------------------------------------------------------------------------
%% Gen server init

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

%% -----------------------------------------------------------------------------------------------
%% gen_server callbacks

%% @doc Write the zone into the cache.
handle_call({put, Name, Zone}, _From, State) ->
    erldns_storage:insert(zones, {normalize_name(Name), Zone}),
    {reply, ok, State};
handle_call({put, Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
             NotifySourceIP}, _From, State) ->
    erldns_storage:insert(zones,
                          {normalize_name(Name), build_zone(Name, AllowNotifyList, AllowTransferList,
                                                            AllowUpdateList, AlsoNotifyList,
                                                            NotifySourceIP, Sha, Records)}),
    {reply, ok, State}.

handle_cast({put, Name, Zone}, State) ->
    erldns_storage:insert(zones, {normalize_name(Name), Zone}),
    {noreply, State};
handle_cast({put, Name, Sha, Records, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
             NotifySourceIP}, State) ->
    erldns_storage:insert(zones,
                          {normalize_name(Name), build_zone(Name, AllowNotifyList, AllowTransferList,
                                                            AllowUpdateList, AlsoNotifyList,
                                                            NotifySourceIP, Sha, Records)}),
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


%% Internal API
%% @doc Removes the expiration timestamp from the list of dns_rrs stored in the dict.
-spec remove_expiry([{non_neg_integer(), dns:rr()}] | []) -> [] | [dns:rr()].
remove_expiry([]) ->
    [];
remove_expiry(RecordSet) ->
    remove_expiry(RecordSet, []).

remove_expiry([], Acc) ->
    Acc;
remove_expiry([{_Expiry, Record} | Tail], Acc) ->
    remove_expiry(Tail, [Record | Acc]).

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
        [] -> {error, {zone_not_found, Name}};
        [_] -> {error, {zone_not_found, Name}};
        [_|Labels] ->
            case erldns_storage:select(zones, Name) of
                [{Name, Zone}] -> {ok, Zone};
                _ -> find_zone_in_cache(dns:labels_to_dname(Labels))
            end
    end.

build_zone(#zone{records = Records} = Zone) ->
    Zone#zone{authority = lists:filter(erldns_records:match_type(?DNS_TYPE_SOA), Records),
              records = Records,
              records_by_name = build_named_index(Records)}.

build_zone(Qname, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
           NotifySourceIP, Version, Records) ->
    Authority = lists:filter(erldns_records:match_type(?DNS_TYPE_SOA), Records),
    #zone{name = Qname, allow_notify = AllowNotifyList, allow_transfer = AllowTransferList,
          allow_update = AllowUpdateList, also_notify = AlsoNotifyList,
          notify_source = NotifySourceIP, version = Version, record_count = length(Records),
          authority = Authority, records = Records,
          records_by_name = build_named_index(Records)}.

build_zone(Qname, AllowNotifyList, AllowTransferList, AllowUpdateList, AlsoNotifyList,
           NotifySourceIP, Version, [#dns_rr{name = AuthName} = Authority], Records) ->
    #zone{name = Qname, allow_notify = AllowNotifyList, allow_transfer = AllowTransferList,
          allow_update = AllowUpdateList, also_notify = AlsoNotifyList, notify_source = NotifySourceIP,
          version = Version, record_count = length(Records),
          authority = [Authority#dns_rr{name = normalize_name(AuthName)}], records = Records,
          records_by_name = build_named_index(Records)}.

build_named_index(Records) -> build_named_index(Records, dict:new()).
build_named_index([], Idx) -> Idx;
build_named_index([#dns_rr{name = Name, ttl = TTL} = R|Rest], Idx) ->
    Expiry = timestamp() + TTL,
    case dict:find(Name, Idx) of
        {ok, Records} ->
            build_named_index(Rest, dict:store(normalize_name(Name), Records ++ [{Expiry, R}], Idx));
        error ->
            build_named_index(Rest, dict:store(normalize_name(Name), [{Expiry, R}], Idx))
    end.

normalize_name(Name) when is_list(Name) -> bin_to_lower(list_to_binary(Name));
normalize_name(Name) when is_binary(Name) -> bin_to_lower(Name).

%% @doc This function takes a list of records and normalizes the name. This ensures that the record
%% being looked up is found.
%% @end
-spec normalize_records([dns:rr()]) -> [dns:rr()].
normalize_records(Records) ->
    normalize_records(Records, []).

normalize_records([], Acc) ->
    Acc;
normalize_records([#dns_rr{name = Name} = H | Tail], Acc) ->
    normalize_records(Tail, [H#dns_rr{name = normalize_name(Name)} | Acc]).

%% @doc Takes a binary messages, and transforms it to lower case. Self said!
-spec bin_to_lower(Bin :: binary()) -> binary().
bin_to_lower(Bin) ->
    bin_to_lower(Bin, <<>>).

bin_to_lower(<<>>, Acc) ->
    Acc;
bin_to_lower(<<H, T/binary>>, Acc) when H >= $A, H =< $Z ->
    H2 = H + 32,
    bin_to_lower(T, <<Acc/binary, H2>>);
bin_to_lower(<<H, T/binary>>, Acc) ->
    bin_to_lower(T, <<Acc/binary, H>>).

%% @doc This function sends the NOTIFY message to all slaves of the zone.
-spec send_notify(binary(), #zone{}) -> [ok].
send_notify(ZoneName, #zone{notify_source = NotifySource, records = Records}) ->
    %% Now send the notify message out to the set of IPs
    BindIP = case NotifySource of
                 <<>> ->
                     {127, 0, 0, 1};
                 IP ->
                     IP
             end,
    lists:foldl(fun(IP, Acc) ->
                        [gen_server:cast(erldns_manager, {send_notify, {BindIP, IP,
                                                                        ZoneName, ?DNS_CLASS_IN}}) | Acc]
                end, [], get_ips_for_notify_set(Records)).

%% @doc This function takes the zones's list of records and returns a list of nameservers to
%% notify for a zone. Returned list excludes the mname that is specified in the authority.
%% @end
-spec get_notify_set([dns:rr()]) -> [dns:rr()].
get_notify_set(Records) ->
    get_notify_set(Records, [], []).

get_notify_set([], SOA, NameServers) ->
    %% Remove mnames, and duplicates from final result
    exclude_mname_duplicates(SOA, NameServers);
get_notify_set([#dns_rr{data = Data} | Tail], SOA, NameServers) ->
    case Data of
        #dns_rrdata_soa{}  = Authority ->
            get_notify_set(Tail, Authority, NameServers);
        #dns_rrdata_ns{} = NS ->
            get_notify_set(Tail, SOA, [NS | NameServers]);
        _ ->
            get_notify_set(Tail, SOA, NameServers)
    end.

%% @doc Takes an SOA, and a list of nameservers and returns a list of nameservers that are not
%% include in the SOA's mname field.
%% @end
-spec exclude_mname_duplicates(dns:rr(), [dns:rr()]) -> [dns:rr()].
exclude_mname_duplicates(#dns_rrdata_soa{mname = MName}, NameServers) ->
    [NameServer || #dns_rrdata_ns{dname = DName} = NameServer <- NameServers, DName =/= MName].

%% @doc This function takes a list of records, finds it's A/AAAA record in the given record set
%% and returns the nameserver's IP address.
%% @end
-spec get_ips_for_notify_set([dns:rr()] | binary()) -> [inet:ip_address()] | [].
get_ips_for_notify_set(ZoneName) when is_binary(ZoneName) ->
    case get_zone_with_records(ZoneName) of
        {ok, #zone{records = Records}} ->
            get_ips_for_notify_set(Records);
        _ ->
            []
    end;
get_ips_for_notify_set(NameServers) ->
    get_ips_for_notify_set(NameServers, get_notify_set(NameServers), []).

get_ips_for_notify_set(_NameServers, [], IPs) ->
    IPs;
get_ips_for_notify_set(NameServers, [#dns_rrdata_ns{dname = DName} | Tail] = NSRecords, IPs) ->
    case lists:keyfind(DName, #dns_rr.name, NameServers) of
        false ->
            get_ips_for_notify_set(NameServers, Tail, IPs);
        #dns_rr{data = ARecord} = DNSRR  ->
            case ARecord of
                #dns_rrdata_a{ip = IP} ->
                    get_ips_for_notify_set(lists:delete(DNSRR, NameServers), NSRecords, [IP | IPs]);
                #dns_rrdata_aaaa{ip = IP} ->
                    get_ips_for_notify_set(lists:delete(DNSRR, NameServers), NSRecords, [IP | IPs])
            end
    end.

%% @doc This function takes a list of records and an authority records. Removes old authority in the
%% record list and adds the new authority. Returns the new record list
%% @end
-spec remove_old_soa_add_new([dns:rr()], dns:rr()) -> [dns:rr()].
remove_old_soa_add_new(Records, NewAuthority) ->
    remove_old_soa_add_new(NewAuthority, Records,  []).

remove_old_soa_add_new(_NewAuthority, [],  NewRecords) ->
    NewRecords;
remove_old_soa_add_new(NewAuthority, [#dns_rr{data = Data} = Record | Records], NewRecords) ->
    case Data of
        #dns_rrdata_soa{} ->
            remove_old_soa_add_new(NewAuthority, Records, [NewAuthority | NewRecords]);
        _ ->
            remove_old_soa_add_new(NewAuthority, Records, [Record | NewRecords])
    end.

timestamp() ->
    {TM, TS, _} = os:timestamp(),
    (TM * 1000000) + TS.
