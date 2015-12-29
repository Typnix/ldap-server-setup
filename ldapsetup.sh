#!/bin/bash

ORGANISATION=""
DOMAIN=""
ADMIN_NAME=""
LDAP_DOMAIN=""
LDAPGROUPS=("People" "Group")
MANAGER=""

ENABLE_INTERNALCA=0
ENABLE_INSTALL=0
ENABLE_SUDOERS=0
ENABLE_SSH_KEY_AUTH=0
ENABLE_TESTUSER=0

installOpenLDAPServer(){
rpm -qa --quiet openldap*
if [  $? -gt 0 ]; then
	yum -y install openldap-servers openldap-clients
fi

if [ -f /usr/share/openldap-servers/DB_CONFIG.example ]; then
	cp /usr/share/openldap-servers/DB_CONFIG.example /var/lib/ldap/DB_CONFIG 
	chown ldap. /var/lib/ldap/DB_CONFIG
else
	echo "No LDAP config found"; 
fi

systemctl start slapd && systemctl enable slapd 

ldapadd -Y EXTERNAL -H ldapi:/// <<__EOF
dn: olcDatabase={0}config,cn=config
changetype: modify
add: olcRootPW
olcRootPW: $(slappasswd -s $PASSWD)
__EOF

if [  $? -gt 0 ]; then
	echo "Password is not set"; 
fi
}

importLDIFS(){
ldifsschema=("nis" "cosine" "inetorgperson")

if [[ $ENABLE_LDAPSUDO -gt 0 ]]; then 
echo "
dn: cn=sudo,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: sudo
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.1 NAME 'sudoUser' DESC 'User(s) who may  run sudo' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.2 NAME 'sudoHost' DESC 'Host(s) who may run sudo' EQUALITY caseExactIA5Match SUBSTR caseExactIA5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.3 NAME 'sudoCommand' DESC 'Command(s) to be executed by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.4 NAME 'sudoRunAs' DESC 'User(s) impersonated by sudo (deprecated)' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.5 NAME 'sudoOption' DESC 'Options(s) followed by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.6 NAME 'sudoRunAsUser' DESC 'User(s) impersonated by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcAttributeTypes: ( 1.3.6.1.4.1.15953.9.1.7 NAME 'sudoRunAsGroup' DESC 'Group(s) impersonated by sudo' EQUALITY caseExactIA5Match SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 )
olcObjectClasses: ( 1.3.6.1.4.1.15953.9.2.1 NAME 'sudoRole' SUP top STRUCTURAL DESC 'Sudoer Entries' MUST ( cn ) MAY ( sudoUser $ sudoHost $ sudoCommand $ sudoRunAs $ sudoRunAsUser $ sudoRunAsGroup $ sudoOption $ description ) )
" > /etc/openldap/schema/sudoers.ldif

ldifsschema=("${ldifsschema[@]}" "sudoers")
LDAPGROUPS=("${LDAPGROUPS[@]" "SUDOers")
fi

if [[ $ENABLE_SSH_KEY_AUTH -gt 0 ]]; then
echo "
dn: cn=openssh-openldap,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: openssh-openldap
olcAttributeTypes: {0}( 1.3.6.1.4.1.24552.500.1.1.1.13 NAME 'sshPublicKey' DES C 'MANDATORY: OpenSSH Public key' EQUALITY octetStringMatch SYNTAX 1.3.6.1.4.  1.1466.115.121.1.40 )
olcObjectClasses: {0}( 1.3.6.1.4.1.24552.500.1.1.2.0 NAME 'ldapPublicKey' DESC 'MANDATORY: OpenSSH LPK objectclass' SUP top AUXILIARY MUST ( sshPublicKey $ uid ) )
"  > /etc/openldap/schema/openldap-ssh.ldif
ldifsschema=("${ldifsschema[@]}" "openldap-ssh" "core")
fi

for ldifname in "${ldifsschema[@]}"
do
	ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/$ldifname.ldif
	if [  $? -gt 0 ]; then
		echo "Sudoers schema is not imported"; 
	fi
done
}

configLDAPServer(){
ldapmodify -Y EXTERNAL -H ldapi:/// <<__EOF
dn: olcDatabase={1}monitor,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" read by
  dn.base="$MANAGER" read by * none

dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: $LDAP_DOMAIN

dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcRootDN
olcRootDN: $MANAGER

dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcRootPW
olcRootPW: $(slappasswd -s $PASSWD)

dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: args config acl stats

dn: olcDatabase={2}hdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange by dn="$MANAGER" write by 
  anonymous auth by self write by * none
olcAccess: {1}to dn.base=""
  by * read
olcAccess: {2}to * by 
  dn="$MANAGER" write by * read
__EOF
if [  $? -gt 0 ]; then
	echo "Configuration has been failed"; 
fi
}

createLDAPStructure(){
ldapadd -x -D $MANAGER -w $PASSWD <<__EOF
dn: $LDAP_DOMAIN
objectClass: top
objectClass: dcObject
objectclass: organization
o: $ORGANISATION

dn: $MANAGER
objectClass: organizationalRole
cn: Manager
description: Directory Manager
__EOF

for group in "${LDAPGROUPS[@]}"
do
ldapadd -x -D $MANAGER -w $PASSWD <<__EOF
dn: ou=$group,$LDAP_DOMAIN
objectClass: organizationalUnit
ou: $group
__EOF
if [  $? -gt 0 ]; then
	echo "Domain is not created"; 
fi
}

createTestUser(){
ldapadd -x -D $MANAGER -w $PASSWD <<__EOF
dn: uid=test,ou=People,$LDAP_DOMAIN
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
sn: Test
cn: Test
uid: test
userPassword: $(slappasswd -s 'testing')
loginShell: /bin/bash
uidNumber: 2000
gidNumber: 2000
homeDirectory: /home/test

dn: cn=Test,ou=Group,$LDAP_DOMAIN
objectClass: posixGroup
cn: Test
gidNumber: 3000
memberUid: test
__EOF
if [  $? -gt 0 ]; then
	echo 'Test user is not created'; 
fi
}

setupInternalCA(){
certutil -d /etc/openldap/certs -f /etc/openldap/certs/password -W
certutil -d etc/openldap/certs -S -n "CA certificate" -s "cn=$ORGANISATION CA cert, $LDAP_DOMAIN" -2 -x -t "CT,," -m 1000 -v 120 -d . -k rsa -Z SHA256
certutil -L -d etc/openldap/certs -n "CA certificate" -a > /etc/openldap/cacerts/cacert.pem
certutil -S -n "LDAP Server-Cert" -s "cn=ldap.$DOMAIN" -c "CA certificate" -t "u,u,u" -m 1001 -v 120 -d . -k rsa -Z SHA256
certutil -L -d etc/openldap/certs -n "LDAP Server-Cert" -a > /etc/openldap/certs/client.pem
}

usage(){
	printf "Usage: $0 -d [ domain ] -o [ organisation ] [-acisS]\n"
}

# -a Do everything
# -i Install OpenLDAP Server
# -c Install Internal CA and create CA and Client certicificate
# -o Organisation
# -d Domain
# -s Enable SUDO support
# -S Enable LDAP SSH key auth  
# -t Create Test User


while getopts ":acd:im:o:t" opt; do
  case $opt in
    a) 	ENABLE_INTERNALCA=1;ENABLE_INSTALL=1;ENABLE_SUDOERS=1;ENABLE_SSH_KEY_AUTH=1;ENABLE_TESTUSER=1 ;;
    c)  NABLE_INTERNALCA=1 >&2 ;;
    d)  DOMAIN=$OPTARG >&2 ;;
    i)  ENABLE_INSTALL=1 >&2 ;;
    m)  ADMIN_NAME=$OPTARG >&2 ;;
    o)  ORGANISATION=$OPTARG >&2 ;;
    s)  ENABLE_SUDOERS=1 >&2 ;;
    S)  ENABLE_SSH_KEY_AUTH=1 >&2 ;;
    t)  ENABLE_TESTUSER=1 >&2 ;;
    *) usage ;;
  esac
done

if [ -z $ADMIN_NAME ]; then
	exit 1
fi

if [ -n "$DOMAIN" ]; then
        DOM="$(echo "$DOMAIN" | cut -d. -f1)"
        EXT="$(echo "$DOMAIN" | cut -d. -f2)"
        LDAP_DOMAIN="dc=$DOM,dc=$EXT"
	MANAGER="cn=$ADMIN_NAME,$LDAP_DOMAIN"
else
        exit 1
fi

if [[ "$ORGANISATION" = " " ]]; then
	exit 1
fi 

read -s -p "Admin Password: " PASSWD
[[ "$PASSWD" = " " ]] && exit 1

if [[ $ENABLE_INSTALL -gt 0 ]]; then
	installOpenLDAPServer
fi

importLDIFS
configLDAPServer
createLDAPStructure

if [[ $ENABLE_TESTUSER -gt 0 ]]; then
	createTestUser
fi
if [[ $ENABLE_INTERNALCA -gt 0 ]]; then
	setupInternalCA
fi
