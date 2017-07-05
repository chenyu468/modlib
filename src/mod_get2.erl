%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1997-2009. All Rights Reserved.
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
%%
-module(mod_get2).
-compile([{parse_transform, lager_transform}]).
-export([do/1]).
-include("httpd.hrl").

%% do

do(Info) ->
    ?DEBUG("do -> entry",[]),
    case Info#mod.method of
	"GET" ->
	    case proplists:get_value(status, Info#mod.data) of
		%% A status code has been generated!
		{_StatusCode, _PhraseArgs, _Reason} ->
		    {proceed,Info#mod.data};
		%% No status code has been generated!
		undefined ->
		    case proplists:get_value(response, Info#mod.data) of
			%% No response has been generated!
			undefined ->
			    do_get(Info);
			%% A response has been generated or sent!
			_Response ->
			    {proceed,Info#mod.data}
		    end
	    end;
	%% Not a GET method!
	_ ->
	    {proceed,Info#mod.data}
    end.


do_get(Info) ->
    ?DEBUG("do_get -> Request URI: ~p",[Info#mod.request_uri]),
    lager:debug("do_get -> Request URI: ~p",[Info#mod.request_uri]),
    Path = mod_alias:path(Info#mod.data, Info#mod.config_db, 
			  Info#mod.request_uri),
    lager:debug("_55:~n\t~p",[Path]),
    send_response(Info#mod.socket,Info#mod.socket_type, Path, Info).


%% The common case when no range is specified
send_response(_Socket, _SocketType, Path, Info)->
    %% Send the file!
    %% Find the modification date of the file
    case file:open(Path,[raw,binary]) of
	{ok, FileDescriptor} ->
	    {FileInfo, LastModified} = get_modification_date(Path),
	    ?DEBUG("do_get -> FileDescriptor: ~p",[FileDescriptor]),
	    Suffix = httpd_util:suffix(Path),
	    MimeType = httpd_util:lookup_mime_default(Info#mod.config_db,
						      Suffix,"text/plain"),
	    %% FileInfo = file:read_file_info(Path),
	    Size = integer_to_list(FileInfo#file_info.size),
	    case Info#mod.http_version of
		"HTTP/1.1" ->
		    Etag = httpd_util:create_etag(FileInfo),
		    case file_modified(Info, FileInfo, Etag) of
			true ->
			    Headers = [{content_type, MimeType},
				       {etag, Etag},
				       {content_length, Size}|LastModified],
			    send(Info, 200, Headers, FileDescriptor),
			    file:close(FileDescriptor),
			    {proceed,[{response,{already_sent,200,
						 FileInfo#file_info.size}},
				      {mime_type,MimeType}|Info#mod.data]};
			false ->
			    file:close(FileDescriptor),
			    %% TODO: content_type is not necessary here,
			    %% but something upstream is filling in
			    %% "text/plain" automatically and we might as
			    %% get it right here.
			    {proceed,[{response, {response, 
						  [{code,304}, 
						   {content_type, MimeType}], 
						  nobody}}|Info#mod.data]}
		    end;
		%% OTP-4935
		_ ->
		    %% i.e http/1.0 and http/0.9
		    Headers = [{content_type, MimeType},
			       {content_length, Size}|LastModified],
		    send(Info, 200, Headers, FileDescriptor),
		    file:close(FileDescriptor),
		    {proceed,[{response,{already_sent,200,
					 FileInfo#file_info.size}},
			      {mime_type,MimeType}|Info#mod.data]}
		end;
	{error, Reason} ->
	    Status = httpd_file:handle_error(Reason, "open", Info, Path),
	    {proceed,
	     [{status, Status}| Info#mod.data]}
    end.

file_modified(#mod{parsed_header=Headers}, #file_info{mtime=Modified}, Etag) ->
    case lists:keyfind("if-none-match", 1, Headers) of
	{_, Etag} -> false;
	_ ->
	    case lists:keyfind("if-modified-since", 1, Headers) of
		{_, IfModifiedStr} ->
		    case httpd_util:convert_request_date(IfModifiedStr) of
			bad_date -> true;
			IfModified -> Modified > IfModified
		    end;
		_ -> true
	    end
    end.    

%% send

send(#mod{socket = Socket, socket_type = SocketType} = Info,
     StatusCode, Headers, FileDescriptor) ->
    ?DEBUG("send -> send header",[]),
    httpd_response:send_header(Info, StatusCode, Headers),
    send_body(SocketType,Socket,FileDescriptor).


send_body(SocketType,Socket,FileDescriptor) ->
    case file:read(FileDescriptor,?FILE_CHUNK_SIZE) of
	{ok,Binary} ->
	    ?DEBUG("send_body -> send another chunk: ~p",[size(Binary)]),
	    case httpd_socket:deliver(SocketType,Socket,Binary) of
		socket_closed ->
		    ?LOG("send_body -> socket closed while sending",[]),
		    socket_close;
		_ ->
		    send_body(SocketType,Socket,FileDescriptor)
	    end;
	eof ->
	    ?DEBUG("send_body -> done with this file",[]),
	    eof
    end.

get_modification_date(Path)->
    {ok, FileInfo0} = file:read_file_info(Path), 
    LastModified = 
	case catch httpd_util:rfc1123_date(FileInfo0#file_info.mtime) of
	    Date when is_list(Date) -> [{last_modified, Date}];
	    _ -> []
	end,
    {FileInfo0, LastModified}.
