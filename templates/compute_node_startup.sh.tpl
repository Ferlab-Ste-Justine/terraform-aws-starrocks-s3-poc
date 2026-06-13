#!/bin/bash
JAVA_PACKAGE=java-17-amazon-corretto
sudo dnf install -y $JAVA_PACKAGE-devel mariadb105 xfsprogs || (sleep 120 ; sudo dnf install -y $JAVA_PACKAGE-devel mariadb105 xfsprogs)

# Infer the CPU architecture from the running kernel rather than passing it in:
# the arch is fully determined by the AMI/instance type, so this is the single
# source of truth and cannot drift from a Terraform variable. SR_ARCH is the
# StarRocks tarball suffix; JAVA_HOME is resolved from the installed JVM so the
# arch-specific corretto directory (.x86_64 / .aarch64) is never hardcoded.
SR_ARCH=$(uname -m | sed -e 's/x86_64/centos-amd64/' -e 's/aarch64/arm64/')
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

sudo su

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

sudo mkdir -p ${starrocks_data_path}/storage
sudo mkdir -p ${starrocks_data_path}/cn
cp -a StarRocks-${starrocks_version}-$SR_ARCH/be/. ${starrocks_data_path}/cn/

sudo tee /etc/sysctl.conf > /dev/null << EOF
vm.swappiness = 0
vm.overcommit_memory = 1
kernel.perf_event_paranoid = 1
vm.max_map_count = 262144
net.ipv4.tcp_abort_on_overflow = 1
net.core.somaxconn=1024
EOF

sudo sysctl -p

cat >> /etc/rc.d/rc.local << EOF
if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
   echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
fi
if test -f /sys/kernel/mm/transparent_hugepage/defrag; then
   echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
fi
EOF
chmod +x /etc/rc.d/rc.local

sed -i 's/SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
sed -i 's/SELINUXTYPE/#SELINUXTYPE/' /etc/selinux/config

#TODO look into datacache settings
cat > ${starrocks_data_path}/cn/conf/cn.conf<< EOF
# Harcode defaults
be_port=9060
be_http_port=8040
heartbeat_service_port=9050
brpc_port=8060
starlet_port=9070

storage_root_path=${starrocks_data_path}/storage
priority_networks=${vpc_cidr}
mem_limit = 80%
spill_local_storage_dir = ${starrocks_data_path}/storage/spill
memory_limitation_per_thread_for_schema_change = 4
push_worker_count_normal_priority = 6
push_worker_count_high_priority = 6
streaming_load_rpc_max_alive_time_sec = 2400
max_percentage_of_error_disk = 100
compact_threads = 2
datacache_mem_size = 40%
datacache_disk_size = 80%
EOF

# Prepare the local NVMe instance-store disk for the CN storage/datacache path.
# Runs on every boot via systemd so it survives reboots (filesystem persists) and
# stop/start (instance store comes back blank -> reformatted). No-op when the
# instance has no local NVMe (e.g. non-"d" instance types) -> storage stays on root.
sudo tee /usr/local/bin/starrocks-storage.sh > /dev/null << 'STORAGE_EOF'
#!/bin/bash
set -e
DEV=$(lsblk -dpno NAME,MODEL | awk '/Amazon EC2 NVMe Instance Storage/{print $1; exit}')
if [ -z "$DEV" ]; then exit 0; fi
MOUNT=${starrocks_data_path}/storage
mkdir -p "$MOUNT"
blkid "$DEV" >/dev/null 2>&1 || mkfs.xfs -f "$DEV"
mountpoint -q "$MOUNT" || mount "$DEV" "$MOUNT"
# StarRocks recommends the kyber I/O scheduler for SSD/NVMe data disks.
echo kyber > /sys/block/$(basename "$DEV")/queue/scheduler
STORAGE_EOF
sudo chmod +x /usr/local/bin/starrocks-storage.sh

sudo tee /etc/systemd/system/starrocks-storage.service > /dev/null << EOF
[Unit]
Description=Prepare StarRocks local NVMe storage (format-if-needed, mount, scheduler)
After=local-fs.target
Before=starrocks-cn.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/bin/starrocks-storage.sh

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/starrocks-cn.service > /dev/null << EOF
[Unit]
Description=StarRocks Compute Node
Requires=starrocks-storage.service
After=starrocks-storage.service network.target

[Service]
Type=simple
Environment="JAVA_HOME=$JAVA_HOME"
Environment="STARROCKS_HOME=${starrocks_data_path}"
Environment="LD_LIBRARY_PATH=$JAVA_HOME/lib/server/"
Environment="JAVA_OPTS=-Djava.net.preferIPv4Stack=true -Xmx${java_heap_size_mb}m -XX:+UseG1GC"
ExecStart=/opt/starrocks/cn/bin/start_cn.sh
ExecStop=/opt/starrocks/cn/bin/stop_cn.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now starrocks-storage.service
sudo systemctl enable starrocks-cn
sudo systemctl start starrocks-cn

# Register with the FE using whatever it is locked down with: TLS when a CA cert
# secret is set (FE reached by its DNS name, which matches the server cert SAN, so
# verify the hostname) and a password when the root-password secret is set (via
# MYSQL_PWD so it never lands on disk or in argv/ps).
ROOT_PW_SECRET="${root_password_secret_name}"
CA_CERT_SECRET="${ca_cert_secret_name}"
MYSQL_AUTH="-uroot"
if [ -n "$CA_CERT_SECRET" ]; then
  mkdir -p /opt/ssl
  aws secretsmanager get-secret-value --region ${region} --secret-id "$CA_CERT_SECRET" --query SecretString --output text > /opt/ssl/starrocks-ca.crt
  MYSQL_AUTH="-uroot --ssl-ca=/opt/ssl/starrocks-ca.crt --ssl-verify-server-cert=ON"
fi
if [ -n "$ROOT_PW_SECRET" ]; then
  export MYSQL_PWD=$(aws secretsmanager get-secret-value --region ${region} --secret-id "$ROOT_PW_SECRET" --query SecretString --output text)
fi

echo "Waiting for Frontend (FE) to be available..."
until echo "SELECT 1;" | mysql $MYSQL_AUTH -h ${fe_host} -P ${fe_query_port} 2>/dev/null; do
  sleep 5
done

echo "Registering Backend with Frontend..."
echo "ALTER SYSTEM ADD COMPUTE NODE \"$(hostname -I | awk '{print $1}'):9050\";" | mysql $MYSQL_AUTH -h ${fe_host} -P ${fe_query_port}
unset MYSQL_PWD

${additional_cn_user_data}
