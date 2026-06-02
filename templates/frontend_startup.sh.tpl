#!/bin/bash
JAVA_PACKAGE=java-17-amazon-corretto
sudo dnf install -y $JAVA_PACKAGE-devel mariadb105 jq || (sleep 120 ; sudo dnf install -y $JAVA_PACKAGE-devel mariadb105 jq)

# Infer the CPU architecture from the running kernel rather than passing it in:
# the arch is fully determined by the AMI/instance type, so this is the single
# source of truth and cannot drift from a Terraform variable. SR_ARCH is the
# StarRocks tarball suffix; JAVA_HOME is resolved from the installed JVM so the
# arch-specific corretto directory (.x86_64 / .aarch64) is never hardcoded.
SR_ARCH=$(uname -m | sed -e 's/x86_64/centos-amd64/' -e 's/aarch64/arm64/')
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

sudo su

sudo tee /etc/sysctl.conf > /dev/null << EOF
vm.swappiness = 0
vm.overcommit_memory = 1
kernel.perf_event_paranoid = 1
vm.max_map_count = 262144
net.ipv4.tcp_abort_on_overflow = 1
net.core.somaxconn=1024
EOF

sudo sysctl -p

cd /opt
# Fail fast if the binary cannot be downloaded or extracted, instead of silently
# continuing and producing a half-installed node (the download is a ~GB tarball
# from the private mirror; a reset mid-transfer must abort the boot, not proceed).
SR_TARBALL=StarRocks-${starrocks_version}-$SR_ARCH.tar.gz
if ! sudo wget --tries=3 --timeout=60 -O "$SR_TARBALL" "${download_base_url}/$SR_TARBALL"; then
   echo "FATAL: failed to download $SR_TARBALL from ${download_base_url}" >&2
   exit 1
fi
if ! sudo tar -xzf "$SR_TARBALL"; then
   echo "FATAL: failed to extract $SR_TARBALL (incomplete download?)" >&2
   exit 1
fi

sudo mkdir -p ${starrocks_data_path}/fe/
cp -a StarRocks-${starrocks_version}-$SR_ARCH/fe ${starrocks_data_path}/
sudo mkdir -p ${starrocks_data_path}/storage
sudo mkdir -p ${starrocks_data_path}/fe/meta

sudo tee /etc/environment > /dev/null << EOF
JAVA_HOME=/usr/bin/java
STARROCKS_HOME=${starrocks_data_path}
EOF


cat > ${starrocks_data_path}/fe/bin/start_sysd_daemon.sh << EOF
#!/bin/bash
LEADER_IP=\$(aws ssm get-parameter --name ${ssm_parameter_name} --region ${region} --output text --query "Parameter.Value")
MY_IP=\$(hostname -I | awk '{print $1}' | xargs)

echo "Leader: \$LEADER_IP"
echo "My IP: \$MY_IP"

if [[ \$LEADER_IP == \$MY_IP ]]; then
   echo "Starting as leader"
   ${starrocks_data_path}/fe/bin/start_fe.sh
else
   echo "Starting as follower, joining leader at \$LEADER_IP:9010"
   ${starrocks_data_path}/fe/bin/start_fe.sh --helper \$LEADER_IP:9010
fi
EOF
chmod +x ${starrocks_data_path}/fe/bin/start_sysd_daemon.sh


cat >> /etc/rc.d/rc.local << EOF
if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
   echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
fi
if test -f /sys/kernel/mm/transparent_hugepage/defrag; then
   echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
fi
echo kyber | sudo tee /sys/block/nvme0p1/queue/scheduler
EOF
chmod +x /etc/rc.d/rc.local

sed -i 's/SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
sed -i 's/SELINUXTYPE/#SELINUXTYPE/' /etc/selinux/config

cat > ${starrocks_data_path}/fe/conf/fe.conf<< EOF
# Harcode defaults
http_port=8030
rpc_port=9020
query_port=9030
edit_log_port=9010

run_mode = shared_data
enable_load_volume_from_conf = true
cloud_native_storage_type = S3

aws_s3_endpoint = https://s3.${region}.amazonaws.com
aws_s3_path = s3://${bucket}
aws_s3_use_instance_profile = true
aws_s3_use_aws_sdk_default_behavior = true

meta_dir=${starrocks_data_path}/fe/meta
priority_networks=${vpc_cidr}

mysql_service_nio_enabled = true
enable_collect_query_detail_info = true
enable_udf = true

sys_log_delete_age = 3d
sys_log_roll_num = 5
internal_log_delete_age = 2d
internal_log_roll_num = 5
enable_profile_log = false
audit_log_delete_age = 14d
EOF


sudo tee /etc/systemd/system/starrocks-fe.service > /dev/null <<EOF
[Unit]
Description=StarRocks Frontend
After=network.target

[Service]
Type=simple
Environment="JAVA_HOME=$JAVA_HOME"
Environment="STARROCKS_HOME=${starrocks_data_path}"
Environment="LD_LIBRARY_PATH=$JAVA_HOME/lib/server/"
Environment="JAVA_OPTS=-Djava.net.preferIPv4Stack=true -Xmx${java_heap_size_mb}m -XX:+UseG1GC -Djava.security.policy=${starrocks_data_path}/conf/udf_security.policy"
ExecStart=${starrocks_data_path}/fe/bin/start_sysd_daemon.sh
ExecStop=${starrocks_data_path}/fe/bin/stop_fe.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo tee /opt/starrocks/fe/conf/core-site.xml > /dev/null <<EOF
<configuration>
  <property>
      <name>fs.s3.impl</name>
      <value>org.apache.hadoop.fs.s3a.S3AFileSystem</value>
   </property>
   <property>
    <name>hadoop.tmp.dir</name>
    <value>/tmp/starrocks-hadoop</value>
  </property>
  <property>
    <name>fs.s3a.buffer.dir</name>
    <value>/tmp/starrocks-s3a-buffer</value>
  </property>
  <property>
    <name>fs.s3a.fast.upload</name>
    <value>true</value>
  </property>
  <property>
    <name>fs.s3a.fast.upload.buffer</name>
    <value>bytebuffer</value>
  </property>
</configuration>
EOF

mkdir -p /tmp/starrocks-hadoop /tmp/starrocks-s3a-buffer
chmod 777 /tmp/starrocks-hadoop /tmp/starrocks-s3a-buffer

# When an SSL secret is provided, serve MySQL-protocol connections over TLS and
# require it. The cert/key are packed into a PKCS12 keystore (the only artifact
# StarRocks reads at runtime), then the plaintext copies are removed.
SSL_SECRET="${ssl_secret_name}"
if [ -n "$SSL_SECRET" ]; then
   mkdir -p /opt/ssl
   umask 077
   SSL_JSON=$(aws secretsmanager get-secret-value --region ${region} --secret-id "$SSL_SECRET" --query SecretString --output text)
   echo "$SSL_JSON" | jq -r .server_cert > /opt/ssl/starrocks.crt
   echo "$SSL_JSON" | jq -r .server_key > /opt/ssl/starrocks.key
   KEYSTORE_PW=$(echo "$SSL_JSON" | jq -r .keystore_password)
   openssl pkcs12 -export -in /opt/ssl/starrocks.crt -inkey /opt/ssl/starrocks.key -out /opt/ssl/starrocks.p12 -passout pass:"$KEYSTORE_PW"
   rm -f /opt/ssl/starrocks.crt /opt/ssl/starrocks.key
   cat >> ${starrocks_data_path}/fe/conf/fe.conf << SSLEOF
ssl_keystore_location = /opt/ssl/starrocks.p12
ssl_keystore_password = $KEYSTORE_PW
ssl_key_password = $KEYSTORE_PW
ssl_force_secure_transport = true
SSLEOF
   unset SSL_JSON KEYSTORE_PW
fi

MY_IP=$(hostname -I | awk '{print $1}' | xargs)

# Register against the leader using whatever the FE is locked down with: TLS when
# a CA cert secret is set (leader reached by IP, not in the cert SAN, so trust the
# chain but skip hostname verification) and a password when the root-password
# secret is set (via MYSQL_PWD so it never lands on disk or in argv/ps).
ROOT_PW_SECRET="${root_password_secret_name}"
CA_CERT_SECRET="${ca_cert_secret_name}"
MYSQL_AUTH="-uroot"
if [ -n "$CA_CERT_SECRET" ]; then
   mkdir -p /opt/ssl
   aws secretsmanager get-secret-value --region ${region} --secret-id "$CA_CERT_SECRET" --query SecretString --output text > /opt/ssl/starrocks-ca.crt
   MYSQL_AUTH="-uroot --ssl-ca=/opt/ssl/starrocks-ca.crt"
fi
if [ -n "$ROOT_PW_SECRET" ]; then
   export MYSQL_PWD=$(aws secretsmanager get-secret-value --region ${region} --secret-id "$ROOT_PW_SECRET" --query SecretString --output text)
fi

# Re-read the SSM leader IP on every iteration so we pick up the leader as soon as
# it is designated (the value starts as a placeholder and is set out of band). If
# the SSM names this node, it is the leader -> nothing to register, exit at once.
# Otherwise wait for the leader to answer, register as a follower, then stop.
# Capped at ~5 min so cloud-init does not block forever; the FE service
# (Restart=always) re-reads the SSM independently for the leader election.
for i in {1..60}; do
   LEADER_IP=$(aws ssm get-parameter --name ${ssm_parameter_name} --region ${region} --output text --query "Parameter.Value")
   if [ "$LEADER_IP" = "$MY_IP" ]; then
      echo "This node is the leader; no follower registration needed."
      break
   fi
   if mysql $MYSQL_AUTH -h "$LEADER_IP" -P 9030 -e "SELECT 1" 2>/dev/null; then
      echo "Leader $LEADER_IP is ready; registering as follower."
      echo "ALTER SYSTEM ADD FOLLOWER \"$MY_IP:9010\";" | mysql $MYSQL_AUTH -h "$LEADER_IP" -P 9030
      break
   fi
   echo "Waiting for the leader (SSM=$LEADER_IP)..."
   sleep 5
done
unset MYSQL_PWD

sudo systemctl daemon-reload
sudo systemctl enable starrocks-fe
sudo systemctl start starrocks-fe

${additional_fe_user_data}