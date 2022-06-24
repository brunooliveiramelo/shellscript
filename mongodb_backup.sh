#!/bin/bash

# For debugging purposes only
#set -x

#########################################################
#########################################################

CONFIG_FILE=/local/etc/mongodb_backup.cfg
MONGODB_CONFIG=/etc/sysconfig/mongod
BACKUP_DIR=/work/data/backup
MONGO_CFG_DIR=/etc/mongodb
LOCKDIR=/var/tmp/mongodb_backup
LOCKFILE="${LOCKDIR}/mongodb_backup.sh.lock"
WEEKDAY_MONGO_DUMP=6
TECTAG="MONGODB_BACKUP"
SUBJECT="The instance couldn't be unlocked in server"
MAILTO="run_nosql@company.com"
ECHO="echo -e"

me=$(basename $0)

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

function Usage {
    ${ECHO} "Usage: ${me} [-q] [-v] [-n]\n\t-b\trun a backup\n\t-s\tstage Mongo dump files for inclusion in TSM backup\n\t-q\tquiet\n\t-v\tincrease verbosity\n\t-n\tdry run" >&2
    exit 1
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
  if [ ! -d ${LOCKDIR} ] ; then
     /usr/bin/mkdir -p ${LOCKDIR}
     /usr/bin/chown mongo_p:epousers ${LOCKDIR}
  fi

  echo $$ > ${LOCKFILE} || return 1
  lockFileWritten=1

  return 0
}

function cleanup {

    [ -n "${lockFileWritten}" ] && rm -f ${LOCKFILE}

    [ -n "${backedUpInstances}" ] && msg "Backed up the following instances: ${backedUpInstances}"
    [ -n "${failedInstances}" ] && err "Failed to backup the following instances: ${failedInstances}"
    if ((errors > 0)) || [ -n "${failedInstances}" ] ; then
        err "${me}: errors occured, please check log files."
        [ -n "${dryrun}" ] || tecerror.sh ${TECTAG} ${TECTAG} "${me}: errors occured, please check log files."
    fi
}

function init {
    dryrun=""
    runBackup=""
    runStage=""
    verbose=1
    errors=0
    lockFileWritten=""

    trap cleanup EXIT

     # Source MongoDB configuration file
    [ -e ${MONGODB_CONFIG} ] || die 1 "Can't find MongoDB configuration file ${MONGODB_CONFIG}"
    . ${MONGODB_CONFIG}
    cd ${MONGODB_LOGDIR}

    if ! checkLockfile; then
        die 1 "Already active"
    fi

    writeLockfile || die 1 "Can't write lock file"

    while getopts ":bsqvn" opt; do
        case ${opt} in
            b)
                runBackup=1
                ;;
            s)
                runStage=1
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

    # Redirect all output to ${MONGODB_LOGDIR}/backup.log
    [ -n "${dryrun}" ] || exec >> ${MONGODB_LOGDIR}/backup.log 2>&1 || die 1 "Failed to log to directory ${MONGODB_LOGDIR}"

    weekday=$(date "+%w") && [ -n "${weekday}" ] || die 1 "Failed to determine day of week"
    nodenum=$(/bin/uname -n | /usr/bin/sed -e 's/[^0-9]//g' -e 's/^0*//')

    # Source the configuration file
    [ -e "${CONFIG_FILE}" ] && . "${CONFIG_FILE}"

    # If the dayTSMBackup variable is not defined (in the configuration file),
    # then use the number in the host name to calculate it.
    [ -z "${dayTSMBackup}" ] && ((dayTSMBackup=nodenum%5))
    ((weekdayTSMBackup=dayTSMBackup+WEEKDAY_MONGO_DUMP))
    ((weekdayTSMBackup=weekdayTSMBackup%7))

}

function runCommand {

    typeset cmd="$1"

    if [ "${verbose}" -gt 0 -o -n "${dryrun}" ]; then
        [ -n "${dryrun}" ] && msg "would have run: ${cmd}" || msg "running: ${cmd}"
    fi
    [ -n "${dryrun}" ] || eval "${cmd}" || return 1

    return 0
}

function rsyncDB {

    typeset cfgFile="$1"
    typeset instanceName="$2"
    typeset dbpath="$3"

    # Append "_cfg" to the name of the instance directory to prevent name clashes with a corresponding non-cfg instance
    backupPath="${BACKUP_DIR}/${instanceName}_cfg/tsm_included"
    tmpBackupPath="${BACKUP_DIR}/${instanceName}_cfg/tsm_excluded"

    # rsync is a deprecated backup method and stop/start is no longer used.
    # Stop mongod
    # runCommand "${MONGODB_HOME}/mongod --shutdown --config ${cfgFile}; sleep 15"  || { err "failed to stop instance ${cfgFile}"; return 1; }

    msg "rsyncing config database(s) under ${dbpath}"
    runCommand "rm -rf ${tmpBackupPath}" || return 1
    runCommand "[ -e ${backupPath} ] && mv ${backupPath} ${tmpBackupPath} || mkdir -p ${tmpBackupPath}" || return 1
    runCommand "rsync -av --delete ${dbpath}/ ${tmpBackupPath}/" || return 1
    runCommand "mv ${tmpBackupPath} ${backupPath}" || return 1

    # rsync is a deprecated backup method and stop/start is no longer used.
    # Start mongod
    # runCommand "cd /tmp && ${MONGODB_HOME}/mongod --config ${cfgFile}" || { err "Failed to start instance ${cfgFile}"; return 1; }

    msg "done with rsyncing config database(s) under ${dbpath}"
}

# Dump all databases in an MongoDB instance
function dumpDBs {

    typeset cfgFile="$1"
    typeset instanceName="$2"
    typeset bind_ip="$3"
    typeset port="$4"

    typeset tmpBackupPath
    typeset backupPath

    backupPath="${BACKUP_DIR}/${instanceName}/tsm_included"
    tmpBackupPath="${BACKUP_DIR}/${instanceName}/tsm_excluded"

    msg "dumping databases in ${cfgFile} instance"
    runCommand "rm -rf ${tmpBackupPath} ${backupPath}" || return 1
    runCommand "[ -d ${tmpBackupPath} ] || mkdir -p ${tmpBackupPath}" || return 1

    # mongodump is a deprecated backup method
    # runCommand "time ${MONGODB_HOME}/mongodump --host ${bind_ip} --port ${port} --forceTableScan --oplog --out ${tmpBackupPath}" || return 1

    msg "done with dumping database in ${cfgFile} instance"

    return 0
}

function createFSSnapshotInstance {

    typeset cfgFile="$1"
    typeset instanceName="$2"
    typeset bind_ip="$3"
    typeset port="$4"
    typeset dbpath="$5"

    typeset tmpBackupPath
    typeset backupPath
    pass=$(cat /local/etc/online_pass)
    backupPath="${BACKUP_DIR}/${instanceName}/tsm_included"
    tmpBackupPath="${BACKUP_DIR}/${instanceName}/tsm_excluded"

    msg "Unmounting existing snapshot of ${dbpath} if it exists"
    runCommand "sudo /local/bin/create_fs_snapshot.sh -o umount -f ${dbpath}"
    [ -d "${backupPath}" ] && runCommand "rmdir \"${backupPath}\""

    runCommand "[ -d ${tmpBackupPath} ] || mkdir -p ${tmpBackupPath}" || return 1

    # Stop/start is no longer used. We now use lock/unlock.
    # Stop mongod
    # runCommand "${MONGODB_HOME}/mongod --shutdown --config ${cfgFile}; sleep 15"  || { err "failed to stop instance ${cfgFile}"; return 1; }

    # msg "Creating filesystem snapshot of ${dbpath}"
    # runCommand "sudo /local/bin/create_fs_snapshot.sh -o create -o mount -f ${dbpath} -m ${tmpBackupPath}"

    # Lock  mongod instance
    msg "Locking the database instance $instanceName"
    NumLocks=$(/work/data/mongodb/binaries/community/4.0.23/bin/mongo admin --port $port -u fsync_user -p $pass --eval 'db.fsyncLock()' | grep lockCount | awk -F"[()]" '{print $2}')

    sleep 2m

    msg "Checking the locks in instance $instanceName"
    if /work/data/mongodb/binaries/community/4.0.23/bin/mongo admin --port $port -u fsync_user -p $pass --eval 'db.currentOp().fsyncLock' |tail -1 | grep -q "true";
     then
      msg "Instance $instanceName LOCKED with $NumLocks locks"
      msg "Creating filesystem snapshot of ${dbpath}"
      runCommand "sudo /local/bin/create_fs_snapshot.sh -o create -o mount -f ${dbpath} -m ${tmpBackupPath}"

      dbpathKimeannotationsv2=${dbpath}/kimeannotationsv2
      if [ -d "${dbpathKimeannotationsv2}" ]; then
        dbpathKimeannotationsv2=${dbpath}/kimeannotationsv2
        backupPathKimeannotationsv2="${BACKUP_DIR}/${instanceName}_kimeannotationsv2/tsm_included"
        tmpBackupPathKimeannotationsv2="${BACKUP_DIR}/${instanceName}_kimeannotationsv2/tsm_excluded"
        msg "Unmounting existing snapshot of ${dbpathKimeannotationsv2} if it exists"
        runCommand "sudo /local/bin/create_fs_snapshot.sh -o umount -f ${dbpathKimeannotationsv2}"
        [ -d "${backupPathKimeannotationsv2}" ] && runCommand "rmdir \"${backupPathKimeannotationsv2}\""

        runCommand "[ -d ${tmpBackupPathKimeannotationsv2} ] || mkdir -p ${tmpBackupPathKimeannotationsv2}" || return 1
        msg "Creating filesystem snapshot of ${dbpathKimeannotationsv2}"
        runCommand "sudo /local/bin/create_fs_snapshot.sh -o create -o mount -f ${dbpathKimeannotationsv2} -m ${tmpBackupPathKimeannotationsv2}"
      fi
     else
      msg "ERROR: Instance $instanceName NOT LOCKED"
    fi

    # Unlock mongod
    msg "Unlocking the database instance $instanceName"
    while [ $NumLocks != 0 ]
     do
     msg "Deleting lock number: $NumLocks"
     /work/data/mongodb/binaries/community/4.0.23/bin/mongo admin --port $port -u fsync_user -p $pass --eval 'db.fsyncUnlock()' > /dev/null
     NumLocks=$[$NumLocks-1]
     done

    # Checking the final lock status
    if /work/data/mongodb/binaries/community/4.0.23/bin/mongo admin --port $port -u fsync_user -p $pass --eval 'db.currentOp().fsyncLock' | tail -1 | grep -q "true";
     then
      msg "ERROR: There are still locks in instance $instanceName"
      echo "The instance $instanceName couldn't be unlocked in luu419p" | mailx -s "$SUBJECT" $MAILTO

     else
      msg "Locks successfully removed from instance $instanceName"
    fi

    # Stop/start is no longer used. We now use lock/unlock.
    # Start mongod
    # runCommand "cd /tmp && ${MONGODB_HOME}/mongod --config ${cfgFile}" || { err "Failed to start instance ${cfgFile}"; return 1; }

    return 0
}

function backupInstance {

    typeset cfgFile="$1"
    typeset dbpath="$2"
    typeset bind_ip="$3"
    typeset port="$4"
    typeset configsvr="$5"
    typeset backupMethod="$6"
    typeset rc=0

    [ -n "${BACKUP_DIR}" ] || die 1 "'$BACKUP_DIR' is not defined"

    case ${configsvr} in
        [Tt][Rr][Uu][Ee])
            if [ -n "${skipMongoConfigServers}" ]; then
                msg "skipping config server instance ${cfgFile}"
                return 0
            fi
        ;;
    esac

    msg "backing up instance ${cfgFile}"

    case ${configsvr} in
        [Tt][Rr][Uu][Ee])
            rsyncDB "${cfgFile}" "${instanceName}" "${dbpath}"
        ;;
        *)
            case ${backupMethod} in
                fs_snapshot)
                    createFSSnapshotInstance "${cfgFile}" "${instanceName}" "${bind_ip}" "${port}" "${dbpath}"
                    ;;
                *)
                    dumpDBs "${cfgFile}" "${instanceName}" "${bind_ip}" "${port}"
                    ;;
            esac
            rc=$?

        ;;
    esac

    if ((rc==0)); then
        msg "done backing up instance ${cfgFile}"
    else
        msg "failed to back-up instance ${cfgFile}"
    fi

    return ${rc}
}

function readInstanceConfig {

    typeset instance="$1"

    cfgFile="${MONGO_CFG_DIR}/${instance}"

    [ -r "${cfgFile}" ] || { err "Cannot find/read Mongo configuration file ${cfgFile}"; failedInstances="${failedInstances} ${instance}"; continue; }
    msg ""
    msg "Reading configuration file ${cfgFile}"
    configsvr=""
    dbpath=""
    port=""
    bind_ip=""
    while read line; do
        [ -n "${line}" ] || continue
                # Mongo v2.6 and higher also support a YAML based configuration file format that looks like this:
                # storage:
                #   dbPath: /work/data/mongodb/kime/v2/db
        if [ -z "${line%%*:*}" ]; then
            set ${line}
            line=$1
            line=${line%:}
            line=$(echo "${line}" | tr '[A-Z]' '[a-z]')
            shift
            line="$line=\"$*\""
        fi
        [ -z "${line%port=*}" ]      && eval ${line}
        [ -z "${line%dbpath=*}" ]    && eval ${line}
        [ -z "${line%configsvr=*}" ] && eval ${line}
        [ -z "${line%bind_ip=*}" ]   && eval ${line} && bind_ip="${bind_ip%,*}"
        #if [ -z "${line%clusterrole*}" ] ;then
            #eval ${line}
            #[ -n "${clusterrole}" ] && [ -z "${clusterrole##*configsvr*}" ] && configsvr=true
        #fi

    done < "${cfgFile}"

    # When no bind_ip is configured, we'll try to reach the server on loopback
    [ -z "${bind_ip}" ] && bind_ip="127.0.0.1"

    # Derive the instance name from the name of the configuration file:
    #   ... /kimetext_v2_mongod.conf -> kimetext_v2
    #   .../kimen_cfg.conf -> kimen
    instanceName=${cfgFile}
    instanceName=${instanceName##*/}
    instanceName=${instanceName%_*}

}

function backupInstances {

    [ -d ${MONGO_CFG_DIR} ] || die 1 "Failed to find ${MONGO_CFG_DIR}"

    # Search for mongod configuration files under ${MONGO_CFG_DIR}

    if [ -n "${MONGO_INSTANCES_TO_BACKUP}" ]; then
        receivedInstanceList=1
    else
        # If we didn't receive a list of configuration files in $MONGO_INSTANCES_TO_BACKUP, then search for *.conf files in the mongo configuation directory
        receivedInstanceList=""
        MONGO_INSTANCES_TO_BACKUP=$(find ${MONGO_CFG_DIR} -maxdepth 1 -name "*.conf" -printf "%f\n")
    fi

    backedUpInstances=""
    failedInstances=""

    # First run the filesystem snapshot backups, then the rest, in order to have a better chance of stopping all Mongo instances that manage a shards of a DB around the same time and thus having a better ch
ance of cathing a consistent state.
    for targetBackupMethod in fs_snapshot default; do
        for instance in ${MONGO_INSTANCES_TO_BACKUP}; do
            backupMethod=default
            # The name of the instance file can be following by the backup method that should be used e.g.: kimetext_v2_mongod.conf:fs_snapshot
            if [ -z "${instance##*:*}" ]; then
                backupMethod="${instance#*:}"
                instance="${instance%:*}"
            fi

            # Skip instances that we already failed to backup on a previous iteration.
            [ -n "${failedInstances}" ] && [ -z "${failedInstances##* ${instance}}" ] && continue

            case ${backupMethod} in
                fs_snapshot|default)
                    :
                    ;;
                *)
                    err "Unknown backup method ${backupMethod}; skipping instance ${instance}."
                    failedInstances="${failedInstances} ${instance}"
                    continue
                    ;;
            esac

            [ "${backupMethod}" = "${targetBackupMethod}" ] || continue


            readInstanceConfig "${instance}"

            # When a configuration file has both dbpath and port variables set, we assume it's a mongod configuration file
            if [ -n "${dbpath}" -a -n "${port}" ]; then
                backupInstance "${cfgFile}" "${dbpath}" "${bind_ip}" "${port}" "${configsvr}" "${backupMethod}"|| { failedInstances="${failedInstances} ${instance}"; continue; }
            #If a configuration file does not have both dbpath and port variables but was in passed to us in a static list of instances, then treat this as an error.
            elif [ -n "${receivedInstanceList}" ]; then
                err "Didn't find dbpath or port attribute in Mongo configuration file ${cfgFile}"
                failedInstances="${failedInstances} ${instance}"
                continue;
            fi

            backedUpInstances="${backedUpInstances} ${instance}"
        done
    done
}

# Rename the directories containing Mongo DB dumps from tsm_excluded to tsm_included
# so that they will be considered for back-up during the next daily TSM back-up.
function stageForTSMBackup {

    typeset tmpBackupPath
    typeset backupPath

    [ -n "${BACKUP_DIR}" ] || die 1 "'$BACKUP_DIR' is not defined"

    # Unmount all snapshots to prevent issues trying to rename an active mountpoint
    for instance in ${MONGO_INSTANCES_TO_BACKUP}; do
        backupMethod=default
        # The name of the instance file can be following by the backup method that should be used e.g.: kimetext_v2_mongod.conf:fs_snapshot
        if [ -z "${instance##*:*}" ]; then
            backupMethod="${instance#*:}"
            instance="${instance%:*}"
        fi

        [ "${backupMethod}" = "fs_snapshot" ] || continue

        readInstanceConfig "${instance}"

        tmpBackupPath="${BACKUP_DIR}/${instanceName}/tsm_excluded"
        runCommand "sudo /local/bin/create_fs_snapshot.sh -o umount -f ${dbpath} -m ${tmpBackupPath}"

    done

    find ${BACKUP_DIR} -type d -name "tsm_excluded" | while read dir; do
        runCommand "mv ${dir} ${dir/tsm_excluded/tsm_included}" || err "Failed to rename ${dir}"
    done

    # Mount all snapshots
    for instance in ${MONGO_INSTANCES_TO_BACKUP}; do
        backupMethod=default
        # The name of the instance file can be following by the backup method that should be used e.g.: kimetext_v2_mongod.conf:fs_snapshot
        if [ -z "${instance##*:*}" ]; then
            backupMethod="${instance#*:}"
            instance="${instance%:*}"
        fi

        [ "${backupMethod}" = "fs_snapshot" ] || continue

        readInstanceConfig "${instance}"

        backupPath="${BACKUP_DIR}/${instanceName}/tsm_included"
        runCommand "sudo /local/bin/create_fs_snapshot.sh -o mount -f ${dbpath} -m ${backupPath}"

    done

}


# Main
init "$@"
[ -n "${runBackup}" -o "${weekday}" = "${WEEKDAY_MONGO_DUMP}" ] && backupInstances
[ -n "${runStage}"  -o "${weekday}" = "${weekdayTSMBackup}"   ] && stageForTSMBackup