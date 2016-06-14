module Scan;  

export {
	global check_scan_cache: function (c: connection, established: bool, reverse: bool, validator: string) ;
	#global add_to_known_scanners:function (orig: addr, detect: string);


	global Scan::m_w_add_scanner: event (ss: scan_info) ; 
	global Scan::w_m_new_scanner: event (ci: conn_info, established: bool, reverse: bool, validator: string); 
	global Scan::m_w_update_scanner: event (ip: addr, status_flag: bool ); 
	global Scan::w_m_update_scanner: event(ss: scan_info); 

	global run_scan_detection: function(ci: conn_info, established: bool, reverse: bool, validator: string ): bool  ; 
} 

@if ( Cluster::is_enabled() )
@load base/frameworks/cluster
redef Cluster::manager2worker_events += /Scan::m_w_(add|remove|update)_scanner/;
redef Cluster::worker2manager_events += /Scan::w_m_(new|add|remove|update)_scanner/;
@endif


## Final function which calls various scan-detection heuristics, if activated 
## as specificed in scan-user-config.bro 
##
## ci: conn_info  - contains conn_id + first seen timestamp for the connection
## established: bool - if connection was established or not 
## reverse: bool - if initial sy/ack was seen from the dst without a syn from orig 
## validator: string  - consist of K(knockknock), L(LandMine), B(BackScatter), A(AddressScan) 
## if any of the above validation is true then based on validator string - that specific heuristic will
## be applied to the connection 
##
## Returns: bool - returns T or F depending if IP is a scanner
function Scan::run_scan_detection(ci: conn_info, established: bool, reverse: bool, validator: string ): bool 
{

	if (gather_statistics)
       	{
       		s_counters$run_scan_detection += 1;
       	}

	local cid=ci$cid ; 
	local orig=ci$cid$orig_h; 

	local result = F ; 

	if (!result && Scan::activate_KnockKnockScan && /K/ in validator && check_KnockKnockScan(cid, established, reverse)) 
	{ 

		Scan::add_to_known_scanners(orig, "KnockKnockScan"); 
		result = T; 
	} 

	if (!result && Scan::activate_BackscatterSeen &&  /B/ in validator && Scan::check_BackscatterSeen(cid, established, reverse))
	{
		#log_reporter (fmt("run_scan_detection: check_BackscatterSeen %s, %s", ci, validator),0); 
		Scan::add_to_known_scanners(orig, "BackscatterSeen");	
		result = T; 
	} 

	if (!result && activate_LandMine && /L/ in validator && check_LandMine(cid, established, reverse))
	{
		Scan::add_to_known_scanners(orig, "LandMine"); 
		result = T; 
	} 
	
	if (!result && activate_AddressScan && /A/ in validator && check_AddressScan(cid, established, reverse)) 
	{
		Scan::add_to_known_scanners(orig, "AddressScan");
		result = T; 
	} 

	if (!result && activate_LowPortTrolling && /T/ in validator && check_LowPortTroll(cid, established, reverse)) 
	{
		Scan::add_to_known_scanners(orig, "LowPortTrolling");
		result = T; 
	} 


	if (result)
	{ 
		Scan::hot_subnet_check(orig); 
	} 
	

#	if (activate_PortScan && /P/ in validator && check_PortScan(cid, established, reverse)) 
#	{
#		return result = T; 
#	} 

	#log_reporter (fmt("run_scan_detection: result is %s, %s, %s", result, cid, validator),0); 

	return result ;
}

####### clusterizations

#### main function to start sending data from worker to manager
### where manager will determine if scanner or not based on values
### collected from all the workers


function populate_table_start_ts(ci: conn_info)
{
	local orig=ci$cid$orig_h ; 

        if (orig !in table_start_ts)
        {
                local st: start_ts ;
                table_start_ts[orig] = st ;
                table_start_ts[orig]$ts = ci$ts ;
        }

        table_start_ts[orig]$conn_count += 1 ;

        ### gather the smallest timestamp for that IP
        ### different workers see different ts
        if (table_start_ts[orig]$ts > ci$ts)
                table_start_ts[orig]$ts  = ci$ts ;
} 


## Entry point from check-scan function - this function dispatches connection to manager if cluster is enabled 
## or calls run_scan_detection for standalone instances
## c: connection record
## established: bool - if connection is established 
## reverse: bool - 
## validator: string - comprises of K,L,A,B depending on which one of the validation was successful
function check_scan_cache(c: connection, established: bool, reverse: bool, validator: string )
{

	if (gather_statistics)
	{
       		s_counters$check_scan_cache += 1;
	}

        local orig = c$id$orig_h ;
        local resp = c$id$resp_h;
	
	local ci: conn_info ;
	
	ci$cid = c$id ; 
	ci$ts = c$start_time; 

	### too expensive log_reporter(fmt("check_scan_cache: %s, validator is : %s", c$id, validator),0); 

        #already identified as scanner no need to proceed further
        if (orig in Scan::known_scanners && Scan::known_scanners[orig]$status)
	{ 
       		s_counters$check_scan_counter += 1;
		log_reporter(fmt("inside check_scan_cache: known_scanners[%s], %s", orig, known_scanners[orig]),0); 
                return;
	} 

	#### we run knockknockport local on each worker since portscan is too expensive 
	#### in term of traffic between nodes and its not worth this conjestion 
	

        ### if standalone then we check on bro node else we deligate manager to handle this
        @if ( Cluster::is_enabled() )
                event Scan::w_m_new_scanner(ci, established, reverse, validator);
        @else
		populate_table_start_ts(ci); 
		run_scan_detection (ci, established, reverse, validator) ;
        @endif

}


## Event runs on manager in cluster setup. All the workers run check_scan_cache locally and 
## dispatch conn_info to manager which aggregates the connections of a source IP and 
## calls heuristics for scan-dection 
## ci: conn_info - conn_id + timestamp 
## established: bool - if connect was established 
## reverse: bool 
## validator: string - comprises of K,L,A,B depending on which one of the validation was successful 
@if ( Cluster::is_enabled() && Cluster::local_node_type() == Cluster::MANAGER )
event Scan::w_m_new_scanner(ci: conn_info, established: bool, reverse: bool, validator: string )
{

	if (gather_statistics)
       	{
       		s_counters$worker_to_manager_counter += 1;
	}
	
	#### log_reporter(fmt("A in inside w_m_new_scanner: %s, %s", ci, validator),0); 

	local orig = ci$cid$orig_h ; 

	if (orig in Scan::known_scanners && Scan::known_scanners[orig]$status)
		return ; 

	populate_table_start_ts(ci); 

       	local result = Scan::run_scan_detection(ci, established, reverse, validator) ; 

	### if successful notify all workers of scanner 
	### so that they stop reporting further 
		
        if (result)
        {



		# check for conn_history - that is if we ever saw a full SF going to this IP
		if (History::check_conn_history(orig)) 
		{
			log_reporter(fmt("check_conn_histry = T in w_m_knockscan_new: %s", known_scanners[orig]),0);
		}

		# if successful scanner, dispatch it to all workers 
		# this is needed to keep known_scanners table syncd on all workers 

		event Scan::m_w_add_scanner(known_scanners[orig]); 
        }
}
@endif


### update workers with new scanner info
@if ( Cluster::is_enabled() && Cluster::local_node_type() != Cluster::MANAGER )
event Scan::m_w_add_scanner (ss: scan_info) 
{
	#### log_reporter(fmt ("check-scan-impl: m_w_add_scanner: %s", ss$scanner), 0);

	local orig = ss$scanner; 
	local detection = ss$detection ; 
        Scan::add_to_known_scanners(orig, detection );
	
}
@endif

## in the event when catch-n-release releases an IP - we change the known_scanners[ip]$status = F 
## so that workers again start sending conn_info to manager to reflag as scanner. 
@if ( Cluster::is_enabled() && Cluster::local_node_type() == Cluster::MANAGER )
event Scan::w_m_update_scanner(ss: scan_info) 
{

	log_reporter(fmt ("check-scan-impl: w_m_update_scanner: %s, %s", ss$scanner, ss$detection), 0);
	if ( ss$scanner !in Scan::known_scanners) 
	{ 
		Scan::add_to_known_scanners(ss$scanner, ss$detection); 
	} 

	### now that Manager added the worker reported portscan to its known_scanner
	#### manager needs to inform other workers of this new scanner 

	event Scan::m_w_add_scanner(ss); 
} 
@endif 


## populates known_scanners table and if scan_summary is enabled then 
## handles initialization of scan_summary table as well. 
## also logs first Detection entry in scan_summary 
## orig: addr - IP address of scanner 
## detect: string - what kind of scan was it - knock, address, landmine, backscatter 
function Scan::add_to_known_scanners(orig: addr, detect: string)
{
	#### log_reporter(fmt("function Scan::add_to_known_scanners: %s, %s", orig, detect),0); 

	local new = F ; 
        if (orig !in Scan::known_scanners)
        {
                local si: scan_info;
                Scan::known_scanners[orig] = si ;
		new = T ; 
        }
                Scan::known_scanners[orig]$scanner=orig;
                Scan::known_scanners[orig]$status = T ;
                Scan::known_scanners[orig]$detection = detect ;
		Scan::known_scanners[orig]$detect_ts = network_time(); 
                Scan::known_scanners[orig]$event_peer = fmt ("%s", peer_description);
        
		#### log_reporter(fmt("add_to_known_scanners: known_scanners[orig]: DETECT: %s, %s, %s, %s, %s", detect, orig, Scan::known_scanners [orig], network_time(), current_time()),0);


	###populate scan_summary 
	if (enable_scan_summary)
	{
		if (orig !in Scan::scan_summary)
		{
                local ss: scan_stats;
                #local hh : set[addr];
                Scan::scan_summary[orig] = ss ;
                #Scan::scan_summary[orig]$hosts=hh ;
		}  

                Scan::scan_summary[orig]$scanner=orig;
                Scan::scan_summary[orig]$status = T ;
                Scan::scan_summary[orig]$detection = detect ;
                Scan::scan_summary[orig]$detect_ts = network_time();
                Scan::scan_summary[orig]$event_peer = fmt ("%s", peer_description);

@if (( Cluster::is_enabled() && Cluster::local_node_type() == Cluster::MANAGER )|| (! Cluster::is_enabled()))
		if (new)
		{ 
			log_scan_summary(known_scanners[orig], DETECT) ; 
		} 
@endif 

	}  # if enable_scan_summary 


}

