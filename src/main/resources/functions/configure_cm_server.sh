#
# Licensed to Cloudera, Inc. under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# Cloudera, Inc. licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -x

function wait_cm_server() {
  for ID in {180..1}; do
    if [ $(curl -sI -u admin:admin "http://localhost:7180" | grep "HTTP/1.1 200 OK" | wc -l) -gt 0 ]; then
        echo "CM Server up"
        return 0
    fi
    sleep 1
  done
  return 1
}

function configure_cm_server() {
    # if [ -f /etc/init.d/mysqld ]; then
    #     service mysqld start
    # elif [ -f /etc/init.d/mysql ]; then
    #     service mysql start
    # fi
    
    # /usr/bin/mysqladmin -u root password 'cloudera'
    # mysql --user=root --password=cloudera -e "CREATE DATABASE metastore;"
    # mysql --user=root --password=cloudera -e "CREATE USER 'hive'@'%' IDENTIFIED BY 'hive';"
    # mysql --user=root --password=cloudera -e "GRANT SELECT,INSERT,UPDATE,DELETE,ALTER,CREATE,DROP ON metastore.* TO 'hive'@'%';"

    sudo -u postgres psql --command="CREATE USER hive PASSWORD 'hive'"
    sudo -u postgres psql --command="CREATE DATABASE metastore OWNER hive"

    service cloudera-scm-server start
    if wait_cm_server; then
    	if [ ! -z "${CONFIGURE_KERBEROS_DONE+xxx}" ] && [ ! -z "${KERBEROS_REALM+xxx}" ]; then
            sed -i -e "s/EXAMPLE\.COM/$KERBEROS_REALM_REGEX/" /var/kerberos/krb5kdc/kadm5.acl
            cat >> run_addpinc <<END
#!/usr/bin/expect -f
set timeout 5000
set principal_kadmin [lindex \$argv 0]
set principal_user [lindex \$argv 1]
set realm [lindex \$argv 2]
spawn sudo kadmin -p \$principal_kadmin/admin@\$realm
expect -re {Password for .* } { send "\$principal_kadmin\r" }
expect {kadmin:  } { send "addprinc -randkey \$principal_user/admin@\$realm\r" }
expect {kadmin:  } { send "xst -k cmf.keytab \$principal_user/admin@\$realm\r" }
expect {kadmin:  } { send "quit\r" }
expect EOF
END
            chmod +x run_addpinc
            ./run_addpinc $CLUSTER_USER cloudera-scm $KERBEROS_REALM
            rm -rf ./run_addpinc
            mv cmf.keytab /etc/cloudera-scm-server
            chown cloudera-scm:cloudera-scm /etc/cloudera-scm-server/cmf.keytab
            chmod 600 /etc/cloudera-scm-server/cmf.keytab
            echo "cloudera-scm/admin@$KERBEROS_REALM" > /etc/cloudera-scm-server/cmf.principal
            chown cloudera-scm:cloudera-scm /etc/cloudera-scm-server/cmf.principal
            chmod 600 /etc/cloudera-scm-server/cmf.principal
            curl -u admin:admin -X PUT -H 'Content-Type:application/json' -d '{ "items" : [ { "name" : "SECURITY_REALM", "value" : "'"$KERBEROS_REALM"'" } ] }' http://localhost:7180/api/v1/cm/config
	fi
        curl -u admin:admin -X PUT -H 'Content-Type:application/json' -d '{ "items" : [ { "name" : "PUBLIC_CLOUD_STATUS", "value" : "NOT_ON_PUBLIC_CLOUD" } ] }' http://localhost:7180/api/v1/cm/config
        if [ -f /tmp/cm-license.txt ]; then
	    curl -u admin:admin -F license=@/tmp/cm-license.txt http://localhost:7180/api/v1/cm/license
	    rm -rf /tmp/cm-license.txt
	fi	    
	service cloudera-scm-server restart
	wait_cm_server
    if [ -d /etc/postgresql/8.4/main ]; then
        POSTGRES_CONF_DIR=/etc/postgresql/8.4/main
    elif [ -d /var/lib/pgsql/data ]; then
        POSTGRES_CONF_DIR=/var/lib/pgsql/data
    fi
    
    sed -i -r 's:ident.*:md5:g' $POSTGRES_CONF_DIR/pg_hba.conf
    sed -i -r 's:peer.*:md5:g' $POSTGRES_CONF_DIR/pg_hba.conf
    echo "listen_addresses = '*'" >> $POSTGRES_CONF_DIR/postgresql.conf
    echo -e "host\tall\tall\t0.0.0.0/0\tmd5" >> $POSTGRES_CONF_DIR/pg_hba.conf

    if [ -f /etc/init.d/postgresql ]; then
        service postgresql restart
    elif [ -f /etc/init.d/postgresql-8.4 ]; then
        service postgresql-8.4 restart
    fi

    fi
}