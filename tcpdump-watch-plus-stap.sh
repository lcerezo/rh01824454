#!/bin/bash

## tcpdump-watch-plus-stap.sh
## Maintainer: Kyle Squizzato - ksquizza@redhat.com
## Maintainer: Dave Wysochanski - dwysocha@redhat.com

## Simple tool to capture tcpdump and run stap until certain log message is matched.

## Fill in each of the variables in the SETUP section then invoke the script and wait
## for the issue to occur, the script will stop on it's own when the $match is seen
## in the $log file.


function copy_nfs_files {
	tar -czvf $1/proc-fs-nfsd.$2.tgz /proc/fs/nfsd/* >/dev/null 2>&1
	tar -czvf $1/proc-fs-nfs.$2.tgz /proc/fs/nfs/* >/dev/null 2>&1
	tar -czvf $1/proc-net-rpc-content.$2.tgz /proc/net/rpc/*/content  >/dev/null 2>&1
	[ -f /proc/self/mountstats ] &&	cp /proc/self/mountstats $1/proc-self-mountstats.$2 >/dev/null 2>&1
	[ -f /proc/net/rpc/nfsd ] && cp /proc/net/rpc/nfsd $1/proc-net-rpc-nfsd.$2 >/dev/null 2>&1
}

## -------- SETUP ---------

if [ $# -lt 3 ]; then
        echo "Usage: `basename $0` caseno nfs-server stap-script"
        exit 1
fi

caseno=$1
nfs_server=$2
stap_script=$3

# File output directory
output_dir=/tmp/nfs-data-$caseno-$$
if [ ! -f $output_dir ]; then
	echo Creating output directory $output_dir
	mkdir -p $output_dir
fi

# File output location
tcpdump_output="$output_dir/tcpdump.pcap"

# Logfile to watch.  Accepts wildcards to watch multiple logfiles at once.
log="./nohup.out"
if [ ! -f $log ]; then
	echo Creating $log
	touch $log
fi

# Message to match from log
match="infinite loop"

# Amount of time in seconds to wait before the tcpdump is stopped following a match
wait="2"

# Systemtap script name and cmdline
stap_cmdline="nohup stap -g -v $stap_script" 

## -------- END SETUP ---------

# NOTE: We could accept a DNS name but then we'd need to convert to IP
if [[ $nfs_server =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "Found valid IP address $nfs_server for NFS server"
else
    	echo "Could not validate $nfs_server as an IP of NFS server"
        echo "Please enter a valid IP of NFS server"
        exit 1
fi

# Check for stap existance
if [ ! -f $stap_script ]; then
	echo Unable to find systemtap script $stap_script
	exit 1
fi

# Capture 'begin' of various NFS files as well as $log
echo Copying various NFS related files to $output_dir with 'begin' suffix
copy_nfs_files $output_dir "begin"

echo Copying $log to $output_dir/$(basename $log).begin
cp $log $output_dir/$(basename $log).begin

# Interface to gather tcpdump, derived based on the IP address of the NFS server
# NOTE: To prevent BZ 972396 we need to specify the interface by interface number
# Check for local interface first
ip_device=$(ip -o a | grep $nfs_server)
if [ $? -eq 0 ]; then
	device=$(echo $ip_device | awk '{ print $2 }')
	echo "Found local device $device for IP $nfs_server"
else
	device=$(ip route get $nfs_server | head -n1 | awk '{print $(NF-2)}')
	echo "Found remote device $device for IP $nfs_server"
fi
interface=$(tcpdump -D | grep -e $device | colrm 3 | sed 's/\.//')
echo "Using tcpdump interface $interface for capture"

# The tcpdump command creates a circular buffer of -W X dump files -C YM in size (in MB).
# The default value is 1 file, 1024M in size, it is recommended to modify the buffer values
# depending on the capture window needed.
tcpdump="tcpdump -s0 -i $interface host $nfs_server -W 1 -C 1024M -w $tcpdump_output -Z root"
echo $tcpdump

$tcpdump &
tcpdump_pid=$!

# Now start the systemtap script
$stap_cmdline &
stap_pid=$!

tail --follow=name -n 1 $log |
while read line
do
        ret=`echo $line | grep "$match"`
        if [[ -n $ret ]]
        then
                sleep $wait
                kill $tcpdump_pid
                kill $stap_pid
                break 1
        fi
done

echo Copying various NFS related files to $output_dir with 'end' suffix
copy_nfs_files $output_dir "end"

echo Copying $log to $output_dir/$(basename $log).end
cp $log $output_dir/$(basename $log).end
echo Copying nohup.out to $output_dir/$stap_script-nohup.out
cp nohup.out $output_dir/$stap_script-nohup.out

if [ -e /bin/gzip ]; then
        echo Gzipping $tcpdump_output
        gzip -f $tcpdump_output
fi

# Now package up all files into one tarball
tar -czvf $output_dir.tgz $output_dir/*

echo "Please upload $output_dir.tgz to Red Hat for analysis."
