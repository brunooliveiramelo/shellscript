#!/usr/bin/sh
#-------------------------------------------------------------------------------
#
# Name:          housekeeping_orphaned-directory.sh
# Author:        Bruno Alex Oliveira Melo
# Date:          2022.05.13
# Description:   This script will be used to find .ssh owners directory that
#                no longer exists and set it to obsolete
#
#
# Changes:
#
#
#-------------------------------------------------------------------------------

VERBOSITY=4 # Print all
LOGDIR="/log/housekeeping"
ERRORFILE=${LOGFILE}.errors
LOGFILE="epo_housekeeping_orphaned.log"
NOW=$(/bin/date +'%Y-%m-%d')
TIMESTAMP=$(/bin/date +'%b %d %X')
FLAGFILE=DO-NOT-REMOVE-OR-TOUCH.flag
FLAFILEMOVE=DATE-MOVED-OBSOLETE-DO-NOT-REMOVE-OR-TOUCH.flag
HOUSEKEEPINGFLAG="/work/tmp/doHousekeepingFlag.flag"
STATEOWNER="/work/tmp/owner.state"
STATEOWNERTRUE="/work/tmp/ownerexist.state"
STATEOWNERFALSE="/work/tmp/ownerNOTexist.state"
HOMEPATH="/home"
SSHPATH=".ssh/"
SSHOBSOLETEPATH=".ssh-obsolete/"
OBSOLETEHOMEDIR="/home/obsolete/"
#   command line parameters
sleep="/usr/bin/sleep"
find="/usr/bin/find"
getent="/usr/bin/getent"
stat="/usr/bin/stat"
rm="/usr/bin/rm"
mv="/usr/bin/mv"
touch="/usr/bin/touch"
sed="/usr/bin/sed"
cut="/usr/bin/cut"
cat="/usr/bin/cat"
tee="/usr/bin/tee"
ls="/usr/bin/ls"
echo="/usr/bin/echo"
grep="/usr/bin/grep"
tr="/usr/bin/tr"

VERBOSITY=4 # Print all
awk="/usr/bin/awk"
GREP="/usr/bin/grep"
FIND="/usr/bin/find"
PRINT="/usr/bin/printf"
TR="/usr/bin/tr"
ECHO="/bin/echo"
CAT="/bin/cat"
LOGDIR="/log/housekeeping/"
LOGFILE="" #only logfile when not from a tty.
dryrun=0





Help() {

    $cat <<EOT

housekeeping_orphaned-directory.sh [-v ALL|INFO|WARNING|ERROR]
                 [-h|-H]
                 [-n|-N]

where

   -v             : Sets the verbosity of the script. Default verbosity
                    is WARNING.
                    ALL     - Will print everything the script does.
                    INFO    - Will print informational log statements and
                              warnings and errors.
                    WARNING - Will print only warnings and errors.
                    ERROR -   Will print only errors.

                    The script will regardles of the log level print a
                    summary of warnings and errors at the end.

   -h|-H          : Prints this text.

   -n|-N          : runs in dry-run mode. Will perform operations and update/create
                    temp files. But will not take actions, create files of configs.

The script will:

    - check if the obsolete dir and temp files exist, if not will be create;
    - obtain and check if the owner of each directory in /home exist or not;
    - check for each not existent owner directory if .ssh exist. If so, rename it to ss-obsolete and create a flag;
    - check for each ssh-obolete directory if the flag created is more than 3 months exist;
    - check if the first flag has more than 3 months and create another one indicating do not removing;

EOT
}

LogMsg() {

    #    if [[ -n $TRACE_ON ]]; then
    #       set -x
    #    fi

    level=$1
    source=$2
    source=${source%%.*} # Remove domain name if any.
    msg=$3
    summary=$4
    timestamp=$(date +"%y.%m.%d-%H:%M")

    case $level in
    0) label="ERROR" ;;
    1) label="WARNING" ;;
    2) label="INFO" ;;
    3) label="ALL" ;;
    *) label="UNKOWN" ;;
    esac

    if [[ ($level < $VERBOSITY) || (-n $summary) ]]; then
        if [[ -n $LOGFILE ]]; then
            $PRINT "%-14s %-7s %-10s - %-s\n" $timestamp $label $source "$msg" >>$LOGFILE
        else
            $PRINT "%-14s %-7s %-10s - %-s\n" $timestamp $label $source "$msg"
        fi
    fi

    if [[ ($label = ERROR) && (-n $ERRORFILE) && (-z $summary) ]]; then
        $echo "$msg" >>"$ERRORFILE"
    fi

}

CheckDir() {
    LogMsg 3 checkdir "[checking if obsolete dir and temp files exist]"

    #
    # Check OBSOLETE DIR, create if it dosn't exist.
    #
    if [ $dryrun -ne 1 ]; then
        if [ ! -d "$OBSOLETEHOMEDIR" ]; then
            LogMsg 3 checkdir "Creating obsolete directory "$OBSOLETEHOMEDIR""
            /bin/mkdir -m 755 -p "$OBSOLETEHOMEDIR"
                if [ $? -gt 0 ]; then
                    LogMsg 0 checkdir "Could not create obsolete directory "$OBSOLETEHOMEDIR""
                    exit 1
                fi
        fi
    else
        if [ ! -d "$OBSOLETEHOMEDIR" ]; then
            LogMsg 3 checkdir "Creating obsolete directory "$OBSOLETEHOMEDIR""
        fi
    fi
    # Check TEMP DIR, create if it dosn't exist.
    #

    if [ ! -e $STATEOWNERTRUE ]; then
        LogMsg 3 checkdir "Creating temporary file "$STATEOWNERTRUE""
        /bin/touch "$STATEOWNERTRUE"
         if [ $? > 0 ]; then
         LogMsg 0 checkdir "Could not create temporary file "$STATEOWNERTRUE""
         exit 1
         fi
    fi

    if [ ! -e $STATEOWNERFALSE ]; then
        LogMsg 3 checkdir "Creating temporary file $STATEOWNERFALSE"
        /bin/touch $STATEOWNERFALSE
         if [ $? > 0 ]; then
         LogMsg 0 checkdir "Could not create temporary file "$STATEOWNERFALSE""
         exit 1
         fi
    fi

}


checkGetent() {
    #   check if directoty in /home is owned by an existing user
    # searches within /home for the owners and their directories and exports to a file.
    LogMsg 3 checkgetent "[checking if if directoty in /home is owned by an existing user]"
    "$find" "$HOMEPATH" -maxdepth 1 -type d -exec "$stat" -c '%U'" "'%n' {} + >"$STATEOWNER"
    ownerstatus=()
    #  validates with the getent command whether the owners are valid or not, and exports to the files.
    while IFS=" " read -r owner dir; do
        ownerstatus+=($("$getent" passwd -s sss ${owner})) >/dev/null
        if [ $? -eq 0 ]; then
            echo """${owner}"" ""${dir}"" "exist"" 2>&1 | "$tee" -a "$STATEOWNERTRUE" >/dev/null
            LogMsg 2 checkgetent " "${owner}" "${dir}" exist"
        else
            echo """${owner}"" ""${dir}"" "not-exist"" 2>&1 | "$tee" -a "$STATEOWNERFALSE" >/dev/null
            LogMsg 2 checkgetent " "${owner}" "${dir}" not-exist"
        fi
    done <"$STATEOWNER"
}

checkSSH() {
    #   validates that non-existing owners have the .ssh directory.
    #   If so, rename it to ss-obsolete and create a flag to identify the tag to be validated later if it is older than 3 months.
    LogMsg 3 checkssh "[checking if non-existing owner have the .ssh directory]"
    checkssh1="$STATEOWNERFALSE"
    while IFS=' ' read -r owner dir status; do
        if [ -d "$dir"/"$SSHPATH" ]; then
            LogMsg 2 checkssh "ssh path has been found in "$dir/$SSHPATH" and renaming to ssh-obsolete "$dir/$SSHOBSOLETEPATH""
            [ ${dryrun} -ne 1 ] && "$mv" -T "$dir"/"$SSHPATH" "$dir"/"$SSHOBSOLETEPATH"""
            if [ -e "$dir"/"$FLAGFILE" ]; then
                LogMsg 2 flagfile "Flagfile "$dir"/"$FLAGFILE" already exist and will not be created"
            else
                [ ${dryrun} -ne 1 ] && "$touch" "$dir"/"$FLAGFILE"
                LogMsg 2 flagfile "flag file has been created "$dir/$FLAGFILE""
            fi
        fi
    done <"$checkssh1"
}

doHousekeepingFlag() {
    #   search the /home path for any directory with the DO-NOT-REMOVE-OR-TOUCH.flag if it was created more than 3 months ago.
    #   if found, the entire directory is moved to /home/obsolete and a new flag DATE-MOVED-OBSOLETE-DO-NOT-REMOVE-OR-TOUCH.flag is created.
    LogMsg 3 housekeepingflag "[do housekeeping for flag that has more than 3 months]"
    "$find" "$HOMEPATH" -maxdepth 2 -name "$FLAGFILE" -mtime +30 -not -path "/home/obsolete/*" >"$HOUSEKEEPINGFLAG"

    if [ ! -s "$HOUSEKEEPINGFLAG" ]; then #     check if file exist and has not a size greater than zero, that is, the script couldn't find any directory.
        LogMsg 2 housekeepingflag "no ssh folder were found that were older than 3 months to be moved to obsolete"

    else
        [ -s "$HOUSEKEEPINGFLAG" ] #     check if file exist and has a size greater than zero, that is, the script find any directory.
        "$cat" "$HOUSEKEEPINGFLAG" | "$sed" s'/DO-NOT-REMOVE-OR-TOUCH.flag//'g | "$cut" -d/ -f3- |
            while IFS= read -r homedir; do
                LogMsg 2 housekeepingflag "find flag "$HOMEPATH"/"$homedir""$FLAFILEMOVE" that has more than 3 month. It will be moved whole directory to obsolete"

                [ ${dryrun} -ne 1 ] && "$mv" "$HOMEPATH"/"$homedir" """$OBSOLETEHOMEDIR"""
                LogMsg 2 housekeepingflag " creating flag ""$OBSOLETEHOMEDIR""""$homedir""""$FLAFILEMOVE"" to mark file moved to obsolete"

                [ ${dryrun} -ne 1 ] && "$touch" "$OBSOLETEHOMEDIR""$homedir""$FLAFILEMOVE"
            done
    fi
}

Cleanup() {
    LogMsg 3 cleanup "[starting clean-up for temp files before start]"
    declare -a array=("$STATEOWNER" "$STATEOWNERTRUE" "$STATEOWNERFALSE" "$HOUSEKEEPINGFLAG")
    for files in "${array[@]}"; do
        LogMsg 2 cleanup "cleaning up old temporary files "$files""
        echo > "$files"
        [ ${dryrun} -ne 1 ] && "$rm" -rf "$files"

    done
}


if [[ -n $TRACE_ON ]]; then
    set -x
fi

while getopts ":nN:hH:v:" opt; do
    case ${opt} in
    v) {
        VERBOSITY=$($echo $OPTARG | $tr 'a-z' 'A-Z')
        if ! $echo "$VERBOSITY" | $grep -q -i -E "^(all|error|warning|action|info)$" 2>/dev/null; then
            $echo "Verbosity must be one of INFO, WARNING or ERROR."
            exit 1
        fi

        if [[ $VERBOSITY = ALL ]]; then
            VERBOSITY=4
            LogMsg 3 housekeeping "Log level set to ALL ($VERBOSITY)."
        elif [[ $VERBOSITY = INFO ]]; then
            VERBOSITY=3
            LogMsg 3 housekeeping "Log level set to INFO ($VERBOSITY)."
        elif [[ $VERBOSITY = WARNING ]]; then
            VERBOSITY=2
        elif [[ $VERBOSITY = ERROR ]]; then
            VERBOSITY=1
        fi

    } ;;
    h) {
        Help
        exit 0
    } ;;

    n) {
        dryrun=1
        LogMsg 3 Dry-run "Dry-run set to on ($dryrun)."
    } ;;

    \?) {

        Help
        exit 0
    } ;;
    esac
done

#shift $((OPTIND - 1))
CheckDir
checkGetent
checkSSH
doHousekeepingFlag
Cleanup