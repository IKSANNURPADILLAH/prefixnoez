#!/bin/bash
# === INPUT MANUAL ===
read -p "Masukkan nama interface (contoh: eth0): " INTERFACE
read -p "Masukkan IP Prefix subnet (contoh: 89.144.50): " IP_PREFIX
read -p "Masukkan IP START (angka akhir, contoh: 129): " START
read -p "Masukkan IP END (angka akhir, contoh: 255): " END
read -p "Masukkan netmask (contoh: 24): " NETMASKS

PORT_START=3128
USERNAME="vodkaace"
PASSWORD="indonesia"
PASSWD_FILE="/etc/squid/passwd"
SQUID_CONF_DIR="/etc/squid"

# === CEK INTERFACE ===
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    echo "[!] Interface $INTERFACE tidak ditemukan. Periksa kembali." >&2
    exit 1
fi

# === TAMBAHKAN IP KE INTERFACE ===
echo "[+] Menambahkan IP ke interface $INTERFACE"
for i in $(seq $START $END); do
    IP="$IP_PREFIX.$i"
    if ! ip addr show dev $INTERFACE | grep -q "$IP"; then
        sudo ip addr add "$IP/$NETMASKS" dev $INTERFACE
    fi
done

# === INSTALL PAKET YANG DIBUTUHKAN ===
echo "[+] Menginstall Squid dan Apache utils"
sudo apt update
sudo apt install squid apache2-utils -y

# === SETUP AUTH USER ===
echo "[+] Menambahkan user proxy $USERNAME"
if [ ! -f "$PASSWD_FILE" ]; then
    sudo htpasswd -cb "$PASSWD_FILE" "$USERNAME" "$PASSWORD"
else
    sudo htpasswd -b "$PASSWD_FILE" "$USERNAME" "$PASSWORD"
fi

# === BACKUP CONFIG LAMA ===
echo "[+] Membackup konfigurasi Squid lama"
sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.bak.$(date +%s)

# === BUAT KONFIGURASI SQUAD1 (128 IP pertama) ===
echo "[+] Menulis konfigurasi Squid1 (128 IP pertama) ke /etc/squid/squid1.conf"
sudo tee $SQUID_CONF_DIR/squid1.conf > /dev/null <<EOF
workers 2
auth_param basic program /usr/lib/squid/basic_ncsa_auth $PASSWD_FILE
auth_param basic realm Private Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated

access_log /var/log/squid/access1.log
cache_log /var/log/squid/cache1.log
cache_store_log none
logfile_rotate 0
buffered_logs on
dns_v4_first on
EOF

for i in $(seq $START 128); do
    PORT=$((PORT_START + i - START))
    IP="$IP_PREFIX.$i"
    echo "http_port $PORT" | sudo tee -a $SQUID_CONF_DIR/squid1.conf > /dev/null
    echo "acl to$i myport $PORT" | sudo tee -a $SQUID_CONF_DIR/squid1.conf > /dev/null
    echo "tcp_outgoing_address $IP to$i" | sudo tee -a $SQUID_CONF_DIR/squid1.conf > /dev/null
    echo "" | sudo tee -a $SQUID_CONF_DIR/squid1.conf > /dev/null
done

# === BUAT KONFIGURASI SQUAD2 (128 IP terakhir) ===
echo "[+] Menulis konfigurasi Squid2 (128 IP terakhir) ke /etc/squid/squid2.conf"
sudo tee $SQUID_CONF_DIR/squid2.conf > /dev/null <<EOF
workers 2
auth_param basic program /usr/lib/squid/basic_ncsa_auth $PASSWD_FILE
auth_param basic realm Private Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated

access_log /var/log/squid/access2.log
cache_log /var/log/squid/cache2.log
cache_store_log none
logfile_rotate 0
buffered_logs on
dns_v4_first on
EOF

for i in $(seq 129 $END); do
    PORT=$((PORT_START + i - START))
    IP="$IP_PREFIX.$i"
    echo "http_port $PORT" | sudo tee -a $SQUID_CONF_DIR/squid2.conf > /dev/null
    echo "acl to$i myport $PORT" | sudo tee -a $SQUID_CONF_DIR/squid2.conf > /dev/null
    echo "tcp_outgoing_address $IP to$i" | sudo tee -a $SQUID_CONF_DIR/squid2.conf > /dev/null
    echo "" | sudo tee -a $SQUID_CONF_DIR/squid2.conf > /dev/null
done

# === SYSTEMD SERVICE CONFIGURATION FOR SQUAD1 ===
echo "[+] Menambahkan systemd service untuk squid1"
sudo tee /etc/systemd/system/squid1.service > /dev/null <<EOF
[Unit]
Description=Squid Proxy Server 1
After=network.target

[Service]
ExecStart=/usr/sbin/squid -f $SQUID_CONF_DIR/squid1.conf
ExecReload=/usr/sbin/squid -k reconfigure
ExecStop=/usr/sbin/squid -k shutdown
User=squid
Group=squid
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# === SYSTEMD SERVICE CONFIGURATION FOR SQUAD2 ===
echo "[+] Menambahkan systemd service untuk squid2"
sudo tee /etc/systemd/system/squid2.service > /dev/null <<EOF
[Unit]
Description=Squid Proxy Server 2
After=network.target

[Service]
ExecStart=/usr/sbin/squid -f $SQUID_CONF_DIR/squid2.conf
ExecReload=/usr/sbin/squid -k reconfigure
ExecStop=/usr/sbin/squid -k shutdown
User=squid
Group=squid
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# === AKTIFKAN DAN START LAYANAN SQUAD ===
echo "[+] Mengaktifkan dan memulai Squid1 & Squid2"
sudo systemctl daemon-reload
sudo systemctl enable squid1.service
sudo systemctl start squid1.service
sudo systemctl enable squid2.service
sudo systemctl start squid2.service

# === SIMPAN HASIL KE FILE ===
echo "[+] Menyimpan hasil konfigurasi ke $HASIL_FILE"
: > "$HASIL_FILE"

for i in $(seq $START $END); do
    PORT=$((PORT_START + i - START))
    IP="$IP_PREFIX.$i"
    echo "$USERNAME:$PASSWORD@$IP:$PORT" >> "$HASIL_FILE"
done

echo "✅ Setup selesai! Proxy siap digunakan."
echo "📄 Hasil disimpan di: $HASIL_FILE"
