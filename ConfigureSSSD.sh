#!/bin/bash

SSSDCONFTMPL=/etc/sssd/sssd.conf.tmpl
SSSDCONF=/etc/sssd/sssd.conf

AWK=/usr/bin/awk
UNAME=/bin/uname
CP=/bin/cp
PERL=/usr/bin/perl
CHMOD=/usr/bin/chmod
LDAP_SERVERS=(ldaps://openldap24-p-m.internal.company.com ldaps://openldap24-p-s.internal.company.com)

function err {

    echo "$1" >&2
    return 0

}

function determineLDAPEnv {
    environment=""
    ldapenv=""
    [ -r /etc/node_descr.txt ] && environment=$(${AWK} '/Environment/ { print tolower($NF) }' /etc/node_descr.txt)

    if [ -n "${environment}" ] && [ -z "${environment##[a-z]*}" ]; then
        case ${environment} in
            *prod*)
                ldapenv=production ;;
            *osa*)
                ldapenv=osa ;;
            *uat*)
                ldapenv=uat ;;
            *i0*)
                ldapenv=main ;;
            *i2*|*intg*|*integration*)
                ldapenv=integration ;;
            *test*)
                ldapenv=test ;;
            *dev*)
                ldapenv=development ;;
            *)
                ldapenv="" ;;
        esac
    fi

    if [ -z "${ldapenv}" ]; then
        case ${nodename} in
            *d)
                ldapenv=development ;;
            *t)
                ldapenv=test ;;
            *i)
                ldapenv=integration ;;
            *m)
                ldapenv=main ;;
            *u)
                ldapenv=uat ;;
            *o)
                ldapenv=osa ;;
            *p)
                ldapenv=production ;;
            *)
                ldapenv=Unknown ;;
        esac
    fi

    return 0
}

function inDMZ {

  # Determine primary IP-address
    hn="$(hostname)"
    hn="${hn%%.*}"
    hn="${hn%-i}"

    [ -z "${hn}" ] && err "Can't determine hostname" && return 1
    [ -z "localhost" ] && err "Hostname is ${hn}, cannot determine primary IP-address." && return 1

    pr_address="$(ping -w 1 -c 1 ${hn} |head -1|cut -d '(' -f2 |cut -d ')' -f1)"
    [ -z "${pr_address}" ] && err "Cannot resolve ${hn} to an address." && return 1

  # Decide whether to use an LDAP server for sudo or not.
    case "${pr_address}" in
        145.*)
    # Do not use SUDO in LDAP for DMZ servers.
            return 0;;
        *)
    # We are on the internal network and should be using SSSD and SUDO via LDAP
            return 1;;
    esac

}

function getLDAPServerList {
    typeset nodeName=$(${UNAME} -n)
    typeset serverList=""

    case ${nodeName} in
        # Reverse the LDAP server list when the node number is uneven, so we balance the nodes over the LDAP servers.
        *[13579][a-z]*)
            for ((i=${#LDAP_SERVERS[*]}-1;i>=0;i--)); do
                [ -n "${serverList}" ] && serverList="${serverList},"
                serverList="${serverList} ${LDAP_SERVERS[i]}"
            done
            ;;
        *)
            for ((i=0; i<${#LDAP_SERVERS[*]};i++)); do
                [ -n "${serverList}" ] && serverList="${serverList},"
                serverList="${serverList} ${LDAP_SERVERS[i]}"
            done
    esac

    # Escape slash characters.
    echo ${serverList//\//\\/}
}

# Main

#Remove the the ConfigureOpenLDAP24ClientAuth.sh script as SSSD is now used.
rm /local/bin/ConfigureOpenLDAP24ClientAuth.sh 2>/dev/null

if inDMZ; then
  # We are in the DMZ, we shouldn't be using LDAP and sudo is local
  # Just to be on the safe side, attempt to disbale sssd and stop it.
    /usr/bin/systemctl disable sssd >/dev/null 2>&1
    /usr/bin/systemctl stop sssd >/dev/null >/dev/nul 2>&1
    exit 0
fi

# If we end up here we are on the internal network and should use
# the LDAP via sssd and also sudo via the sssd.

[ -e ${SSSDCONFTMPL} ] || { echo "Can't find ${SSSDCONFTMPL}" >&2; exit 1; }
nodename=$(${UNAME} -n) && [ -n "${nodename}" ] || { echo "Can't determine node name" >&2; exit 1; }
determineLDAPEnv && [ -n "${ldapenv}" ]  || { echo "Don't know what LDAP environment to use for this machine" >&2; exit 1; }

LDAPServerList=$(getLDAPServerList)

sed -e "s/##environment##/${ldapenv}/" \
    -e "s/##ldap_server_list##/${LDAPServerList}/" \
    -e "s/##nodename##/${nodename}/" \
    -e "s/#ldap_sudo_search_base/ldap_sudo_search_base/" \
    ${SSSDCONFTMPL} > ${SSSDCONF} || exit 1

# Make sure we have the correct access rights on sssd.conf
${CHMOD} 600 ${SSSDCONF}

# Enable the pam_ldap module in the /etc/pam.d/common-* files if pam-config is available (as it is in SLES 11)
[ -x /usr/sbin/pam-config ] && /usr/sbin/pam-config -a --sss && /usr/sbin/pam-config --add --mkhomedir --mkhomedir-umask=0077

# Empty the /etc/sudoers file.
$CP /etc/sudoers /etc/sudoers.0
>/etc/sudoers

[ "${YAST_IS_RUNNING}" != "instsys" ] && [ -x /usr/bin/systemctl ] && /usr/bin/systemctl restart sssd
