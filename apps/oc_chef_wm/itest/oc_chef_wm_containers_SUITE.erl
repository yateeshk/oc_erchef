%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Stephen Delano <stephen@chef.io>
%% @author Tyler Cloke <tyler@chef.io>
%%
%% Copyright 2013-2015 Chef, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(oc_chef_wm_containers_SUITE).

-include_lib("common_test/include/ct.hrl").
-include("../../../include/chef_types.hrl").
-include("../../../include/oc_chef_types.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(context, {reqid :: binary(),
                  otto_connection,
                  darklaunch = undefined}).

-compile([export_all, {parse_transform, lager_transform}]).

-define(ORG_AUTHZ_ID, <<"10000000000000000000000000000000">>).
-define(AUTHZ_ID, <<"00000000000000000000000000000001">>).
-define(CLIENT_NAME, <<"test-client">>).

init_per_suite(LastConfig) ->
    Config = chef_test_db_helper:start_db(LastConfig, "oc_chef_wm_itests"),
    setup_helper:start_server(Config),

    OrganizationRecord = chef_object:new_record(oc_chef_organization,
                                                nil,
                                                ?ORG_AUTHZ_ID,
                                                {[{<<"name">>, <<"org">>},
                                                  {<<"full_name">>, <<"org">>}]}),
    Result2 = chef_db:create(OrganizationRecord,
                   #context{reqid = <<"fake-req-id">>},
                   ?AUTHZ_ID),
    io:format("Organization Create Result ~p~n", [Result2]),

    % get the OrgId from the database that was generated during Org object creation
    % so we can associate the client with the org.
    {ok, OrgObject} = chef_sql:fetch_object(chef_object:fields_for_fetch(OrganizationRecord),
                                element(1, OrganizationRecord),
                                chef_object:find_query(OrganizationRecord),
                                chef_object:record_fields(OrganizationRecord)
                               ),
    OrgId = OrgObject#oc_chef_organization.id,

    %% create the test client
    ClientRecord = chef_object:new_record(chef_client,
                                          OrgId,
                                          ?AUTHZ_ID,
                                          {[{<<"name">>, ?CLIENT_NAME},
                                            {<<"validator">>, true},
                                            {<<"admin">>, true},
                                            {<<"public_key">>, <<"stub-pub">>}]}),
    io:format("ClientRecord ~p~n", [ClientRecord]),
    ok = chef_db:create(ClientRecord,
                        #context{reqid = <<"fake-req-id">>},
                        ?AUTHZ_ID),

    Config.

end_per_suite(Config) ->
    chef_test_suite_helper:stop_server(Config, setup_helper:needed_apps()).

all() ->
    [
     list_when_no_containers,
     list_when_created_containers,
     create_container,
     create_with_bad_name,
     delete_container,
     fetch_non_existant_container,
     fetch_existant_container,
     update_container
    ].

init_per_testcase(_, Config) ->
    delete_all_containers(),
    Config.

delete_all_containers() ->
    Result = case sqerl:adhoc_delete("containers", all) of
        {ok, Count} ->
            Count;
        Error ->
            throw(Error)
    end,
    lager:info("Delete containers: ~p", [Result]),
    ok.

list_when_no_containers(_) ->
    Result = http_list_containers(),
    ?assertMatch({ok, "200", _, _} , Result),
    ok.

list_when_created_containers(_) ->
    Containers = ["foo", "bar"],
    [ http_create_container(Container) || Container <- Containers ],
    {ok, ResponseCode, _, ResponseBody} = http_list_containers(),
    ?assertEqual("200", ResponseCode),
    Ejson = ejson:decode(ResponseBody),
    {ContainerList} = Ejson,
    [ ?assertEqual(true, proplists:is_defined(list_to_binary(Container), ContainerList))
      || Container <- Containers ].

create_container(_) ->
    Result = http_create_container("foo"),
    ?assertMatch({ok, "201", _, _} , Result),
    ok.

create_with_bad_name(_) ->
    Result = http_create_container("name with spaces"),
    ?assertMatch({ok, "400", _, _}, Result),
    ok.

delete_container(_) ->
    http_create_container("foo"),
    Result = http_delete_container("foo"),
    ?assertMatch({ok, "200", _, _} , Result),
    ok.

fetch_non_existant_container(_) ->
    Result = {ok, _, _, ResponseBody} = http_fetch_container("bar"),
    ?assertMatch({ok, "404", _, ResponseBody} , Result),
    ?assertEqual([<<"Cannot load container bar">>], ej:get({"error"}, ejson:decode(ResponseBody))),
    ok.

fetch_existant_container(_) ->
    http_create_container("foo"),
    {ok, ResponseCode, _, ResponseBody} = http_fetch_container("foo"),
    ?assertMatch("200", ResponseCode),
    Ejson = ejson:decode(ResponseBody),
    ?assertEqual(<<"foo">>, ej:get({"containername"}, Ejson)),
    ?assertEqual(<<"foo">>, ej:get({"containerpath"}, Ejson)).

update_container(_) ->
    http_create_container("foo"),
    UpdateJson = {[{<<"containername">>, <<"bar">>},
                   {<<"containerpath">>, <<"foo">>},
                   {<<"extra-data">>, <<"ignored">>}]},
    ?assertMatch({ok, "405", _, _}, http_update_container("foo", UpdateJson)),
    ok.

http_list_containers() ->
    ibrowse:send_req("http://localhost:8000/organizations/org/containers",
                     [{"x-ops-userid", "test-client"},
                      {"accept", "application/json"}],
                     get).

http_fetch_container(Name) ->
    ibrowse:send_req("http://localhost:8000/organizations/org/containers/" ++ Name,
                     [{"x-ops-userid", "test-client"},
                      {"accept", "application/json"}],
                     get).

http_create_container(Name) ->
    ibrowse:send_req("http://localhost:8000/organizations/org/containers",
                     [{"x-ops-userid", "test-client"},
                      {"accept", "application/json"},
                      {"content-type", "application/json"}
                     ],post, ejson:encode({[{<<"containername">>, list_to_binary(Name)}]})
                    ).

http_delete_container(Name) ->
    ibrowse:send_req("http://localhost:8000/organizations/org/containers/" ++ Name,
                     [{"x-ops-userid", "test-client"},
                      {"accept", "application/json"}
                     ], delete).

http_update_container(Name, Ejson) ->
    ibrowse:send_req("http://localhost:8000/organizations/org/containers/" ++ Name,
                     [{"x-ops-userid", "test-client"},
                      {"accept", "application/json"},
                      {"content-type", "application/json"}
                     ], put, ejson:encode(Ejson)).
