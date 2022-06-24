#!/bin/bash

me=${0##*/}

STATEDIR=/var/run/set_mongo_balancer_state
LOCKDIR=/var/lock/set_mongo_balancer_state
LOCKFILE="${LOCKDIR}/set_mongo_balancer_state.lock"

ECHO="echo -e"

function msg {
    msg="$1"
    [ -n "${msg}" ] && msg="INFO $(date) ${msg}"
    ${ECHO} "${msg}"

    return 0
}

function warn {
    ${ECHO} "WARNING $1"

    return 0
}

function err {
    ${ECHO} "ERROR: $1" >&2
    ((rc=rc+1))

    return 0
}

function die {
    err "$2"
    ((errors++))

    exit $1
}

function runCommand {
    typeset cmd="$1"

    if [ "${verbose}" -gt 0 -o -n "${dryrun}" ]; then
        [ -n "${dryrun}" ] && msg "would have run: ${cmd}" || msg "running: ${cmd}"
    fi
    [ -n "${dryrun}" ] || eval "${cmd}" || return 1

    return 0
}

# Checks if another instance is active
function checkLockfile {
  if [ -r ${LOCKFILE} ] ; then
    # Extract the Process ID from the lockfile
    pid=$(cat ${LOCKFILE})
    # Check if process is still active
    ps -p ${pid} >/dev/null && return 1
  fi

  return 0
}

# Write our PID to the lockfile
function writeLockfile {
  echo $$ > ${LOCKFILE} || return 1
  lockFileWritten=1

  return 0
}

function cleanup {
    [ -n "${lockFileWritten}" ] && rm -f ${LOCKFILE}

}

function Usage {
    ${ECHO} "Usage: ${me} [-q] [-v] [-n] -h host -p port -o operation\n\t-o stop (save current state and stop balancer if running)\n\t-o conditional-start (start balancer if saved state is started)\n\t-o st
atus (display the balancer status)\n\t-q\tquiet\n\t-v\tincrease verbosity\n\t-n\tdry run" >&2
    exit 1
}

function init {
    lockFileWritten=""
    dryrun=""
    verbose=1
    errors=0
    operation=""
    host=""
    port=""

    if ! checkLockfile; then
        die 1 "Already active"
    fi

    [ -d "${LOCKDIR}" ]  || mkdir -p "${LOCKDIR}" || die 1 "Failed to create lock directory ${LOCKDIR}"
    writeLockfile || die 1 "Can't write lock file"
    trap cleanup EXIT

    case ${me} in
        start*)
            action=stop;
            ;;
    esac

    [ -d "${statedir}" ] || mkdir -p "${STATEDIR}" || die 1 "Failed to create state directory ${STATEDIR}"

    while getopts ":qvnh:p:o:" opt; do
        case ${opt} in
            h)
                host=${OPTARG}
                ;;
            p)
                port=${OPTARG}
                ;;
            o)
                operation=${OPTARG}
                ;;
            n)
                dryrun=1
                ;;
            v)
                ((verbose++))
                ;;
            q)
                verbose=0
                ;;
            \?)
                Usage
                ;;
        esac
    done

    [ -n "${operation}" -a -n "${host}" -a -n "${port}" ] || Usage
}

function getClusterID {
    typeset _o

    _o=$(echo "db.printShardingStatus()" | mongo --host ${host} --port ${port}) && [ -n "${_o}" ] || die 1 "Failed to retrieve sharding status"
    clusterID=$(echo "${_o}" | awk -F\" '/clusterId/ { print $4 }') && [ -n "${clusterID}" ] || die 1 "Failed to extract cluster ID from sharding status output. Got this ${_o}"
}

function getState {
    state=$(echo "sh.getBalancerState()" | mongo --host ${host} --port ${port} --quiet) && [ -n "${state}" ] || die 1 "Failed to determine balancer state"
}

function saveState {
    echo ${state} > ${STATEDIR}/${clusterID}.state || die 1 "Failed to save state to ${STATEDIR}/${clusterID}.state"
}

function getSavedState {
    savedState=""

    [ -r "${STATEDIR}/${clusterID}.state" ] || { msg "Cannot find saved state for cluster ${clusterID}"; return; }

    read savedState < "${STATEDIR}/${clusterID}.state" || die 1 "Failed to read saved state from ${STATEDIR}/${clusterID}.state"
}

function stopBalancer {
    msg "Stopping balancer on cluster ${clusterID}, via mongos on ${host}:${port}"
    echo "sh.stopBalancer()" | mongo --host ${host} --port ${port} --quiet || die 1 "Failed to determine balancer state"
    getState
    [ "${state}" = "false" ] || die 1 "Balancer state is not \"false\"."
    msg "Stopped balancer on cluster ${clusterID}, via mongos on ${host}:${port}"
}

function startBalancer {
    msg "Starting balancer in cluster ${clusterID}, via mongos on ${host}:${port}."
    echo "sh.setBalancerState(1)" | mongo --host ${host} --port ${port} --quiet || die 1 "Failed to start balancer in cluster ${clusterID}"
    msg "Started balancer in cluster ${clusterID}, via mongos on ${host}:${port}."

}

# Main
init "$@"
getClusterID

case ${operation} in
    stop)
        getState
        [ "${state}" = true ] || { msg "Balancer state is not \"true\"; not stopping balancer in cluster ${clusterID}."; exit 0; }
        saveState
        stopBalancer
        ;;
    conditional-start)
        getSavedState
        [ "${savedState}" = "true" ] || { msg "Saved state is not \"true\"; not starting balancer in cluster ${clusterID}."; exit 0; }
        startBalancer
        ;;
    status)
        getState
        echo "Balancer state in cluster ${clusterID} is ${state}."
        ;;
esac