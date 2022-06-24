#!/bin/bash

function usage {
        echo "Usage $0 <number|all>" >&2
        exit 1
}

function init {
        [ $# -ne 1 ] && usage

        targetCPUs=$1

        cpus=/sys/devices/system/cpu/cpu[0-9]*
        set ${cpus}
        numCPUs=$#

        [ "${targetCPUs}" = "all" ] && targetCPUs=${numCPUs}
        ((targetCPUs < 1 || targetCPUs > numCPUs)) && { echo "Invalid number of CPUs ${targetCPUs}. This machine has ${numCPUs} CPUs" >&2; exit 1; }
}

function setCPUState {
        typeset cpu=$1
        typeset targetState=$2
        typeset curState

        if [ ! -e ${cpu}/online ]; then
                [ "${targetState}" = "1" ] && return 0
                return 1
        fi

        read curState < ${cpu}/online || return 1
        [ "${curState}" = "${targetState}" ] && return 0
        echo ${targetState} > ${cpu}/online && return 0 || return 1
}

# Main
init "$@"

# First set all CPUs online
for cpu in ${cpus}; do
        setCPUState ${cpu} 1 || { echo "Failed to set CPUs online" >&2; exit 1; }
done

# Now set some CPUs offline if asked.
ncpu=0
for cpu in ${cpus}; do
        ((++ncpu > targetCPUs)) && setCPUState ${cpu} 0
done

onlineCPUs=0
offlineCPUs=0
for cpu in ${cpus}; do
        [ ! -e ${cpu}/online ] && { ((onlineCPUs++)) ; continue; }
        read curState < ${cpu}/online || return 1
        [ "${curState}" = "1" ] && ((onlineCPUs++)) || ((offlineCPUs++))
done
echo "${onlineCPUs} out of ${numCPUs} CPUs are now online."