#!/bin/sh
# written by Ugo Viti <ugo.viti@initzero.it>
# version: 20181215
#set -ex

# default variables
## webserver options
: ${MULTISERVICE:=false}          # (true|**false**) enable multiple service manager
: ${UMASK:=0002}                  # (**0002**) default umask when creating new files
: ${SERVERNAME:=$HOSTNAME}        # (**$HOSTNAME**) default web server hostname
: ${HTTPD_ENABLED:=true}          # (**true**|false) # enable apache web server
: ${HTTPD_MOD_SSL:=false}         # (true|**false**) enable apache module mod_ssl
: ${HTTPD_CONF_DIR:=/etc/apache2} # (**/etc/apache2**) # apache config dir
: ${HTTPD_MPM:=prefork}           # (event|worker|**prefork**) # default apache mpm worker to use
: ${PHP_ENABLED:=true}            # (**true**|false) enable apache module mod_php
: ${PHPFPM_ENABLED:=false}        # (true|**false**) enable php-fpm service
: ${PHPINFO:=false}               # (true|**false**) if true, then automatically create a **info.php** file into webroot
: ${DOCUMENTROOT:=/var/www/localhost/htdocs} # (**directory path**) default webroot path
: ${PHP_PREFIX:=/usr/local/php}   # PHP base path
: ${PHP_INI_DIR:=$PHP_PREFIX/etc/php} # php ini files directory
: ${PHP_CONF:="$PHP_INI_DIR/php.ini"} # path of php.ini file

## smtp options
: ${domain:="$HOSTNAME"}                # local hostname
: ${from:="root@localhost.localdomain"} # default From email address
: ${host:="localhost"}                  # remote smtp server
: ${port:=25}                           # smtp port
: ${tls:="off"}                         # (**on**|**off**) enable tls
: ${starttls:="off"}                    # (**on**|**off**) enable starttls
: ${username:=""}                       # username for auth smtp server
: ${password:=""}                       # password for auth smtp server
: ${timeout:=3600}                      # connection timeout

export MULTISERVICE UMASK HTTPD_ENABLED PHP_ENABLED PHPFPM_ENABLED
# set default umask
umask $UMASK

## misc functions
print_path() {
  echo ${@%/*}
}

print_fullname() {
  echo ${@##*/}
}

print_name() {
  print_fullname $(echo ${@%.*})
}

print_ext() {
  echo ${@##*.}
}

## exec entrypoint hooks

# HTTPD configuration
if [ "$HTTPD_ENABLED" = "true" ]; then
  echo "=> Configuring Apache Web Server..."
  echo "--> INFO: Setting default ServerName to: ${SERVERNAME}"
  sed "s/^#ServerName.*/ServerName ${SERVERNAME}/" -i "${HTTPD_CONF_DIR}/httpd.conf"
  echo "--> INFO: Setting default DocumentRoot to: ${DOCUMENTROOT}"
  sed "s|/var/www/localhost/htdocs|${DOCUMENTROOT}|" -i "${HTTPD_CONF_DIR}/httpd.conf"
  #echo "--> INFO: Setting default logging to: CustomLog /proc/self/fd/1 common env=!nolog"
  #sed "s|CustomLog .*|CustomLog /proc/self/fd/1 common env=!nolog|" -i "${HTTPD_CONF_DIR}/httpd.conf"
  #echo "SetEnvIf Request_URI "GET /.probe" nolog" >> "${HTTPD_CONF_DIR}/httpd.conf"
  # configure apache mpm
  case $HTTPD_MPM in
	  worker|event|prefork)
      echo "--> INFO: configuring default apache worker to: mpm_$HTTPD_MPM"
      sed -r "s|^LoadModule mpm_|#LoadModule mpm_|i" -i "${HTTPD_CONF_DIR}/httpd.conf"
      sed -r "s|^#LoadModule mpm_${HTTPD_MPM}_module|LoadModule mpm_${HTTPD_MPM}_module|i" -i "${HTTPD_CONF_DIR}/httpd.conf"
      ;;
  esac

  PHP_VERSION_ALL=$(php -v | head -n1)
  # Verify if PHP is Thread Safe compiled (ZTS)
  case $HTTPD_MPM in
	  worker|event)
	  if echo $PHP_VERSION_ALL | grep -i nts >/dev/null; then
      if [ "$PHP_ENABLED" != "false" ]; then
        PHP_ENABLED="false"
        PHPFPM_ENABLED="true"
        echo "--> WARNING: disabling mod_php module because current apache worker is 'mpm_$HTTPD_MPM' and PHP is not ZTS (Zend Thread Safe) compiled: $PHP_VERSION_ALL"
        echo "--> INFO: enabling php-fpm because: HTTPD_MPM=$HTTPD_MPM and PHPFPM_ENABLED=$PHPFPM_ENABLED"
      fi
    fi
    ;;
  esac

  # manage mod_php
  if [ "$PHP_ENABLED" = "true" ]; then
    echo "--> INFO: enabling Apache mod_php: $PHP_VERSION_ALL"
    # enable mod_php
    echo "#LoadModule php7_module        modules/libphp7.so
    DirectoryIndex index.php index.html
    <FilesMatch \.php$>
      SetHandler application/x-httpd-php
    </FilesMatch>" > ${HTTPD_CONF_DIR}/conf.d/php.conf
    [ "$PHPINFO" = "true" ] && echo "<?php phpinfo(); ?>" > ${DOCUMENTROOT}/info.php
   else
     echo "--> INFO: disabling mod_php because: PHP_ENABLED=$PHP_ENABLED"
     sed "s/^LoadModule php/#LoadModule php/" -i "${HTTPD_CONF_DIR}/httpd.conf"
  fi

  # manage php-fpm service
  if [ "$PHPFPM_ENABLED" = "true" ]; then
     echo "--> INFO: enabling php-fpm service via multi service manager"
     MULTISERVICE=true
    else
     echo "--> INFO: disabling php-fpm service because: PHPFPM_ENABLED=$PHPFPM_ENABLED"
     [ "$MULTISERVICE" = "true" ] && rm -rf /etc/service/php-fpm
  fi

  # enable mod_ssl
  if [ "${HTTPD_MOD_SSL}" = "true" ]; then
    echo "--> INFO: enabling mod_ssl module because: HTTPD_MOD_SSL=${HTTPD_MOD_SSL}"
    sed "s/^#LoadModule ssl_module/LoadModule ssl_module/" -i "${HTTPD_CONF_DIR}/httpd.conf"
  fi

  # verify if SSL files exist otherwise generate self signed certs
  #set -x

  # search for all certificates
  #grep -H -r "^.*SSLCertificate.*File " ${HTTPD_CONF_DIR}/*.d/*.conf 2>/dev/null |

  # search if exist all SSLCertificateFile files
  grep -H -r "^.*SSLCertificateFile " ${HTTPD_CONF_DIR}/*.d/*.conf 2>/dev/null |
  {
  while read line; do
  config_file=$(echo $line | awk '{print $1}' | sed 's/:$//')
  config_object=$(echo $line | awk '{print $2}')
  cert_file=$(echo $line | awk '{print $3}')
  if [ ! -e "$cert_file" ]; then
    echo "--> ERROR: into '$config_file' the certificate '$config_object' file doesn't exist: '$cert_file'"
    if [ -w "$config_file" ]; then
      echo "---> INFO: disabling line: '$config_object $cert_file'"
      sed -e "s|$line|#$line|" -i "$config_file"
     else
      echo "---> WARNING: the file '$config_file' is not writable... unable to disable line: '$config_object $cert_file'"
      echo "----> INFO: generating self signed certificate file to avoid configuration errors"
      ssl_dir="$(print_path $cert_file)"
      cn="$(print_name $cert_file)"

      # create the ssl dir if not exist
      [ ! -e "${ssl_dir}" ] && mkdir -p "${ssl_dir}"

      # ssl domain files detection (FIXME: find a better way to discover the used files name. we are assuming that every certificate is located into different dir)
      # detect the SSLCertificateFile
      ssl_crt="$(grep -H -r "^.*SSLCertificateFile.*${ssl_dir}/" ${HTTPD_CONF_DIR}/*.d/*.conf | awk '{print $3}')"

      # detect the SSLCertificateKeyFile
      ssl_key="$(grep -H -r "^.*SSLCertificateKeyFile.*${ssl_dir}/" ${HTTPD_CONF_DIR}/*.d/*.conf | awk '{print $3}')"
      ssl_csr="${ssl_dir}/${cn}.csr"

      # detect the SSLCertificateKeyFile
      ssl_chain_crt="$(grep -H -r "^.*SSLCertificateChainFile.*${ssl_dir}/" ${HTTPD_CONF_DIR}/*.d/*.conf | awk '{print $3}')"
      ssl_chain_key="${ssl_dir}/${cn}.chain.key"
      ssl_chain_csr="${ssl_dir}/${cn}.chain.csr"

      # openssl ca files
      ssl_ca_key="${ssl_dir}/${cn}.ca.key"
      ssl_ca_crt="${ssl_dir}/${cn}.ca.crt"

      cd "${ssl_dir}"

      # generate CA x509v3
      echo "-----> INFO: generating Certification Authority files: ${ssl_ca_key}"
      openssl req -x509 -newkey rsa:4096 -sha256 -extensions v3_ca -nodes -keyout "${ssl_ca_key}" -out "${ssl_ca_crt}" -subj "/O=Self Signed/OU=Web Services/CN=$cn Certification Authority" -days 3650

      # generate CA Intermediate Chain x509v3
      echo "-----> INFO: generating Intermediate Chain KEY file: ${ssl_chain_key}"
      openssl genrsa -out "${ssl_chain_key}" 4096
      echo "-----> INFO: generating Intermediate Chain CSR file: ${ssl_chain_csr}"
      openssl req -new -sha256 -key "${ssl_chain_key}" -out "${ssl_chain_csr}" -subj "/O=Self Signed/OU=Web Services/CN=$cn CA Intermediate Chain"
      echo "-----> INFO: generating Intermediate Chain CRT file: ${ssl_chain_crt}"
      openssl x509 -req -sha256 -in "${ssl_chain_csr}" -CA "${ssl_ca_crt}" -CAkey "${ssl_ca_key}" -CAcreateserial -out "${ssl_chain_crt}" -days 3650

      # generate domain certs
      echo "-----> INFO: generating ${cn} KEY file: ${ssl_key}"
      openssl genrsa -out "${ssl_key}" 4096
      echo "-----> INFO: generating ${cn} CSR file: ${ssl_csr}"
      openssl req -new -sha256 -key "${ssl_key}" -out "${ssl_csr}" -subj "/O=Self Signed/OU=Web Services/CN=$cn"
      echo "-----> INFO: generating ${cn} CRT file by signing CSR file: ${ssl_crt}"
      openssl x509 -req -sha256 -in "${ssl_csr}" -CA "${ssl_ca_crt}" -CAkey "${ssl_ca_key}" -CAcreateserial -out "${ssl_crt}" -days 3650

      # avoid missing chain.crt file
      #[ ! -e "${ssl_dir}/${cn}.chain.crt" ] && ln -s "${ssl_dir}/${cn}.ca.crt" "${ssl_dir}/$cn.chain.crt"
      #[ ! -e "${ssl_dir}/${cn}.chain.crt" ] && ln -s "${ssl_dir}/${cn}.crt" "${ssl_dir}/$cn.chain.crt"
    fi
    # disable mod_ssl if the certificate still doesn't exist
    [ ! -e "$cert_file" ] && ssl_err=1
  fi
  done
  #echo ssl_err=$ssl_err
  # to avoid apache from starting, disable ssl module if certs files doesn't exist
  if [ "$ssl_err" = "1" ]; then
    echo "--> ERROR: disabling mod_ssl module because one or more certs files doesn't exist... please fix it"
    #grep -r "^LoadModule ssl_module" ${HTTPD_CONF_DIR} | awk -F: '{print $1}' | while read file ; do sed 's/^LoadModule ssl_module/#LoadModule ssl_module/' -i $file ; done
    sed "s/^LoadModule ssl_module/#LoadModule ssl_module/" -i "${HTTPD_CONF_DIR}/httpd.conf"
  fi
  }
fi

# load php modules (used by php-fpm also)
if [ "$PHP_ENABLED" = "true" ] || [ "$PHPFPM_ENABLED" = "true" ]; then
  echo "=> INFO: enabling PHP Modules based on $(php -v| head -n1)..."
  if [ "${PHP_MODULES_ENABLED}" = "all" ] || [ "${PHP_MODULES_ENABLED}" = "ALL" ]; then
      for MODULE in ${PHP_PREFIX}/lib/php/extensions/*/*.so; do docker-php-ext-enable $MODULE ; done \
    else
      for MODULE in ${PHP_MODULES_ENABLED} ; do echo "--> Enabling PHP module: $MODULE" ; docker-php-ext-enable $MODULE ; done
  fi
fi


cfgService_mta() {
## SSMTP MTA Agent
if [ -e "/usr/sbin/ssmtp" ]; then
 echo "=> Configuring SSMTP MTA..."
 mv /usr/sbin/sendmail /usr/sbin/sendmail.ssmtp
 print_ssmtp_conf() {
  #echo "rewriteDomain=$domain"
  #echo "FromLineOverride=$from"
  echo "hostname=$domain"
  echo "root=$from"
  echo "mailhub=$host"
  echo "UseTLS=$tls"
  echo "UseSTARTTLS=$starttls"
  if [ -n "$username" ] && [ -n "$password" ]; then
   echo "auth on"
   echo "AuthUser=$username"
   echo "AuthPass=$password"
  fi
 }
 print_ssmtp_conf > /etc/ssmtp/ssmtp.conf
fi

## MSMTP MTA Agent
if [ -e "/usr/bin/msmtp" ]; then
 echo "=> Configuring MSMTP MTA..."
 print_msmtp_conf() {
  echo "defaults"
  echo "logfile -"
  echo "account default"
  echo "domain $domain"
  echo "from $from"
  echo "host $host"
  echo "port $port"
  echo "tls $tls"
  echo "tls_starttls $starttls"
  echo "timeout $timeout"
  if [ -n "$username" ] && [ -n "$password" ]; then
    echo "auth on"
    echo "user $username"
    echo "password $password"
    #passwordeval gpg2 --no-tty -q -d /etc/msmtp-password.gpg
  fi
 }
 print_msmtp_conf > /etc/msmtp.conf
fi

## DMA MTA Agent
if [ -e "/usr/sbin/dma" ]; then
 echo "=> Configuring DMA MTA..."

 print_dma_conf() {
  [ $host ] && echo "SMARTHOST $host"
  [ $tls = "on" ] && echo "SECURETRANSFER"
  [ $starttls = "on" ] && echo "STARTTLS"
  [ $port ] && echo "PORT $port"
  [ $from ] && echo "MASQUERADE $from"
  echo "MAILNAME /etc/mailname"
 }
 print_auth_conf() {
  echo $([ ! -z "${username}" ] && echo -n "$username|")${host}$([ ! -z "${password}" ] && echo -n ":${password}|")
 }
 [ $domain ] && echo "$domain" > /etc/mailname
 print_dma_conf > /etc/dma/dma.conf
 print_auth_conf > /etc/dma/auth.conf
fi

echo -n "--> forwarding all emails to: $host"
[ -n "$username" ] && echo -n " using username: $username"
echo

## izdsendmail config
echo "--> Configuring izSendmail MTA Wrapper..."
[ -e "/usr/sbin/sendmail" ] && mv /usr/sbin/sendmail /usr/sbin/sendmail.dist
ln -s /usr/local/sbin/izsendmail /usr/sbin/sendmail
sed "s/;sendmail_path =.*/sendmail_path = \/usr\/local\/sbin\/izsendmail -t -i/" -i ${PHP_CONF}
sed "s/auto_prepend_file =.*/auto_prepend_file = \/usr\/local\/share\/izsendmail-env.php/" -i ${PHP_CONF}
}

cfgService_mta
