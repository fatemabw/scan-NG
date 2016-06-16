### this is the core module which integrates and enables and disables 
### all the scan-detection suite 

module Scan;

export { 
	
global check_scan: function (c: connection, established: bool, reverse: bool); 

#global not_scanner: function (cid: conn_id): bool ; 

} 

global uid_table: table[string] of bool &create_expire=30 sec ;

event bro_init()
{ 
	event table_sizes() ; 
}	

## Checks if a perticular connection is already blocked and managed by netcontrol
## and catch-and-release. If yes, we don't process this connection any-further in the
## scan-detection module
## 
## cid: conn_id - four touple conn record
## 
## Returns: bool - returns T or F depending if IP is managed by :bro:see:`NetControl::get_catch_release_info`  
function is_catch_release_active(cid: conn_id): bool
{
	if (gather_statistics)	
		s_counters$is_catch_release_active += 1; 
	
	local orig = cid$orig_h ; 

@ifdef (NetControl::BlockInfo)
        local bi: NetControl::BlockInfo ;
        bi = NetControl::get_catch_release_info(orig);

	#### log_reporter(fmt("is_catch_release_active: blockinfo is %s, %s", cid, bi),0); 
        ### if record bi is initialized
        if (bi$watch_until != 0.0 ) 
                return  T;

        ### means empty bi
        ### [block_until=<uninitialized>, watch_until=0.0, num_reblocked=0, current_interval=0, current_block_id=]
@endif 

        return F ;
}

## Checks if an IP qualies the criteria of being a NOT scanner 
## 
## cid: connection record 
##
## Returns: bool - T/F depending on various conditions satisfied internally 
function not_scanner(cid: conn_id): bool 
{



	if (is_catch_release_active(cid) )
		return T ; 


	local result = F ; 

	local orig = cid$orig_h ; 
	local orig_p = cid$orig_p ; 
	local resp = cid$resp_h ; 
	local service = cid$resp_p ; 
	local outbound = Site::is_local_addr(orig);

        # whitelist membership checks
        if (orig in Scan::whitelist_ip_table)
                return T ;

        if (orig in Scan::whitelist_subnet_table)
                return T ;

	# ignore scan sources (ex: cloud.lbl.gov)
	if (orig in skip_scan_sources)
	{       return  T ; }

	# Blocked on border router - perma firewalled
	if (orig_p in skip_services )
	{ 	return T ; } 


	if ( service in skip_services &&  ! outbound )
		return T;

	if ( outbound && service in skip_outbound_services )
		return T;

	if ( orig in skip_scan_nets )
		return T;

	# Don't include well known server/ports for scanning purposes.
	if ( ! outbound && [resp, service] in skip_dest_server_ports )
		return T;

	# we only deal with tcp scanners and icmp for now
	if (service >= 0/udp && service <= 65535/udp) 
		return T; 

	return result ; 
} 

## Primary entry point of :bro:see:`Scan::check_scan` modoule 
## It is called by :bro:see:`new_connection`, :bro:see:`connection_state_remove`, :bro:see:`connection_established`
## :bro:see:`connection_attempt`, :bro:see:`connection_rejected`, :bro:see:`partial_connection`, :bro:see:`connection_half_finished`, 
## :bro:see:`connection_reset`, :bro:see:`connection_pending` events
## 
## c: connection_record :see:bro:`connection` 
## 
## established: bool - if a connection between endpoints is established 
##
## reverse: bool - if connection is from setup from destination to source instead 
function check_scan(c: connection, established: bool, reverse: bool)
{

	local orig=c$id$orig_h ; 

	### already a known_scanner 
	if (orig in Scan::known_scanners && Scan::known_scanners[orig]$status) 
	{ 
		if (gather_statistics)
                        s_counters$already_scanner_counter += 1;

		return ; 
	} 

	if (not_scanner(c$id))
	{ 
		if (gather_statistics)
                        s_counters$not_scanner += 1;
		return ; 
	} 

	###log_reporter(fmt ("check_scan: scanner: orig in known_scanners for %s", c$id$orig_h),0);

       	local resp = c$id$resp_h ;

	### if darknet then fast-pace the detection for landmine, knockknoc and
	### backscatter so that we don't ahve to wait till tcp_attempt_delay expiration 
	### of 5 sec 

	local darknet = F ; 

        if (Site::is_local_addr(resp) && resp !in Site::subnet_table)
        {
		darknet = T ; 

	 	if (gather_statistics)
                        s_counters$darknet_counter += 1;

	} 
        ### only watch for live subnets - since conn_state_remove adds
        ### 5.0 sec of latency to tcp_attempt_delay
        ### Unsuccessful is defined as at least tcp_attempt_delay seconds
        ### having elapsed since the originator first sent a connection
        ### establishment packet to the destination without seeing a reply.

	else if (Site::is_local_addr(resp) && resp in Site::subnet_table)
	{ 
	 	if (gather_statistics)
                        s_counters$not_darknet_counter += 1;
		darknet = F ; 
	} 


	local valid__Backscatter = "" ;
	local valid__KnockKnock = "" ;
	local valid__LandMine = "" ;
	local valid__AddressScan = "" ;
	local valid__PortScan = "" ;
	local valid_port_knock = "" ; 
	local valid__LowPortTroll = "" ; 
	
        
	# run validation code on the workers for each scan module 
	# if a connectiond doesn't fit what is eventually one of the criterias of a 
	# detection heuristic, validation for that heuristic is a F 
	# only connections with T validation are processed further to be analyzed 

	if (activate_BackscatterSeen)
	{
		valid__Backscatter = Scan::validate_BackscatterSeen(c, darknet);
	} 

	if (activate_KnockKnockScan)
			valid__KnockKnock = Scan::validate_KnockKnockScan(c, darknet); 
	
	if (activate_LandMine)
			valid__LandMine = Scan::validate_LandMineScan(c, darknet ); 

	if (activate_AddressScan)
		valid__AddressScan = Scan::validate_AddressScan(c, established, reverse); 
	
	if (activate_LowPortTrolling)
		valid__LowPortTroll = Scan::validate_LowPortTroll(c, established, reverse); 


	
	# we hold off on PortScan to use the heuristics provided by sumstats 	
	# if (activate_PortScan)
  	#	valid__PortScan = Scan::validate_PortScan(c, established, reverse) ; 

	
	if (/K/ in valid__KnockKnock || /L/ in valid__LandMine || /B/ in valid__Backscatter  || /A/ in valid__AddressScan || /T/ in valid__LowPortTroll)  
	{ 
		#### So connection met one or more of heuristic validation criterias 
		#### send for further determination into check-scan-impl.bro now 
	
		if (gather_statistics)
			s_counters$validation_success += 1;

		### we maintain a uid_table with create_expire of 30 secs so that same connection processed by one event 
		### is not again sent - for example if C is already processed in scan-engine for new_connection, lets not 
		### process same C for subsiquent TCP events such as conn_terminate or conn_rejected etc. 
		### call conn_state_remove 
		
		if (c$uid !in uid_table)
		{ 
			local validator = fmt("%s%s%s%s%s%s", valid__KnockKnock, valid__LandMine, valid__Backscatter, valid__AddressScan, valid__PortScan,valid__LowPortTroll); 
			uid_table[c$uid]=T ; 
			check_scan_cache(c, established, reverse, validator) ; 
		} 
	} 
} 


### speed up landmine and knockknock for darknet space 
event new_connection(c: connection)
	{
	### for new connections we just want to supply C and only for darknet spaces 
	### to speed up reaction time and to avoind tcp_expire_delays of 5.0 sec  

	if (gather_statistics)
		{ 
		s_counters$event_peer = fmt ("%s", peer_description); 
		s_counters$new_conn_counter += 1; 
		} 

    local tp = get_port_transport_proto(c$id$resp_p);
        
	if (tp == tcp && c$id$orig_h !in Site::local_nets && is_darknet(c$id$resp_h) )
	{
		Scan::check_scan(c, F, F); 
	} 
} 

event connection_state_remove(c: connection)
{
	check_scan(c, F, F); 
}


event connection_established(c: connection)
	{
	local is_reverse_scan = (c$orig$state == TCP_INACTIVE && c$id$resp_p !in likely_server_ports);
	Scan::check_scan(c, T, is_reverse_scan);

	local trans = get_port_transport_proto(c$id$orig_p);
	if ( trans == tcp && ! is_reverse_scan && TRW::use_TRW_algorithm )
	       TRW::check_TRW_scan(c, conn_state(c, trans), F);
	}

event partial_connection(c: connection)
	{
	Scan::check_scan(c, T, F);
	}

event connection_attempt(c: connection)
	{
    local is_reverse_scan = (c$orig$state == TCP_INACTIVE && c$id$resp_p !in likely_server_ports);
	Scan::check_scan(c, F, is_reverse_scan);

	local trans = get_port_transport_proto(c$id$orig_p);
	if ( trans == tcp && TRW::use_TRW_algorithm )
	       TRW::check_TRW_scan(c, conn_state(c, trans), F);
	}

event connection_half_finished(c: connection)
       {
       # Half connections never were "established", so do scan-checking here.
       Scan::check_scan(c, F, F);
       }

event connection_rejected(c: connection)
       {
       local is_reverse_scan = (c$orig$state == TCP_RESET && c$id$resp_p !in likely_server_ports);

       Scan::check_scan(c, F, is_reverse_scan);

       local trans = get_port_transport_proto(c$id$orig_p);
       if ( trans == tcp && TRW::use_TRW_algorithm )
              TRW::check_TRW_scan(c, conn_state(c, trans), is_reverse_scan);
       }

event connection_reset(c: connection)
       {
       if ( c$orig$state == TCP_INACTIVE || c$resp$state == TCP_INACTIVE )
        {
        local is_reverse_scan = (c$orig$state == TCP_INACTIVE && c$id$resp_p !in likely_server_ports);
               # We never heard from one side - that looks like a scan.
               Scan::check_scan(c, c$orig$size + c$resp$size > 0, is_reverse_scan);
        }
       }

event connection_pending(c: connection)
       {
       if ( c$orig$state == TCP_PARTIAL && c$resp$state == TCP_INACTIVE )
               Scan::check_scan(c, F, F);
       }


#### no need of these ############ TRW Events 
#
#
#event connection_established(c: connection)
#{
#	local is_reverse_scan = (c$orig$state == TCP_INACTIVE);
#	local trans = get_port_transport_proto(c$id$orig_p);
#
#	if ( trans == tcp && ! is_reverse_scan && TRW::use_TRW_algorithm )
#		TRW::check_TRW_scan(c, conn_state(c, trans), F);
#}
#
#event connection_attempt(c: connection)
#{
#        local trans = get_port_transport_proto(c$id$orig_p);
#        if ( trans == tcp && TRW::use_TRW_algorithm )
#                TRW::check_TRW_scan(c, conn_state(c, trans), F);
#}
#
#event connection_rejected(c: connection)
#{
#        local is_reverse_scan = c$orig$state == TCP_RESET;
#
#        local trans = get_port_transport_proto(c$id$orig_p);
#        if ( trans == tcp && TRW::use_TRW_algorithm )
#                TRW::check_TRW_scan(c, conn_state(c, trans), is_reverse_scan);
#}
############

