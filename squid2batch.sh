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
HASIL_FILE="/root/proxylist.txt"

# === CEK INTERFACE ===
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    echo "[!] Interface $INTERFACE tidak ditemukan. Periksa kembali." >&2
    exit 1
fi

# === HENTIKAN LAYANAN SQUID DEFAULT JIKA ADA ===
echo "[+] Menghentikan layanan squid bawaan (jika aktif)"
sudo systemctl stop squid 2>/dev/null
sudo systemctl disable squid 2>/dev/null

# === TAMBAHKAN IP KE INTERFACE SECARA TEMPORER ===
echo "[+] Menambahkan IP ke interface $INTERFACE"
for i in $(seq $START $END); do
    IP="$IP_PREFIX.$i"
    if ! ip addr show dev $INTERFACE | grep -q "$IP"; then
        sudo ip addr add "$IP/$NETMASKS" dev "$INTERFACE"
    fi
done

# === INSTALL PAKET YANG DIBUTUHKAN ===
echo "[+] Menginstall Squid dan Apache utils"
sudo apt update
sudo apt install -y squid apache2-utils

# === SETUP AUTH USER ===
echo "[+] Menambahkan user proxy $USERNAME"
if [ ! -f "$PASSWD_FILE" ]; then
    sudo htpasswd -cb "$PASSWD_FILE" "$USERNAME" "$PASSWORD"
else
    sudo htpasswd -b "$PASSWD_FILE" "$USERNAME" "$PASSWORD"
fi

# === BACKUP KONFIGURASI LAMA ===
echo "[+] Membackup konfigurasi Squid lama"
sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.bak.$(date +%s)

# === HITUNG PEMBAGIAN IP UNTUK 2 KONFIGURASI ===
TOTAL_IP=$((END - START + 1))
MID=$((START + TOTAL_IP / 2 - 1))

# === TEMPLATE KONFIGURASI SQUAD ===
generate_squid_conf() {
    local FILE="$1"
    local START_IP="$2"
    local END_IP="$3"
    local ACCESS_LOG="$4"
    local CACHE_LOG="$5"

    sudo tee "$FILE" > /dev/null <<EOF
workers 2
auth_param basic program /usr/lib/squid/basic_ncsa_auth $PASSWD_FILE
auth_param basic realm Private Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated

access_log $ACCESS_LOG
cache_log $CACHE_LOG
cache_store_log none
logfile_rotate 0
buffered_logs on
dns_v4_first on
EOF

    for i in $(seq "$START_IP" "$END_IP"); do
        PORT=$((PORT_START + i - START))
        IP="$IP_PREFIX.$i"
        echo "http_port $PORT" | sudo tee -a "$FILE" > /dev/null
        echo "acl to$i myport $PORT" | sudo tee -a "$FILE" > /dev/null
        echo "tcp_outgoing_address $IP to$i" | sudo tee -a "$FILE" > /dev/null
        echo "" | sudo tee -a "$FILE" > /dev/null
    done
}

# === BUAT KONFIGURASI SQUAD1 ===
echo "[+] Menulis konfigurasi Squid1"
generate_squid_conf "$SQUID_CONF_DIR/squid1.conf" "$START" "$MID" "/var/log/squid/access1.log" "/var/log/squid/cache1.log"

# === BUAT KONFIGURASI SQUAD2 ===
echo "[+] Menulis konfigurasi Squid2"
generate_squid_conf "$SQUID_CONF_DIR/squid2.conf" "$((MID + 1))" "$END" "/var/log/squid/access2.log" "/var/log/squid/cache2.log"

# === SYSTEMD SERVICE UNTUK SQUAD1 ===
echo "[+] Membuat service systemd untuk squid1"
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

# === SYSTEMD SERVICE UNTUK SQUAD2 ===
echo "[+] Membuat service systemd untuk squid2"
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

# === AKTIFKAN DAN MULAIKAN LAYANAN ===
echo "[+] Mengaktifkan dan memulai Squid1 & Squid2"
sudo systemctl daemon-reload
sudo systemctl enable --now squid1.service
sudo systemctl enable --now squid2.service

# === SIMPAN HASIL KE FILE ===
echo "[+] Menyimpan daftar proxy ke $HASIL_FILE"
: > "$HASIL_FILE"

for i in $(seq $START $END); do
    PORT=$((PORT_START + i - START))
    IP="$IP_PREFIX.$i"
    echo "$USERNAME:$PASSWORD@$IP:$PORT" >> "$HASIL_FILE"
done

echo "✅ Setup selesai! Proxy siap digunakan."
echo "📄 File proxy list: $HASIL_FILE"
