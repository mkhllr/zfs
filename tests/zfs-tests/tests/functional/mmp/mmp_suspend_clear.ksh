#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# DESCRIPTION:
#	'zpool clear' resumes a pool that MMP suspended when no other host
#	has written to it.  MMP rewrites the last synced uberblock with a
#	newer timestamp, so the best uberblock on disk is usually one of
#	this host's own MMP writes, and that must not be taken for another
#	host.
#
# STRATEGY:
#	1. Create a multihost pool and let MMP write for a few seconds.
#	2. Wait for a txg to sync, then two seconds more, so that MMP writes
#	   an uberblock in a later second than the last sync.
#	3. Delay the uberblock writes until MMP suspends the pool.
#	4. Remove the delays and verify that 'zpool clear' resumes the pool.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/mmp/mmp.cfg
. $STF_SUITE/tests/functional/mmp/mmp.kshlib

verify_runnable "both"

function cleanup
{
	zinject -c all
	#
	# Destroying a suspended pool blocks, so if the clear failed leave
	# the pool behind rather than block here.
	#
	if poolexists $MMP_POOL && \
	    [[ $(kstat_pool $MMP_POOL state) == "SUSPENDED" ]]; then
		log_note "$MMP_POOL is still suspended, not destroying it"
		mmp_clear_hostid
	else
		mmp_pool_destroy $MMP_POOL $MMP_DIR
	fi
	log_must set_tunable64 MULTIHOST_INTERVAL $MMP_INTERVAL_DEFAULT
}

# Last txg the pool has synced, from its txg history.
function last_synced_txg
{
	kstat_pool $MMP_POOL txgs | awk '$3 == "C" {t = $1} END {print t}'
}

log_assert "zpool clear resumes a pool suspended by MMP on this host"
log_onexit cleanup

log_must set_tunable64 MULTIHOST_INTERVAL $MMP_INTERVAL_MIN
mmp_pool_create_simple $MMP_POOL $MMP_DIR
log_must sleep 5

typeset txg=$(last_synced_txg)
typeset -i i=0
while [[ $(last_synced_txg) == "$txg" ]]; do
	(( i++ > 200 )) && log_fail "no txg synced after txg $txg"
	sleep 0.1
done
log_must sleep 2

log_must zinject -D 10000:1 -T write -L uber -d $MMP_DIR/vdev1 $MMP_POOL
log_must zinject -D 10000:1 -T write -L uber -d $MMP_DIR/vdev2 $MMP_POOL

i=0
while [[ $(kstat_pool $MMP_POOL state) != "SUSPENDED" ]]; do
	(( i++ > 60 )) && log_fail "$MMP_POOL was not suspended"
	sleep 1
done
log_note "$MMP_POOL suspended after about $i seconds"

log_must zinject -c all
log_must zpool clear $MMP_POOL
log_must check_state $MMP_POOL "" "ONLINE"
log_must sync_pool $MMP_POOL

log_pass "zpool clear resumes a pool suspended by MMP on this host"
