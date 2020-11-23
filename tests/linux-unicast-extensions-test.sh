#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

# Self-tests for IPv4 address extensions: the kernel's ability to accept
# certain traditionally unused or unallocated IPv4 addresses. Currently
# the kernel accepts addresses in 0/8 and 240/4 as valid. These tests
# check this for interface assignment, ping, TCP, and forwarding. Must
# be run as root (to manipulate network namespaces and virtual interfaces).

# This is work in progress toward an eventual submission to the Linux
# selftests (in linux/tools/testing/selftests).

# TODO: This uses fast-fork-test, which is a customized adaptation of
#       the functionality of nettest. Ideally, fast-fork-test should
#       be merged into nettest and we should just use that.

result=0

hide_output(){ exec 3>&1 4>&2 >/dev/null 2>/dev/null; }
show_output(){ exec >&3 2>&4; }

show_result(){
if [ $1 -eq 0 ]; then
	printf "TEST: %-60s  [ OK ]\n" "${2}"
else
	printf "TEST: %-60s  [FAIL]\n" "${2}"
	result=1
fi
}

_do_pingtest(){
# Perform a simple set of link tests between a pair of
# IP addresses on a shared (virtual) segment.
# foo --- bar
# Arguments: ip_a ip_b prefix_length test_description
#
# Caller must set up foo-ns and bar-ns namespaces
# containing linked veth devices foo and bar,
# respectively.


ip -n foo-ns address add $1/$3 dev foo || return 1
ip -n foo-ns link set foo up || return 1
ip -n bar-ns address add $2/$3 dev bar || return 1
ip -n bar-ns link set bar up || return 1

ip netns exec foo-ns timeout 2 ping -c 1 $2 || return 1
ip netns exec bar-ns timeout 2 ping -c 1 $1 || return 1

./fast-fork-test foo-ns bar-ns $1 12345 || return 1
# using nettest (for this simple test, it's akin to netcat)
# ip netns exec foo-ns "$NETTEST" -s &
# sleep 0.5
# ip netns exec bar-ns "$NETTEST" -r $1 || return 1

./fast-fork-test bar-ns foo-ns $2 12345 || return 1
# ip netns exec bar-ns "$NETTEST" -s &
# sleep 0.5
# ip netns exec foo-ns "$NETTEST" -r $2 || return 1

wait
return 0
}

_do_route_test(){
# Perform a simple set of gateway tests.
#
# [foo] <---> [foo1]-[bar1] <---> [bar]   /prefix
#  host          gateway          host
#
# Arguments: foo_ip foo1_ip bar1_ip bar_ip prefix_len test_description
# Displays test result and returns success or failue.

# Caller must set up foo-ns, bar-ns, and router-ns
# containing linked veth devices foo-foo1, bar1-bar
# (foo in foo-ns, foo1 and bar1 in router-ns, and
# bar in bar-ns).

ip -n foo-ns address add $1/$5 dev foo || return 1
ip -n foo-ns link set foo up || return 1
ip -n foo-ns route add default via $2 || return 1

ip -n bar-ns address add $4/$5 dev bar || return 1
ip -n bar-ns link set bar up || return 1
ip -n bar-ns route add default via $3 || return 1

ip -n router-ns address add $2/$5 dev foo1 || return 1
ip -n router-ns link set foo1 up || return 1

ip -n router-ns address add $3/$5 dev bar1 || return 1
ip -n router-ns link set bar1 up || return 1

echo 1 | ip netns exec router-ns tee /proc/sys/net/ipv4/ip_forward

ip netns exec foo-ns timeout 2 ping -c 1 $2 || return 1
ip netns exec foo-ns timeout 2 ping -c 1 $4 || return 1
ip netns exec bar-ns timeout 2 ping -c 1 $3 || return 1
ip netns exec bar-ns timeout 2 ping -c 1 $1 || return 1

./fast-fork-test foo-ns bar-ns $1 12345 || return 1
./fast-fork-test bar-ns foo-ns $4 12345 || return 1

wait
return 0
}

pingtest(){
# Sets up veth link and tries to connect over it.
# Arguments: ip_a ip_b prefix_len test_description
hide_output
ip netns add foo-ns
ip netns add bar-ns
ip link add foo netns foo-ns type veth peer name bar netns bar-ns

test_result=0
_do_pingtest "$@" || test_result=1

ip netns pids foo-ns | xargs kill -9
ip netns pids bar-ns | xargs kill -9
ip netns del foo-ns
ip netns del bar-ns
show_output

# inverted tests will expect failure instead of success
[ -n "$expect_failure" ] && test_result=`expr 1 - $test_result`

show_result $test_result "$4"
}


route_test(){
# Sets up a simple gateway and tries to connect through it.
# [foo] <---> [foo1]-[bar1] <---> [bar]   /prefix
# Arguments: foo_ip foo1_ip bar1_ip bar_ip prefix_len test_description
# Returns success or failure.

hide_output
ip netns add foo-ns
ip netns add bar-ns
ip netns add router-ns
ip link add foo netns foo-ns type veth peer name foo1 netns router-ns
ip link add bar netns bar-ns type veth peer name bar1 netns router-ns

test_result=0
_do_route_test "$@" || test_result=1

ip netns pids foo-ns | xargs kill -9
ip netns pids bar-ns | xargs kill -9
ip netns pids router-ns | xargs kill -9
ip netns del foo-ns
ip netns del bar-ns
ip netns del router-ns

show_output

# inverted tests will expect failure instead of success
[ -n "$expect_failure" ] && test_result=`expr 1 - $test_result`
show_result $test_result "$6"
}

# Test support for 240/4
pingtest 240.1.2.1   240.1.2.4    24 "assign and ping within 240/4 (1 of 2)"
pingtest 250.100.2.1 250.100.30.4 16 "assign and ping within 240/4 (2 of 2)"

# Test support for 0/8
pingtest 0.1.2.17    0.1.2.23  24 "assign and ping within 0/8 (1 of 2)"
pingtest 0.77.240.17 0.77.2.23 16 "assign and ping within 0/8 (2 of 2)"

# Even 255.255/16 is OK!
pingtest 255.255.3.1 255.255.50.77 16 "assign and ping inside 255.255/16"

# Or 255.255.255/24
pingtest 255.255.255.1 255.255.255.254 24 "assign and ping inside 255.255.255/24"

# Routing between different networks
route_test 240.5.6.7 240.5.6.1  255.1.2.1    255.1.2.3      24 "route between 240.5.6/24 and 255.1.2/24"
route_test 0.200.6.7 0.200.38.1 245.99.101.1 245.99.200.111 16 "route between 0.200/16 and 245.99/16"

# ==============================================
# ==== TESTS THAT CURRENTLY EXPECT FAILURE =====
# ==============================================
expect_failure=true
# It should still not be possible to use 0.0.0.0 or 255.255.255.255
# as a unicast address.  Thus, these tests expect failure.
pingtest 0.0.1.5       0.0.0.0         16 "assigning 0.0.0.0 (is forbidden)"
pingtest 255.255.255.1 255.255.255.255 16 "assigning 255.255.255.255 (is forbidden)"
# Test support for not having all of 127 be loopback
# Currently Linux does not allow this, so this should fail too
pingtest 127.99.4.5 127.99.4.6 16 "assign and ping inside 127/8 (is forbidden)"
# Test support for zeroth host
# Currently Linux does not allow this, so this should fail too
pingtest 5.10.15.20 5.10.15.0 24 "assign and ping zeroth host (is forbidden)"
# Routing using zeroth host as a gateway/endpoint
# Currently Linux does not allow this, so this should fail too
route_test 192.168.42.1 192.168.42.0 9.8.7.6 9.8.7.0 24 "routing using zeroth host (is forbidden)"

# Test support for unicast use of class D
# Currently Linux does not allow this, so this should fail too
pingtest 225.1.2.3 225.1.2.200 24 "assign and ping class D address (is forbidden)"
# Routing using class D as a gateway
route_test 225.1.42.1 225.1.42.2 9.8.7.6 9.8.7.1 24 "routing using class D (is forbidden)"

# Routing using 127/8
# Currently Linux does not allow this, so this should fail too
route_test 127.99.2.3 127.99.2.4 200.1.2.3 200.1.2.4 24 "routing using 127/8 (is forbidden)"

unset expect_failure
# =====================================================
# ==== END OF TESTS THAT CURRENTLY EXPECT FAILURE =====
# =====================================================

exit ${result}
